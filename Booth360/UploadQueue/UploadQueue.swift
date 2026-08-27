import Foundation
import SwiftData
import Network
import Observation

enum UploadState: String {
    case none
    case queued
    case uploading
    case done
    case failed

    var displayName: String {
        switch self {
        case .none: return "未上传"
        case .queued: return "排队中"
        case .uploading: return "上传中…"
        case .done: return "已上传"
        case .failed: return "上传失败"
        }
    }

    var iconName: String {
        switch self {
        case .none: return "icloud.slash"
        case .queued: return "clock.arrow.circlepath"
        case .uploading: return "icloud.and.arrow.up"
        case .done: return "checkmark.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }
}

extension RenderedVideo {
    var uploadState: UploadState {
        get { UploadState(rawValue: uploadStateRawValue) ?? .none }
        set { uploadStateRawValue = newValue.rawValue }
    }
}

/// 上传队列：一次传一个，失败指数退避重试；断网自动暂停、联网自动续传；
/// App 重开时恢复未完成任务。队列内容直接以 RenderedVideo.uploadState 持久化。
@Observable
@MainActor
final class UploadQueue {

    private let modelContext: ModelContext
    private let storage: FileStorageService

    private(set) var isProcessing = false
    private(set) var isOnline = true
    /// 正在上传条目的进度 0…1（key 为 RenderedVideo.id）。
    private(set) var progressByID: [UUID: Double] = [:]

    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryFireDate: Date?
    /// 失败条目的下次重试时间（仅内存；重启后立即可重试）。
    @ObservationIgnored private var nextRetryAt: [UUID: Date] = [:]

    var isEnabled: Bool { UploadMode.current != .off }

    init(modelContext: ModelContext, storage: FileStorageService) {
        self.modelContext = modelContext
        self.storage = storage
        startNetworkMonitor()
    }

    // MARK: - 对外操作

    func enqueue(_ render: RenderedVideo) {
        guard isEnabled else { return }
        guard render.uploadState != .done, render.uploadState != .uploading else { return }
        render.uploadState = .queued
        render.lastUploadError = nil
        try? modelContext.save()
        pump()
    }

    /// 手动重试：清空退避计时立即入队。
    func retryNow(_ render: RenderedVideo) {
        nextRetryAt[render.id] = nil
        render.uploadAttempts = 0
        enqueue(render)
    }

    /// App 启动时调用：上次中断在 uploading 的回退为 queued，连同 queued/failed 一起继续。
    func resumePendingOnLaunch() {
        guard isEnabled else { return }
        let descriptor = FetchDescriptor<RenderedVideo>(
            predicate: #Predicate {
                $0.uploadStateRawValue == "uploading"
                    || $0.uploadStateRawValue == "queued"
                    || $0.uploadStateRawValue == "failed"
            }
        )
        guard let items = try? modelContext.fetch(descriptor), !items.isEmpty else { return }
        for item in items where item.uploadState == .uploading {
            item.uploadState = .queued
        }
        try? modelContext.save()
        AppLogger.storage.info("上传队列恢复 \(items.count) 项")
        pump()
    }

    // MARK: - 队列泵

    func pump() {
        guard isEnabled, isOnline || UploadMode.current == .mock, !isProcessing else { return }
        guard let next = nextItem() else { return }
        isProcessing = true
        Task { [weak self] in
            guard let self else { return }
            await self.process(next)
            self.isProcessing = false
            self.pump()
        }
    }

    private func nextItem() -> RenderedVideo? {
        let descriptor = FetchDescriptor<RenderedVideo>(
            predicate: #Predicate {
                $0.uploadStateRawValue == "queued" || $0.uploadStateRawValue == "failed"
            },
            sortBy: [SortDescriptor(\RenderedVideo.createdAt, order: .forward)]
        )
        guard let items = try? modelContext.fetch(descriptor) else { return nil }
        let now = Date()
        return items.first { item in
            guard item.uploadState == .failed else { return true }
            guard let fireAt = nextRetryAt[item.id] else { return true }
            return now >= fireAt
        }
    }

    private func process(_ render: RenderedVideo) async {
        guard let backend = makeBackend() else {
            render.uploadState = .failed
            render.lastUploadError = UploadError.notConfigured.localizedDescription
            try? modelContext.save()
            return
        }
        render.uploadState = .uploading
        progressByID[render.id] = 0
        try? modelContext.save()

        let fileURL = storage.renderURL(fileName: render.fileName)
        // 对象键沿用 AI PhotoBooth Pro 的组织方式
        let objectKey = "booth360/\(render.id.uuidString.lowercased())/\(render.fileName)"
        let renderID = render.id
        do {
            let downloadURL = try await backend.upload(
                fileURL: fileURL,
                objectKey: objectKey,
                progress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.progressByID[renderID] = value
                    }
                }
            )
            progressByID[renderID] = nil
            render.uploadState = .done
            render.remoteURLString = downloadURL.absoluteString
            render.lastUploadError = nil
            nextRetryAt[render.id] = nil
            try? modelContext.save()
            AppLogger.storage.info("上传完成: \(render.fileName, privacy: .public)")
        } catch {
            progressByID[renderID] = nil
            render.uploadAttempts += 1
            render.uploadState = .failed
            render.lastUploadError = error.localizedDescription
            try? modelContext.save()
            let delay = UploadBackoff.delaySeconds(attempt: render.uploadAttempts)
            nextRetryAt[render.id] = Date().addingTimeInterval(delay)
            AppLogger.storage.error("上传失败(第\(render.uploadAttempts)次): \(error.localizedDescription, privacy: .public)，\(Int(delay))s 后重试")
            scheduleRetry(after: delay)
        }
    }

    private func makeBackend() -> UploadBackend? {
        switch UploadMode.current {
        case .off:
            return nil
        case .mock:
            return MockUploadBackend()
        case .cos:
            let config = COSConfig.load()
            return config.isComplete ? TencentCOSBackend(config: config) : nil
        }
    }

    // MARK: - 重试定时

    /// 保留最早触发的一个定时器（多个失败项时不互相顶掉更早的重试）。
    private func scheduleRetry(after delay: Double) {
        let fireDate = Date().addingTimeInterval(delay)
        if let existing = retryFireDate, existing <= fireDate, retryTask != nil {
            return
        }
        retryTask?.cancel()
        retryFireDate = fireDate
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.retryFireDate = nil
            self.pump()
        }
    }

    // MARK: - 网络监听

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                if online, wasOffline {
                    AppLogger.storage.info("网络恢复，继续上传队列")
                    self.pump()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.hugoteoh.booth360.network-monitor"))
        pathMonitor = monitor
    }
}
