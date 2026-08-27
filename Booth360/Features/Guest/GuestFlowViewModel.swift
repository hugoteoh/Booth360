import Foundation
import SwiftData
import AVFoundation
import UIKit
import Observation

/// 嘉宾模式流程状态机：
/// welcome → countingDown → recording → processing → result →（自动/手动）→ welcome
/// 任何失败 → failed（几秒后自动回 welcome，源视频已落盘不丢）。
@Observable
@MainActor
final class GuestFlowViewModel {

    enum Phase: Equatable {
        case welcome
        case countingDown(Int)
        case recording(remaining: Int)
        case processing
        case result
        case failed(String)
    }

    let event: EventTemplate
    let cameraEngine: CameraEngine
    let storage: FileStorageService
    let uploadQueue: UploadQueue
    let processingEngine = VideoProcessingEngine()
    let motionTrigger = MotionTriggerService()

    private(set) var phase: Phase = .welcome {
        didSet { phaseDidChange() }
    }
    private(set) var resultPlayer: AVPlayer?
    private(set) var currentRender: RenderedVideo?
    private(set) var autoReturnRemaining: Int = 0

    @ObservationIgnored var modelContext: ModelContext?
    /// 存储见底等禁录条件（由界面注入 monitor 判定）。
    @ObservationIgnored var blockedProvider: (() -> Bool)?
    /// 局域网控制桥（状态回写 + 远程开始）。
    @ObservationIgnored weak var hub: RemoteControlHub?
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var autoReturnTask: Task<Void, Never>?
    @ObservationIgnored private var loopObserver: NSObjectProtocol?

    init(
        event: EventTemplate,
        cameraEngine: CameraEngine,
        storage: FileStorageService,
        uploadQueue: UploadQueue
    ) {
        self.event = event
        self.cameraEngine = cameraEngine
        self.storage = storage
        self.uploadQueue = uploadQueue
    }

    /// 进入嘉宾模式：按活动配置重配相机，装好 Motion Trigger 与远程桥。
    func onAppear(modelContext: ModelContext) {
        self.modelContext = modelContext
        motionTrigger.onTrigger = { [weak self] in self?.startTapped() }
        hub?.guestActive = true
        phaseDidChange()
        Task { await cameraEngine.configure(event.cameraConfiguration) }
    }

    /// 退出嘉宾模式：停掉一切进行中的任务。
    func teardown() {
        flowTask?.cancel()
        autoReturnTask?.cancel()
        processingEngine.cancel()
        cameraEngine.stopRecording()
        motionTrigger.stop()
        cleanupResult()
        hub?.guestActive = false
        hub?.guestPhaseText = "未开启"
    }

    /// 阶段变化时同步 Motion Trigger 与远程状态。
    private func phaseDidChange() {
        hub?.guestPhaseText = Self.phaseText(phase)
        if phase == .welcome, event.motionTriggerEnabled {
            motionTrigger.start()
        } else {
            motionTrigger.stop()
        }
    }

    private static func phaseText(_ phase: Phase) -> String {
        switch phase {
        case .welcome: return "等待开始"
        case .countingDown(let n): return "倒数 \(n)"
        case .recording(let r): return "录制中（剩 \(r)s）"
        case .processing: return "处理中"
        case .result: return "展示成品"
        case .failed: return "出错"
        }
    }

    // MARK: - 交互入口

    /// Start：仅 welcome 且相机就绪时有效（防狂点）。按钮/Motion Trigger/远程控制共用。
    func startTapped() {
        guard phase == .welcome, cameraEngine.status == .running else { return }
        if blockedProvider?() == true { return }
        flowTask = Task { await runFlow() }
    }

    /// 倒数阶段取消。
    func cancelCountdown() {
        guard case .countingDown = phase else { return }
        flowTask?.cancel()
        flowTask = nil
        phase = .welcome
    }

    /// 重拍：丢弃当前结果展示（文件与记录都保留），直接重新走流程。
    func retakeTapped() {
        guard phase == .result else { return }
        cleanupResult()
        flowTask = Task { await runFlow() }
    }

    func doneTapped() {
        backToWelcome()
    }

    // MARK: - 主流程

