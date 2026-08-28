import Foundation
import SwiftData
import AVFoundation
import Observation

/// 拍摄流程状态机。
///
/// idle → countingDown → recording → saving → idle
///
/// 防重复点击：`startTapped()` 只在 idle 且相机 running 时生效，
/// 其余阶段一律忽略（现场嘉宾狂点 Start 也不会出问题）。
@Observable
@MainActor
final class CaptureViewModel {

    enum Phase: Equatable {
        case idle
        case countingDown(Int)
        case recording
        case saving
    }

    /// 成片确认弹层（模板自动处理完成后弹出）。
    struct ReviewPresentation: Identifiable {
        let id = UUID()
        let playerItem: AVPlayerItem
        let render: RenderedVideo
        let eventName: String
    }

    // MARK: - 状态

    private(set) var phase: Phase = .idle {
        didSet { updateAutomation() }
    }
    private(set) var recordingElapsedSeconds: Int = 0
    /// 最近一次保存成功的片段（仅在未设置当前活动的兜底路径显示）。
    private(set) var lastSavedClip: SourceClip?
    /// 成片确认弹层。
    var review: ReviewPresentation? {
        didSet { updateAutomation() }
    }
    var errorMessage: String?

    var settings = RecordingSettings()
    var manualControls = ManualControlState()
    /// 当前活动启用的拍摄模式（拍摄页底部按钮排）。
    private(set) var shotModes: [ShotMode] = []
    var selectedShotModeID: UUID?

    var selectedShotMode: ShotMode? {
        shotModes.first { $0.id == selectedShotModeID } ?? shotModes.first
    }

    /// 本次录制实际时长：选中模式的时长优先，否则用页面上的「录 Ns」。
    var effectiveRecordingSeconds: Int {
        selectedShotMode?.recordingSeconds ?? settings.recordingSeconds
    }

    let engine: CameraEngine
    let storage: FileStorageService
    /// 模板自动处理引擎（与嘉宾模式同款流程）。
    let processingEngine = VideoProcessingEngine()
    /// 转台起转自动开拍（当前活动开了开关时，待机状态监听）。
    let motionTrigger = MotionTriggerService()
    @ObservationIgnored var uploadQueue: UploadQueue?
    /// 蓝牙转台（当前活动开了旋转开关时：录制开始转、录完停）。
    @ObservationIgnored weak var turntable: TurntableService?
    /// 远程控制桥（电脑控制台看状态 / 远程开拍）。
    @ObservationIgnored weak var hub: RemoteControlHub?

    @ObservationIgnored var modelContext: ModelContext?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    /// 管理员端自己的相机配置（嘉宾模式会改 engine 配置，退出后据此还原）。
    @ObservationIgnored private var adminConfiguration = CameraConfiguration.phase1Default

    init(engine: CameraEngine, storage: FileStorageService) {
        self.engine = engine
        self.storage = storage
    }

    var isBusy: Bool { phase != .idle || processingEngine.isBusy }

    // MARK: - 相机配置

    func configureCamera() async {
        await engine.configure(adminConfiguration)
        motionTrigger.onTrigger = { [weak self] in self?.startTapped() }
        updateAutomation()
    }

    /// 按「当前活动」的开关同步自动化：拍摄模式列表、Motion Trigger、转台预连、远程状态。
    private func updateAutomation() {
        let event = modelContext.flatMap { EventManager.activeEvent(in: $0) }

        let modes = event?.enabledShotModes ?? []
        if modes != shotModes {
            shotModes = modes
        }
        if selectedShotModeID == nil || !modes.contains(where: { $0.id == selectedShotModeID }) {
            selectedShotModeID = modes.first?.id
        }

        if phase == .idle, review == nil, !processingEngine.isBusy,
           event?.motionTriggerEnabled == true, engine.status == .running {
            motionTrigger.start()
        } else {
            motionTrigger.stop()
        }

        if event?.turntableSpinEnabled == true {
            turntable?.reconnectRememberedIfNeeded()
        }

        // 电脑控制台的状态行（嘉宾模式开着时由嘉宾流程接管）
        if hub?.guestActive != true {
            hub?.guestPhaseText = Self.phaseText(phase: phase, review: review != nil,
                                                 processing: processingEngine.isBusy)
        }
    }

