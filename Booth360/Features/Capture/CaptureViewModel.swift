import Foundation
import SwiftData
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

    // MARK: - 状态

    private(set) var phase: Phase = .idle
    private(set) var recordingElapsedSeconds: Int = 0
    /// 最近一次保存成功的片段（供 UI 弹提示）。
    private(set) var lastSavedClip: SourceClip?
    var errorMessage: String?

    var settings = RecordingSettings()
    var manualControls = ManualControlState()

    let engine: CameraEngine
    let storage: FileStorageService

    @ObservationIgnored var modelContext: ModelContext?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    /// 管理员端自己的相机配置（嘉宾模式会改 engine 配置，退出后据此还原）。
    @ObservationIgnored private var adminConfiguration = CameraConfiguration.phase1Default

    init(engine: CameraEngine, storage: FileStorageService) {
        self.engine = engine
        self.storage = storage
    }

    var isBusy: Bool { phase != .idle }

    // MARK: - 相机配置

    func configureCamera() async {
        await engine.configure(adminConfiguration)
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
        guard phase == .idle, engine.status == .running else { return }
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
        phase = .recording
        startElapsedTicker()

        let freeGB = Double(storage.availableDiskSpaceInBytes()) / 1_000_000_000
        AppLogger.storage.info("录制前可用空间 \(String(format: "%.1f", freeGB), privacy: .public) GB")

        do {
            let info = try await engine.startRecording(to: url, maxSeconds: settings.recordingSeconds)
            elapsedTask?.cancel()
            phase = .saving
            saveClipRecord(info)
            phase = .idle
        } catch {
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

    private func saveClipRecord(_ info: RecordedClipInfo) {
        guard let modelContext else {
            AppLogger.storage.error("modelContext 未注入，片段元数据未入库（文件已保留）")
            return
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
            lastSavedClip = clip
            AppLogger.storage.info("片段已入库: \(clip.fileName, privacy: .public)")
        } catch {
            // 入库失败不丢文件：文件已在 SourceClips/，下版可做启动时目录扫描兜底
            AppLogger.storage.error("SwiftData 保存失败: \(error.localizedDescription, privacy: .public)")
            errorMessage = "片段文件已保存，但元数据入库失败：\(error.localizedDescription)"
        }
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
