import Foundation
import AVFoundation
import CoreGraphics
import Observation

/// 处理/导出总调度：倒放素材生成（带缓存）→ 时间轴合成 → 导出。
/// 全程可取消；进度 0…1（含倒放阶段权重 45%）。
@Observable
@MainActor
final class VideoProcessingEngine {

    enum Stage: Equatable {
        case idle
        case preparing
        case reversing
        case exporting
        case beautifying
        case failed(String)

        var displayText: String {
            switch self {
            case .idle: return ""
            case .preparing: return "正在准备视频…"
            case .reversing: return "正在生成倒放素材…"
            case .exporting: return "正在导出成品…"
            case .beautifying: return "正在美颜 / 滤镜处理…"
            case .failed(let message): return message
            }
        }
    }

    struct RenderRequest {
        let sourceURL: URL
        let settings: EffectSettings
        let overlayImage: CGImage?
        let overlayVideoURL: URL?
        let musicURL: URL?
        let introURL: URL?
        let outroURL: URL?
        let outputURL: URL

        init(
            sourceURL: URL,
            settings: EffectSettings,
            overlayImage: CGImage? = nil,
            overlayVideoURL: URL? = nil,
            musicURL: URL? = nil,
            introURL: URL? = nil,
            outroURL: URL? = nil,
            outputURL: URL
        ) {
            self.sourceURL = sourceURL
            self.settings = settings
            self.overlayImage = overlayImage
            self.overlayVideoURL = overlayVideoURL
            self.musicURL = musicURL
            self.introURL = introURL
            self.outroURL = outroURL
            self.outputURL = outputURL
        }
    }

    struct RenderResult {
        let outputURL: URL
        let durationSeconds: Double
        let renderSize: CGSize
    }

    // MARK: - 状态

    private(set) var stage: Stage = .idle
    private(set) var progress: Double = 0

    // 从第一次 await 之前持有，覆盖准备、预览、美颜和取消后的清理。
    private(set) var isBusy = false