    private static func phaseText(phase: Phase, review: Bool, processing: Bool) -> String {
        if review { return "确认成片中" }
        if processing { return "处理中" }
        switch phase {
        case .idle: return "待机"
        case .countingDown(let n): return "倒数 \(n)"
        case .recording: return "录制中"
        case .saving: return "保存中"
        }
    }

    func changeLens(_ lens: CameraLens) {
        guard phase == .idle else { return }
        adminConfiguration.lens = lens
        Task { [adminConfiguration] in await engine.configure(adminConfiguration) }
    }

    func changeFrameRate(_ frameRate: CaptureFrameRate) {
        guard phase == .idle else { return }
        adminConfiguration.frameRate = frameRate
        Task { [adminConfiguration] in await engine.configure(adminConfiguration) }
    }

    func changeResolution(_ resolution: CaptureResolution) {
        guard phase == .idle else { return }
        adminConfiguration.resolution = resolution
        Task { [adminConfiguration] in await engine.configure(adminConfiguration) }
    }

    // MARK: - 拍摄流程

    func startTapped() {
        guard phase == .idle, !processingEngine.isBusy, review == nil,
              engine.status == .running else { return }
        lastSavedClip = nil
        errorMessage = nil

        let countdown = settings.countdownSeconds
        countdownTask = Task { [weak self] in
            guard let self else { return }
            if countdown > 0 {
                for remaining in stride(from: countdown, through: 1, by: -1) {
                    self.phase = .countingDown(remaining)
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        self.phase = .idle
                        return
                    }
                }
            }
            await self.beginRecording()
        }
    }

    /// 倒数阶段可取消；录制阶段调用则提前停止（片段仍会保存）。
    func cancelOrStopTapped() {
        switch phase {
        case .countingDown:
            countdownTask?.cancel()
            countdownTask = nil
            phase = .idle
        case .recording:
            engine.stopRecording()
        default:
            break
        }
    }

    private func beginRecording() async {
        let url = storage.newSourceClipURL()
        recordingElapsedSeconds = 0
        // 当前活动开了转台旋转 → 录制起转、录完停
        let spinEnabled = modelContext
            .flatMap { EventManager.activeEvent(in: $0) }?.turntableSpinEnabled == true
        if spinEnabled { turntable?.sendStart() }
        phase = .recording
        startElapsedTicker()

        let freeGB = Double(storage.availableDiskSpaceInBytes()) / 1_000_000_000
        AppLogger.storage.info("录制前可用空间 \(String(format: "%.1f", freeGB), privacy: .public) GB")

        do {
            let info = try await engine.startRecording(to: url, maxSeconds: effectiveRecordingSeconds)
            if spinEnabled { turntable?.sendStop() }
            elapsedTask?.cancel()
            phase = .saving
            let clip = saveClipRecord(info)
            phase = .idle
            // 有「当前活动」→ 按模板自动处理并弹成片确认（与嘉宾模式同一逻辑）
            if let clip {
                await autoProcessWithActiveEvent(clip: clip, sourceURL: info.url)
            }
        } catch {
            if spinEnabled { turntable?.sendStop() }
            elapsedTask?.cancel()
            phase = .idle
            storage.deleteFileIfExists(at: url)
            errorMessage = (error as? CameraError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startElapsedTicker() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase == .recording else { return }
                self.recordingElapsedSeconds += 1
            }
        }
    }

    @discardableResult
    private func saveClipRecord(_ info: RecordedClipInfo) -> SourceClip? {
        guard let modelContext else {
            AppLogger.storage.error("modelContext 未注入，片段元数据未入库（文件已保留）")
            return nil
        }
        let clip = SourceClip(
            fileName: info.url.lastPathComponent,
            durationSeconds: info.durationSeconds,
            width: info.width,
            height: info.height,
            frameRate: info.frameRate,
            lensRawValue: info.lens.rawValue
        )
        modelContext.insert(clip)
        do {
            try modelContext.save()
            AppLogger.storage.info("片段已入库: \(clip.fileName, privacy: .public)")
        } catch {
            // 入库失败不丢文件：文件已在 SourceClips/，启动时 LibraryReconciler 会兜底补录
            AppLogger.storage.error("SwiftData 保存失败: \(error.localizedDescription, privacy: .public)")
            errorMessage = "片段文件已保存，但元数据入库失败：\(error.localizedDescription)"
        }
        return clip
    }

    // MARK: - 模板自动处理（拍完 → 处理中 → 成片确认）

    private func autoProcessWithActiveEvent(clip: SourceClip, sourceURL: URL) async {
        guard let modelContext, let event = EventManager.activeEvent(in: modelContext) else {
            // 没有当前活动：退回"已保存 + 处理/预览"手动入口
            lastSavedClip = clip
            return
        }
        let manager = EventManager(storage: storage)
        let overlayImage = manager.loadImage(event: event, fileName: event.overlayFileName)
        let musicURL = manager.musicURL(event: event)
        var effect = event.effectSettings
        effect.overlayEnabled = effect.overlayEnabled && overlayImage != nil
        effect.musicEnabled = effect.musicEnabled && musicURL != nil
        // 选中的拍摄模式曲线优先于活动里的 speed/style
        effect.shotKindRaw = selectedShotMode?.kind.rawValue

        let outputURL = storage.newRenderURL()
        do {
            let result = try await processingEngine.export(VideoProcessingEngine.RenderRequest(
                sourceURL: sourceURL,
                settings: effect,
                overlayImage: overlayImage?.cgImage,
                overlayVideoURL: manager.overlayVideoURL(event: event),
                musicURL: musicURL,
                introURL: manager.introURL(event: event),
                outroURL: manager.outroURL(event: event),
                outputURL: outputURL
            ))
            let render = RenderedVideo(
                fileName: result.outputURL.lastPathComponent,
                durationSeconds: result.durationSeconds,
                width: Int(result.renderSize.width),
                height: Int(result.renderSize.height),
                settingsSummary: effect.summaryText,
                sourceClipID: clip.id,
                eventID: event.id
            )
            modelContext.insert(render)
            try? modelContext.save()
            review = ReviewPresentation(
                playerItem: AVPlayerItem(url: result.outputURL),
                render: render,
                eventName: event.name
            )
        } catch {
            if (error as? ProcessingError) == .cancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 成片确认：完成（保留；上传功能开着就自动进队列）。
    func reviewDone() {
        guard let review else { return }
        if let uploadQueue, uploadQueue.isEnabled {
            uploadQueue.enqueue(review.render)
        }
        self.review = nil
    }

    /// 成片确认：重拍（作废成品，源片保留）。
    func reviewRetake() {
        guard let review else { return }
        storage.deleteFileIfExists(at: storage.renderURL(fileName: review.render.fileName))
        modelContext?.delete(review.render)
        try? modelContext?.save()
        self.review = nil
    }

    func cancelProcessing() {
        processingEngine.cancel()
    }

    // MARK: - 手动控制

    /// 锁定开关切换时，先接管设备当前实际值，滑杆从现状出发。
    func willToggleLock(exposure: Bool = false, focus: Bool = false, whiteBalance: Bool = false) {
        let snapshot = engine.snapshotCurrentValues(base: manualControls)
        if exposure {
            manualControls.iso = snapshot.iso
            // 吸附到最近的快门档位，保证 Picker 有选中项
            manualControls.shutterSeconds = ManualControlState.shutterChoices.min {
                abs($0 - snapshot.shutterSeconds) < abs($1 - snapshot.shutterSeconds)
            } ?? snapshot.shutterSeconds
        }
        if focus {
            manualControls.lensPosition = snapshot.lensPosition
        }
        if whiteBalance {
            manualControls.temperature = snapshot.temperature
            manualControls.tint = snapshot.tint
        }
    }

    func applyManualControls() {
        engine.applyManualControls(manualControls)
    }
}
