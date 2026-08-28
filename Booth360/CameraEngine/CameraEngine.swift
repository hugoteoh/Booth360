import Foundation
import AVFoundation
import UIKit
import Observation

/// 一次成功录制的结果。
struct RecordedClipInfo: Equatable {
    let url: URL
    let durationSeconds: Double
    let width: Int
    let height: Int
    let frameRate: Double
    let lens: CameraLens
}

/// 相机引擎门面：会话生命周期、镜头/格式选择、录制、手动控制、中断恢复。
///
/// 线程模型：所有 AVFoundation 调用都在私有串行队列 `sessionQueue` 上执行；
/// 对外的 @Observable 状态只在 MainActor 上更新。UI 不直接接触 AVFoundation。
@Observable
final class CameraEngine {

    enum Status: Equatable {
        case idle
        case configuring
        case running
        case recording
        case interrupted(String)
        case failed(CameraError)

        var isRunningOrRecording: Bool {
            self == .running || self == .recording
        }
    }

    // MARK: - 对外可观察状态（仅 MainActor 更新）

    private(set) var status: Status = .idle
    private(set) var currentConfiguration: CameraConfiguration = .phase1Default
    /// 实际生效的格式描述，如 "1080p · 60FPS · 广角 1×"。
    private(set) var activeFormatSummary: String = ""
    /// 请求帧率被降级时为 true（例如设备超广角不支持 60fps）。
    private(set) var didFallBackFrameRate: Bool = false
    private(set) var manualLimits: ManualControlLimits = ManualControlLimits()
    /// 麦克风是否实际接入（权限被拒时为 false，仍可无声录制）。
    private(set) var audioEnabled: Bool = false
    /// 当前防抖档位描述（"增强电影级"/"电影级"/…，永远自动开启）。
    private(set) var stabilizationDescription: String = ""

    /// 预览层直接使用该 session。
    let session = AVCaptureSession()

    // MARK: - 私有

    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.hugoteoh.booth360.camera-session")
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored private let delegateProxy = RecordingDelegateProxy()
    @ObservationIgnored private var videoDeviceInput: AVCaptureDeviceInput?
    @ObservationIgnored private var audioDeviceInput: AVCaptureDeviceInput?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var recordingCompletion: ((Result<RecordedClipInfo, CameraError>) -> Void)?
    /// sessionQueue 上维护的“当前生效”快照，录制完成时用来生成 RecordedClipInfo。
    @ObservationIgnored private var activeSelection: (configuration: CameraConfiguration, frameRate: Double)?

