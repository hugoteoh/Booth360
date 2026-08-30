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

    /// 把所有「未上传 / 上传失败」的成品自动排入队列。
    /// 触发点：App 启动、上传方式切换、COS 配置保存——用户永远不需要手动补传。
    func enqueueAllPending() {
        guard isEnabled else { return }
        let descriptor = FetchDescriptor<RenderedVideo>(
            predicate: #Predicate {
                $0.uploadStateRawValue == "none" || $0.uploadStateRawValue == "failed"
            }
        )
        guard let items = try? modelContext.fetch(descriptor), !items.isEmpty else { return }
        for item in items {
            nextRetryAt[item.id] = nil
            item.uploadAttempts = 0
            item.uploadState = .queued
            item.lastUploadError = nil
        }
        try? modelContext.save()
        AppLogger.storage.info("自动补传 \(items.count) 条历史成品")
        pump()
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
        guard let items = try? modelContext.fetch(descriptor), !items.isEmpty else {
            enqueueAllPending()
            return
        }
        for item in items where item.uploadState == .uploading {
            item.uploadState = .queued
        }
        try? modelContext.save()
        AppLogger.storage.info("上传队列恢复 \(items.count) 项")
        pump()
        // 顺带把从未上传过的也扫进来（例如拍摄时上传功能还没开）
        enqueueAllPending()
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
            publishCloudWallIfNeeded()
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

    /// 云端大屏开关（默认开，设置页可关）。
    static var cloudWallEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "booth360.cloudWallEnabled") == nil
                || UserDefaults.standard.bool(forKey: "booth360.cloudWallEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "booth360.cloudWallEnabled") }
    }

    /// 手动触发云端大屏刷新（隐藏/取消隐藏/删除成品后调用）。
    func republishWall() {
        publishCloudWallIfNeeded()
    }

    /// 删除整场活动时清理它的云端大屏/总览页面（4 个清单与页面文件，尽力而为）。
    func cleanupEventWall(eventID: UUID) {
        guard UploadMode.current == .cos else { return }
        let config = COSConfig.load()
        guard config.isComplete else { return }
        let folder = eventID.uuidString.lowercased()
        let keys = [
            "booth360/wall/\(folder)/wall.json",
            "booth360/wall/\(folder)/index.html",
            "booth360/wall/\(folder)/gallery.json",
            "booth360/wall/\(folder)/gallery.html",
        ]
        Task.detached {
            for key in keys {
                guard let url = COSSigner.signedURL(
                    config: config, objectKey: key, method: "delete", expiresSeconds: 600) else {
                    continue
                }
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.timeoutInterval = 30
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    /// 删除成品时清理它在 COS 上的对象（视频 / 落地页 / 二维码，尽力而为，不阻塞删除）。
    /// 调用后记得再调 republishWall() 让大屏节目单同步减掉这条。
    func cleanupRemoteObjects(id: UUID, fileName: String, wasUploaded: Bool) {
        guard wasUploaded, UploadMode.current == .cos else { return }
        let config = COSConfig.load()
        guard config.isComplete else { return }
        let baseKey = "booth360/\(id.uuidString.lowercased())"
        let keys = ["\(baseKey)/\(fileName)", "\(baseKey)/index.html", "\(baseKey)/qr.png"]
        Task.detached {
            for key in keys {
                guard let url = COSSigner.signedURL(
                    config: config, objectKey: key, method: "delete", expiresSeconds: 600) else {
                    continue
                }
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.timeoutInterval = 30
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    @ObservationIgnored private var wallPublishTask: Task<Void, Never>?
    @ObservationIgnored private var wallPublishQueued = false

    /// COS 模式且开关打开时，把最近 30 条已上传成品（未隐藏的）发布/刷新到云端大屏。
    /// 大屏跟着「当前活动」走：只发布当前活动的成品，切活动后重新发布即切换节目单。
    ///
    /// 发布是串行的：同一时间只跑一个发布任务，进行中再触发只置标记，
    /// 结束后用**最新**数据补发一次——避免并发发布时旧快照后写完、把已删条目写回节目单。
    private func publishCloudWallIfNeeded() {
        guard UploadMode.current == .cos, Self.cloudWallEnabled else { return }
        if wallPublishTask != nil {
            wallPublishQueued = true
            return
        }
        wallPublishTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.wallPublishQueued = false
                if let payload = self.buildWallPayload() {
                    await CloudWallPublisher.publish(
                        items: payload.items,
                        galleryItems: payload.all,
                        eventID: payload.eventID
                    )
                }
            } while self.wallPublishQueued
            self.wallPublishTask = nil
        }
    }

    /// 发布内容以调用瞬间的数据库状态为准（每轮补发都重新取，保证新鲜）。
    private func buildWallPayload()
        -> (items: [CloudWallPublisher.WallItem], all: [CloudWallPublisher.WallItem], eventID: UUID?)? {
        let predicate: Predicate<RenderedVideo>
        if let activeID = EventManager.activeEventID {
            predicate = #Predicate {
                $0.uploadStateRawValue == "done" && $0.hiddenFromWall == false
                    && $0.eventID == activeID
            }
        } else {
            predicate = #Predicate { $0.uploadStateRawValue == "done" && $0.hiddenFromWall == false }
        }
        var descriptor = FetchDescriptor<RenderedVideo>(
            predicate: predicate,
            sortBy: [SortDescriptor(\RenderedVideo.createdAt, order: .reverse)]
        )
        // 视频总览要全量（上限 500 防极端），大屏节目单取前 30
        descriptor.fetchLimit = 500
        let all = ((try? modelContext.fetch(descriptor)) ?? []).map { render in
            CloudWallPublisher.WallItem(
                id: render.id,
                createdAt: render.createdAt,
                fileName: render.fileName
            )
        }
        // 空列表也发布：切到还没拍的活动时，大屏回到「等待」画面而不是残留上一场
        return (items: Array(all.prefix(30)), all: all, eventID: EventManager.activeEventID)
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