    private func runFlow() async {
        autoReturnTask?.cancel()

        // 1. 倒数
        let countdown = event.countdownSeconds
        if countdown > 0 {
            for remaining in stride(from: countdown, through: 1, by: -1) {
                phase = .countingDown(remaining)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    phase = .welcome
                    return
                }
            }
        }

        // 2. 录制（自动停止由引擎 maxRecordedDuration 保证）
        let sourceURL = storage.newSourceClipURL()
        let totalSeconds = event.recordingSeconds
        phase = .recording(remaining: totalSeconds)
        let tickTask = Task { [weak self] in
            var remaining = totalSeconds
            while remaining > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, case .recording = self.phase else { return }
                remaining -= 1
                self.phase = .recording(remaining: max(0, remaining))
            }
        }

        var clipSaved = false
        do {
            let info = try await cameraEngine.startRecording(to: sourceURL, maxSeconds: totalSeconds)
            tickTask.cancel()

            // 3. 源片入库（先保住素材，处理失败也不丢）
            let clip = SourceClip(
                fileName: info.url.lastPathComponent,
                durationSeconds: info.durationSeconds,
                width: info.width,
                height: info.height,
                frameRate: info.frameRate,
                lensRawValue: info.lens.rawValue,
                eventID: event.id
            )
            modelContext?.insert(clip)
            try? modelContext?.save()
            clipSaved = true

            // 退出嘉宾模式（teardown）时不再继续后台处理；源片已保住
            if Task.isCancelled { return }

            // 4. 按活动配置处理
            phase = .processing
            let manager = EventManager(storage: storage)
            let overlayImage = manager.loadImage(event: event, fileName: event.overlayFileName)
            let musicURL = manager.musicURL(event: event)
            var settings = event.effectSettings
            settings.overlayEnabled = settings.overlayEnabled && overlayImage != nil
            settings.musicEnabled = settings.musicEnabled && musicURL != nil

            let outputURL = storage.newRenderURL()
            let result = try await processingEngine.export(VideoProcessingEngine.RenderRequest(
                sourceURL: info.url,
                settings: settings,
                overlayImage: overlayImage?.cgImage,
                overlayVideoURL: manager.overlayVideoURL(event: event),
                musicURL: musicURL,
                introURL: manager.introURL(event: event),
                outroURL: manager.outroURL(event: event),
                outputURL: outputURL
            ))

            // 5. 成品入库 + 自动进上传队列
            let render = RenderedVideo(
                fileName: result.outputURL.lastPathComponent,
                durationSeconds: result.durationSeconds,
                width: Int(result.renderSize.width),
                height: Int(result.renderSize.height),
                settingsSummary: settings.summaryText,
                sourceClipID: clip.id,
                eventID: event.id
            )
            modelContext?.insert(render)
            try? modelContext?.save()
            currentRender = render
            if uploadQueue.isEnabled {
                uploadQueue.enqueue(render)
            }

            // 6. 结果页（循环播放 + 自动返回倒计时）
            startResultPlayback(url: result.outputURL)
            phase = .result
            startAutoReturnCountdown()
        } catch {
            tickTask.cancel()
            if !clipSaved {
                // 录制阶段就失败：清掉半成品文件
                storage.deleteFileIfExists(at: sourceURL)
            }
            if Task.isCancelled { return }
            AppLogger.ui.error("嘉宾流程失败: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            autoReturnTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled, case .failed = self.phase else { return }
                self.backToWelcome()
            }
        }
    }

    // MARK: - 结果页

    private func startResultPlayback(url: URL) {
        let player = AVPlayer(url: url)
        resultPlayer = player
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
    }

    private func startAutoReturnCountdown() {
        autoReturnRemaining = event.autoReturnSeconds
        autoReturnTask?.cancel()
        autoReturnTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.phase == .result else { return }
                self.autoReturnRemaining -= 1
                if self.autoReturnRemaining <= 0 {
                    self.backToWelcome()
                    return
                }
            }
        }
    }

    private func backToWelcome() {
        cleanupResult()
        autoReturnTask?.cancel()
        phase = .welcome
    }

    private func cleanupResult() {
        resultPlayer?.pause()
        resultPlayer = nil
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = nil
        currentRender = nil
    }
}