    init() {
        setUpDelegateProxy()
        observeSessionNotifications()
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 配置

    /// 按给定配置（重新）搭建会话并启动预览。可重复调用（切镜头/帧率时调用）。
    func configure(_ configuration: CameraConfiguration) async {
        await setStatus(.configuring)

        guard await Self.ensurePermission(for: .video) else {
            await setStatus(.failed(.permissionDenied))
            return
        }
        let audioAllowed = configuration.recordsAudio
            ? await Self.ensurePermission(for: .audio)
            : false

        do {
            let result = try await performConfiguration(configuration, includeAudio: audioAllowed)
            await MainActor.run {
                self.currentConfiguration = configuration
                self.didFallBackFrameRate = result.didFallBack
                self.manualLimits = result.limits
                self.audioEnabled = audioAllowed
                self.stabilizationDescription = result.stabilization
                self.activeFormatSummary =
                    "\(configuration.resolution.displayName) · \(Int(result.frameRate))FPS · \(configuration.lens.displayName)"
                self.status = .running
                self.rebuildRotationCoordinator()
            }
            AppLogger.camera.info("相机已配置: \(self.activeFormatSummary, privacy: .public)")
        } catch let error as CameraError {
            await setStatus(.failed(error))
            AppLogger.camera.error("配置失败: \(error.localizedDescription, privacy: .public)")
        } catch {
            await setStatus(.failed(.configurationFailed(error.localizedDescription)))
        }
    }

    private struct ConfigurationResult {
        let frameRate: Double
        let didFallBack: Bool
        let limits: ManualControlLimits
        let stabilization: String
    }

    private func performConfiguration(
        _ configuration: CameraConfiguration,
        includeAudio: Bool
    ) async throws -> ConfigurationResult {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    let result = try configureOnSessionQueue(configuration, includeAudio: includeAudio)
                    if !session.isRunning { session.startRunning() }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 只能在 sessionQueue 上调用。
    private func configureOnSessionQueue(
        _ configuration: CameraConfiguration,
        includeAudio: Bool
    ) throws -> ConfigurationResult {
        guard let device = AVCaptureDevice.default(configuration.lens.deviceType, for: .video, position: .back) else {
            throw CameraError.deviceUnavailable(configuration.lens)
        }

        // 纯逻辑格式选择（可单测）
        let candidates = device.formats.enumerated().map { index, format -> FormatCandidate in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return FormatCandidate(
                index: index,
                width: dims.width,
                height: dims.height,
                maxFrameRate: maxRate,
                isBinned: format.isVideoBinned,
                isMultiCamOnly: false
            )
        }
        guard let selection = CameraFormatSelector.select(
            from: candidates,
            resolution: configuration.resolution,
            requestedFrameRate: configuration.frameRate.doubleValue
        ) else {
            throw CameraError.formatUnsupported(
                "\(configuration.resolution.displayName) @ \(configuration.frameRate.displayName)")
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .inputPriority

        // 替换视频输入
        if let existing = videoDeviceInput {
            session.removeInput(existing)
            videoDeviceInput = nil
        }
        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else {
            throw CameraError.configurationFailed("无法添加视频输入")
        }
        session.addInput(videoInput)
        videoDeviceInput = videoInput

        // 应用格式与恒定帧率
        let format = device.formats[selection.index]
        try device.lockForConfiguration()
        device.activeFormat = format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(selection.frameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        device.unlockForConfiguration()

        // 音频输入
        if let existingAudio = audioDeviceInput {
            session.removeInput(existingAudio)
            audioDeviceInput = nil
        }
        if includeAudio, let mic = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                audioDeviceInput = audioInput
            }
        }

        // 录制输出（只加一次）
        if !session.outputs.contains(movieOutput) {
            guard session.canAddOutput(movieOutput) else {
                throw CameraError.configurationFailed("无法添加录制输出")
            }
            session.addOutput(movieOutput)
        }

        // 视频防抖：按当前格式能力选最强档
        // （增强电影级 iOS 17.2+ > 电影级 > cinematic > auto）。
        // 部分高帧率格式不支持防抖，isVideoStabilizationSupported 为 false 时自动跳过。
        var stabilizationText = "该格式不支持"
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoStabilizationSupported {
            if #available(iOS 18.0, *),
               format.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced) {
                connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
                stabilizationText = "增强电影级"
            } else if format.isVideoStabilizationModeSupported(.cinematicExtended) {
                connection.preferredVideoStabilizationMode = .cinematicExtended
                stabilizationText = "电影级"
            } else if format.isVideoStabilizationModeSupported(.cinematic) {
                connection.preferredVideoStabilizationMode = .cinematic
                stabilizationText = "标准电影"
            } else {
                connection.preferredVideoStabilizationMode = .auto
                stabilizationText = "自动"
            }
            AppLogger.camera.info("防抖模式: \(stabilizationText, privacy: .public)")
        }

        activeSelection = (configuration, selection.frameRate)
        return ConfigurationResult(
            frameRate: selection.frameRate,
            didFallBack: selection.didFallBack,
            limits: Self.limits(for: device),
            stabilization: stabilizationText
        )
    }

    private static func limits(for device: AVCaptureDevice) -> ManualControlLimits {
        let format = device.activeFormat
        return ManualControlLimits(
            minISO: format.minISO,
            maxISO: format.maxISO,
            minShutterSeconds: max(format.minExposureDuration.seconds, 1.0 / 8000.0),
            maxShutterSeconds: min(format.maxExposureDuration.seconds, 0.5),
            minExposureBias: device.minExposureTargetBias,
            maxExposureBias: device.maxExposureTargetBias,
            maxWhiteBalanceGain: device.maxWhiteBalanceGain
        )
    }

    // MARK: - 预览层与旋转

    @MainActor
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rebuildRotationCoordinator()
    }

    /// 幂等版：同一 layer 不重复重建旋转协调器。
    /// 管理员/嘉宾两个界面共用一个 session，各自出现时调用即可接管旋转跟随。
    @MainActor
    func ensurePreviewLayerAttached(_ layer: AVCaptureVideoPreviewLayer) {
        guard previewLayer !== layer else { return }
        attachPreviewLayer(layer)
    }