    /// 原生导出回调/取消处理器会跨线程访问，独立对象避免闭包持有引擎。
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                cancelled = newValue
            }
        }
    }

    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private var exportSession: AVAssetExportSession?
    @ObservationIgnored private let reverser = ClipReverser()

    // MARK: - 对外入口

    /// 导出成品到 request.outputURL。
    func export(_ request: RenderRequest) async throws -> RenderResult {
        guard !isBusy else { throw ProcessingError.exportFailed("已有任务进行中") }
        let flag = beginWork()
        defer { isBusy = false }
        var outputStarted = false
        do {
            try checkCancellation(flag)
            let built = try await prepareComposition(
                request: request,
                overlayImage: request.settings.overlayEnabled ? request.overlayImage : nil,
                flag: flag
            )
            let needsPostFX = VideoPostFX.isNeeded(
                beautyEnabled: request.settings.beautyEnabled,
                filter: request.settings.filterPreset
            )
            try checkCancellation(flag)
            outputStarted = true
            let result = try await runExport(
                request: request, built: built, flag: flag,
                progressCeiling: needsPostFX ? 0.85 : 1.0
            )
            try checkCancellation(flag)
            if needsPostFX {
                stage = .beautifying
                let tmpURL = request.outputURL.deletingLastPathComponent()
                    .appendingPathComponent("postfx_\(request.outputURL.lastPathComponent)")
                do {
                    try await withTaskCancellationHandler(operation: {
                        try await VideoPostFX.apply(
                            inputURL: request.outputURL,
                            outputURL: tmpURL,
                            beautyStrength: request.settings.beautyStrength,
                            filter: request.settings.filterPreset,
                            codec: request.settings.codec,
                            progressHandler: { [weak self] value in
                                Task { @MainActor [weak self] in
                                    guard let self, self.cancelFlag === flag, self.isBusy else { return }
                                    self.progress = 0.85 + 0.15 * value
                                }
                            },
                            isCancelled: { flag.isCancelled }
                        )
                    }, onCancel: { flag.isCancelled = true })
                    try checkCancellation(flag)
                    try FileManager.default.removeItem(at: request.outputURL)
                    try FileManager.default.moveItem(at: tmpURL, to: request.outputURL)
                } catch {
                    // 后处理失败/取消：连同已导出的中间成品一起清掉，避免出现无记录的孤儿文件
                    try? FileManager.default.removeItem(at: tmpURL)
                    try? FileManager.default.removeItem(at: request.outputURL)
                    throw error
                }
            }
            try checkCancellation(flag)
            stage = .idle
            progress = 1
            return result
        } catch {
            let cancelled = flag.isCancelled || Task.isCancelled || error is CancellationError
            if cancelled, outputStarted { try? FileManager.default.removeItem(at: request.outputURL) }
            if cancelled { flag.isCancelled = true }
            let finalError: Error = cancelled ? ProcessingError.cancelled : error
            finishWithError(finalError, flag: flag)
            throw finalError
        }
    }

    /// 生成预览用 PlayerItem。静态图 Overlay 不出现在预览（animationTool 无法用于播放器）；
    /// 动态视频 Overlay、片头片尾在预览里都生效。
    /// 倒放/Boomerang 首次预览会先生成倒放素材（有进度），之后走缓存秒开。
    func makePreviewItem(_ request: RenderRequest) async throws -> AVPlayerItem {
        guard !isBusy else { throw ProcessingError.exportFailed("已有任务进行中") }
        let flag = beginWork()
        defer { isBusy = false }
        do {
            try checkCancellation(flag)
            let built = try await prepareComposition(request: request, overlayImage: nil, flag: flag)
            try checkCancellation(flag)
            stage = .idle
            progress = 0
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            return item
        } catch {
            if Task.isCancelled || error is CancellationError { flag.isCancelled = true }
            let finalError: Error = flag.isCancelled ? ProcessingError.cancelled : error
            finishWithError(finalError, flag: flag)
            throw finalError
        }
    }

    func cancel() {
        cancelFlag.isCancelled = true
        exportSession?.cancelExport()
    }

    // MARK: - 流程

    private func beginWork() -> CancelFlag {
        let flag = CancelFlag()
        cancelFlag = flag
        isBusy = true
        stage = .preparing
        progress = 0
        return flag
    }

    private func checkCancellation(_ flag: CancelFlag) throws {
        if flag.isCancelled || Task.isCancelled { throw ProcessingError.cancelled }
    }

    private func finishWithError(_ error: Error, flag: CancelFlag) {
        stage = flag.isCancelled ? .idle : .failed(error.localizedDescription)
        progress = 0
    }

    private func prepareComposition(
        request: RenderRequest,
        overlayImage: CGImage?,
        flag: CancelFlag
    ) async throws -> BuiltComposition {
        let settings = request.settings
        guard FileManager.default.fileExists(atPath: request.sourceURL.path) else {
            throw ProcessingError.sourceFileMissing
        }
        let originalAsset = AVURLAsset(url: request.sourceURL)
        guard let originalVideoTrack = try await originalAsset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let videoRange = try await originalVideoTrack.load(.timeRange)
        let clipDuration = videoRange.duration.seconds
        guard videoRange.isValid, videoRange.start.isNumeric,
              clipDuration.isFinite, clipDuration > 0 else { throw ProcessingError.noVideoTrack }
        try checkCancellation(flag)

        // 倒放素材（缓存：源片不可变，同名缓存永远有效）
        var reversedAsset: AVAsset?
        let reverseWeight = settings.needsReversedAsset ? 0.45 : 0.0
        if settings.needsReversedAsset {
            let cacheURL = Self.reversedCacheURL(for: request.sourceURL)
            if !FileManager.default.fileExists(atPath: cacheURL.path) {
                stage = .reversing
                try await reverser.reverse(
                    sourceURL: request.sourceURL,
                    outputURL: cacheURL,
                    progress: { [weak self] value in
                        Task { @MainActor [weak self] in
                            guard let self, self.cancelFlag === flag, self.isBusy else { return }
                            self.progress = value * reverseWeight
                        }
                    },
                    isCancelled: { flag.isCancelled }
                )
            }
            reversedAsset = AVURLAsset(url: cacheURL)
        }
        try checkCancellation(flag)

        let segments: [TimelineSegment]
        if let mode = settings.shotMode {
            segments = TimelineBuilder.build(
                mode: mode,
                clipDurationSeconds: clipDuration,
                loopCount: settings.loopCount
            )
        } else if let kind = settings.shotKind {
            segments = TimelineBuilder.build(
                kind: kind,
                clipDurationSeconds: clipDuration,
                loopCount: settings.loopCount
            )
        } else {
            segments = TimelineBuilder.build(
                clipDurationSeconds: clipDuration,
                effect: settings.speed,
                style: settings.style,
                loopCount: settings.loopCount
            )
        }

        func assetIfUsable(_ url: URL?, enabled: Bool) -> AVAsset? {
            guard enabled, let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return AVURLAsset(url: url)
        }

        let inputs = CompositionInputs(
            originalAsset: originalAsset,
            reversedAsset: reversedAsset,
            introAsset: assetIfUsable(request.introURL, enabled: settings.introEnabled),
            outroAsset: assetIfUsable(request.outroURL, enabled: settings.outroEnabled),
            overlayVideoAsset: assetIfUsable(request.overlayVideoURL, enabled: settings.overlayVideoEnabled),
            segments: segments,
            includeOriginalAudio: settings.originalAudioEnabled && settings.canUseOriginalAudio,
            musicAsset: assetIfUsable(request.musicURL, enabled: settings.musicEnabled),
            musicVolume: Float(settings.musicVolume),
            renderSize: settings.renderSize,
            outputFrameRate: 30
        )
        let built = try await CompositionBuilder.build(inputs, overlayImage: overlayImage)
        try checkCancellation(flag)
        return built
    }

    private func runExport(
        request: RenderRequest,
        built: BuiltComposition,
        flag: CancelFlag,
        progressCeiling: Double = 1.0
    ) async throws -> RenderResult {
        try checkCancellation(flag)
        stage = .exporting
        let baseProgress = request.settings.needsReversedAsset ? 0.45 : 0.0
        let span = progressCeiling - baseProgress

        try? FileManager.default.removeItem(at: request.outputURL)

        let preset = request.settings.codec == .hevc
            ? AVAssetExportPresetHEVCHighestQuality
            : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw ProcessingError.exportFailed("无法创建导出会话（预设不可用）")
        }
        session.outputURL = request.outputURL
        session.outputFileType = .mp4
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true
        exportSession = session

        // 进度轮询
        let pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let session = self.exportSession else { return }
                self.progress = baseProgress + span * Double(session.progress)
            }
        }

        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
        }, onCancel: { session.cancelExport() })
        pollTask.cancel()
        exportSession = nil
        try checkCancellation(flag)

        switch session.status {
        case .completed:
            let seconds = built.totalDuration.seconds
            AppLogger.processing.info("导出完成 \(request.outputURL.lastPathComponent, privacy: .public)，\(String(format: "%.1f", seconds), privacy: .public)s")
            return RenderResult(
                outputURL: request.outputURL,
                durationSeconds: seconds,
                renderSize: request.settings.renderSize
            )
        case .cancelled:
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ProcessingError.cancelled
        default:
            try? FileManager.default.removeItem(at: request.outputURL)
            throw ProcessingError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }
    }

    // MARK: - 倒放缓存

    /// Caches/ReversedClips/reversed_<源文件名>。系统可能清理 Caches，
    /// 清了也没关系——下次用到会自动重新生成。
    static func reversedCacheURL(for sourceURL: URL) -> URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReversedClips", isDirectory: true)
        if !FileManager.default.fileExists(atPath: cachesDir.path) {
            try? FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        }
        return cachesDir.appendingPathComponent("reversed_\(sourceURL.lastPathComponent)", isDirectory: false)
    }
}