    @MainActor
    private func rebuildRotationCoordinator() {
        rotationObservation = nil
        rotationCoordinator = nil
        guard let device = videoDeviceInput?.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in
                guard let connection = self?.previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    // MARK: - 录制

    /// 开始录制并等待完成（到达 maxSeconds 自动停止，或外部调用 stopRecording）。
    /// 成功返回已落盘的片段信息；文件由调用方决定去留。
    func startRecording(to url: URL, maxSeconds: Int) async throws -> RecordedClipInfo {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard session.isRunning, !movieOutput.isRecording, recordingCompletion == nil else {
                    continuation.resume(throwing: CameraError.busy)
                    return
                }
                // 冻结本次录制的方向（跟随当前设备朝向）
                if let connection = movieOutput.connection(with: .video) {
                    let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
                    if connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                    // 优先 HEVC（体积小，画质同级），设备都支持硬解
                    if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                        movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                    }
                }
                movieOutput.maxRecordedDuration = CMTime(seconds: Double(maxSeconds), preferredTimescale: 600)
                recordingCompletion = { result in
                    continuation.resume(with: result.mapError { $0 as Error })
                }
                movieOutput.startRecording(to: url, recordingDelegate: delegateProxy)
                AppLogger.camera.info("开始录制 → \(url.lastPathComponent, privacy: .public)，上限 \(maxSeconds)s")
            }
        }
    }

    /// 提前手动停止（自动停止由 maxRecordedDuration 保证，不依赖 UI 计时器）。
    func stopRecording() {
        sessionQueue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
    }

    func stopSession() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            Task { @MainActor in self.status = .idle }
        }
    }

    // MARK: - 录制回调

    private func setUpDelegateProxy() {
        delegateProxy.onStart = { [weak self] _ in
            Task { @MainActor [weak self] in self?.status = .recording }
        }
        delegateProxy.onFinish = { [weak self] url, output, error in
            self?.handleRecordingFinished(url: url, output: output, error: error)
        }
    }

    private func handleRecordingFinished(url: URL, output: AVCaptureFileOutput, error: Error?) {
        sessionQueue.async { [self] in
            var success = true
            var failureDetail = ""
            if let nsError = error as NSError? {
                // maxRecordedDuration 到时会带着 error 回调，但 userInfo 标记“成功完成”——按成功处理
                success = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
                failureDetail = nsError.localizedDescription
            }
            let completion = recordingCompletion
            recordingCompletion = nil

            let config = activeSelection?.configuration ?? currentConfiguration
            let frameRate = activeSelection?.frameRate ?? 30
            let info = RecordedClipInfo(
                url: url,
                durationSeconds: output.recordedDuration.seconds.isFinite ? output.recordedDuration.seconds : 0,
                width: Int(config.resolution.width),
                height: Int(config.resolution.height),
                frameRate: frameRate,
                lens: config.lens
            )

            Task { @MainActor in
                self.status = self.session.isRunning ? .running : .idle
            }
            if success {
                AppLogger.camera.info("录制完成 \(url.lastPathComponent, privacy: .public)，时长 \(info.durationSeconds)s")
                completion?(.success(info))
            } else {
                AppLogger.camera.error("录制失败: \(failureDetail, privacy: .public)")
                completion?(.failure(.recordingFailed(failureDetail)))
            }
        }
    }

    // MARK: - 手动控制

    /// 下发手动控制。所有值先经 ControlClamp 钳制，避免超范围崩溃。
    func applyManualControls(_ state: ManualControlState) {
        sessionQueue.async { [self] in
            guard let device = videoDeviceInput?.device else { return }
            let limits = Self.limits(for: device)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if state.exposureLocked, device.isExposureModeSupported(.custom) {
                    let duration = CMTime(
                        seconds: ControlClamp.shutterSeconds(state.shutterSeconds, limits: limits),
                        preferredTimescale: 1_000_000_000
                    )
                    device.setExposureModeCustom(
                        duration: duration,
                        iso: ControlClamp.iso(state.iso, limits: limits),
                        completionHandler: nil
                    )
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    device.setExposureTargetBias(
                        ControlClamp.exposureBias(state.exposureBias, limits: limits),
                        completionHandler: nil
                    )
                }

                if state.focusLocked, device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(
                        lensPosition: ControlClamp.lensPosition(state.lensPosition),
                        completionHandler: nil
                    )
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }

                if state.whiteBalanceLocked, device.isWhiteBalanceModeSupported(.locked) {
                    let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: ControlClamp.temperature(state.temperature),
                        tint: ControlClamp.tint(state.tint)
                    )
                    var gains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
                    let maxGain = device.maxWhiteBalanceGain
                    gains.redGain = ControlClamp.whiteBalanceGain(gains.redGain, maxGain: maxGain)
                    gains.greenGain = ControlClamp.whiteBalanceGain(gains.greenGain, maxGain: maxGain)
                    gains.blueGain = ControlClamp.whiteBalanceGain(gains.blueGain, maxGain: maxGain)
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } catch {
                AppLogger.camera.error("手动控制下发失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 读取设备当前实际值，用于初始化手动控制滑杆（例如从自动切到锁定时接管当前值）。
    func snapshotCurrentValues(base: ManualControlState) -> ManualControlState {
        var result = base
        sessionQueue.sync { [self] in
            guard let device = videoDeviceInput?.device else { return }
            result.iso = device.iso
            let duration = device.exposureDuration.seconds
            if duration.isFinite, duration > 0 { result.shutterSeconds = duration }
            result.lensPosition = device.lensPosition
            var gains = device.deviceWhiteBalanceGains
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = ControlClamp.whiteBalanceGain(gains.redGain, maxGain: maxGain)
            gains.greenGain = ControlClamp.whiteBalanceGain(gains.greenGain, maxGain: maxGain)
            gains.blueGain = ControlClamp.whiteBalanceGain(gains.blueGain, maxGain: maxGain)
            let temperatureAndTint = device.temperatureAndTintValues(for: gains)
            result.temperature = ControlClamp.temperature(temperatureAndTint.temperature)
            result.tint = ControlClamp.tint(temperatureAndTint.tint)
        }
        return result
    }

    // MARK: - 权限

    private static func ensurePermission(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }

    // MARK: - 中断恢复

    private func observeSessionNotifications() {
        let center = NotificationCenter.default

        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] note in
            let reason = Self.interruptionText(from: note)
            AppLogger.camera.warning("会话被中断: \(reason, privacy: .public)")
            Task { @MainActor [weak self] in self?.status = .interrupted(reason) }
        })

        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            AppLogger.camera.info("中断结束，恢复会话")
            self?.resumeSessionIfNeeded()
        })

        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            AppLogger.camera.error("运行时错误: \(error?.localizedDescription ?? "未知", privacy: .public)")
            // 媒体服务重置（系统级恢复点）后重启会话即可
            if error?.code == .mediaServicesWereReset {
                self?.resumeSessionIfNeeded()
            } else {
                Task { @MainActor [weak self] in
                    self?.status = .failed(.configurationFailed(error?.localizedDescription ?? "相机运行时错误"))
                }
            }
        })

        notificationTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.resumeSessionIfNeeded()
        })
    }

    /// 中断结束/回到前台时恢复。
    /// 注意：后台中断时系统可能自动恢复会话（isRunning 一直为 true），
    /// 此时也必须把 status 从 interrupted 刷回 running，否则 UI 永远停在"已暂停"。
    private func resumeSessionIfNeeded() {
        sessionQueue.async { [self] in
            guard videoDeviceInput != nil else { return }
            if !session.isRunning {
                session.startRunning()
            }
            let running = session.isRunning
            Task { @MainActor in
                guard running else { return }
                if self.status != .recording {
                    self.status = .running
                }
            }
        }
    }

    private static func interruptionText(from note: Notification) -> String {
        guard let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "未知原因"
        }
        switch reason {
        case .audioDeviceInUseByAnotherClient: return "麦克风被其他应用占用"
        case .videoDeviceInUseByAnotherClient: return "相机被其他应用占用"
        case .videoDeviceNotAvailableInBackground: return "App 进入后台"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "分屏时相机不可用"
        case .videoDeviceNotAvailableDueToSystemPressure: return "系统压力过高（可能过热）"
        @unknown default: return "未知原因"
        }
    }

    // MARK: - 工具

    private func setStatus(_ newStatus: Status) async {
        await MainActor.run { self.status = newStatus }
    }
}

/// AVCaptureFileOutputRecordingDelegate 需要 NSObject；用独立代理避免引擎继承 NSObject。
private final class RecordingDelegateProxy: NSObject, AVCaptureFileOutputRecordingDelegate {
    var onStart: ((URL) -> Void)?
    var onFinish: ((URL, AVCaptureFileOutput, Error?) -> Void)?

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        onStart?(fileURL)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        onFinish?(outputFileURL, output, error)
    }
}
