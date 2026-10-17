import AVFoundation
import Observation
import SwiftData
import UIKit

/// One read-only player for the television. Never creates a second camera preview,
/// changes the capture/audio session, serves HTTP, or exports another video.
@Observable
@MainActor
final class ExternalWallController {
    static let shared = ExternalWallController()
    private static let enabledKey = "booth360.externalWallEnabled"
    private static let layoutKey = "booth360.externalWallLayout"

    var layoutMode: ExternalWallLayoutMode {
        didSet {
            preferences.set(layoutMode.rawValue, forKey: Self.layoutKey)
            cancelCardImagePreparation()
            wantsLatest = true
            cycleBeganAt = Date()
            cinemaProgress = 0
            if canRun { refreshPlaylist() }
        }
    }

    var isEnabled: Bool {
        didSet {
            preferences.set(isEnabled, forKey: Self.enabledKey)
            updateRunningState()
        }
    }
    private(set) var isConnected = false
    private(set) var currentItem: ExternalWallItem?
    private(set) var qrImage: UIImage?
    private(set) var isPlaybackHeld = false
    private(set) var statusText = "尚未连接电视"
    private(set) var items: [ExternalWallItem] = []
    private(set) var posterImages: [UUID: UIImage] = [:]
    private(set) var qrImages: [UUID: UIImage] = [:]
    private(set) var cinemaProgress: Double = 0

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var storage: FileStorageService?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var busyProvider: (() -> Bool)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var cardImageTask: Task<Void, Never>?
    @ObservationIgnored private var cardImageGenerationID: UUID?
    @ObservationIgnored private let posterLoader = ExternalWallPosterLoader()
    @ObservationIgnored private var failedPosterIDs = Set<UUID>()
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var connectedSessionID: String?
    @ObservationIgnored private var mainSceneActive = true
    @ObservationIgnored private var displayActive = false
    @ObservationIgnored private var wantsLatest = false
    @ObservationIgnored private var itemEnded = false
    @ObservationIgnored private var qrPayload: String?
    @ObservationIgnored private var failedIDs = Set<UUID>()
    @ObservationIgnored private var playlistEventID: UUID?
    @ObservationIgnored private var cycleBeganAt = Date()

    init(defaults: UserDefaults = .standard) {
        preferences = defaults
        layoutMode = defaults.string(forKey: Self.layoutKey)
            .flatMap(ExternalWallLayoutMode.init(rawValue:)) ?? .grid
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        player.isMuted = true
        player.volume = 0
        // Media AirPlay would send only the MP4 and omit the adjacent QR. Keep
        // this player in the dedicated UIKit display scene instead.
        player.allowsExternalPlayback = false
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.actionAtItemEnd = .pause
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                self.playbackEnded()
            }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                self.playbackFailed()
            }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.enforceCapturePriority() }
        })
    }

    deinit {
        refreshTask?.cancel()
        cardImageTask?.cancel()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func configure(storage: FileStorageService, modelContext: ModelContext,
                   isCaptureBusy: @escaping () -> Bool) {
        self.storage = storage
        self.modelContext = modelContext
        busyProvider = isCaptureBusy
        updateRunningState()
    }

    /// A second display must never attach the same player to another layer.
    @discardableResult
    func connect(sessionID: String) -> Bool {
        guard connectedSessionID == nil || connectedSessionID == sessionID else { return false }
        connectedSessionID = sessionID
        isConnected = true
        displayActive = true
        updateRunningState()
        return true
    }

    func disconnect(sessionID: String) {
        guard connectedSessionID == sessionID else { return }
        connectedSessionID = nil
        isConnected = false
        displayActive = false
        updateRunningState()
    }

    func setDisplayActive(_ active: Bool, sessionID: String) {
        guard connectedSessionID == sessionID else { return }
        displayActive = active
        updateRunningState()
    }

    func setMainSceneActive(_ active: Bool) {
        mainSceneActive = active
        updateRunningState()
    }

    /// Called immediately by the capture UI on countdown/record/export changes.
    /// A warm phone holds the last frame; a cool phone keeps the existing single
    /// video running, but never loads a different video while capture is busy.
    func enforceCapturePriority() {
        guard canRun else { return }
        if !mayReplaceItem { cancelCardImagePreparation() }
        let hold = ExternalWallPlaybackPolicy.shouldHoldPlayback(
            isCaptureBusy: isCaptureBusy, thermal: thermalLevel)
        let wasHeld = isPlaybackHeld
        isPlaybackHeld = hold
        if hold {
            player.pause()
            statusText = "拍摄优先，电视暂留当前画面"
        } else {
            statusText = currentItem == nil ? "等待当前活动的成片" : "电视独立轮播中"
            if wasHeld { resumeCurrentPlayback() }
        }
    }

    private var canRun: Bool {
        isConnected && displayActive && isEnabled && mainSceneActive && modelContext != nil
    }
    private var isCaptureBusy: Bool { busyProvider?() ?? true }
    private var mayReplaceItem: Bool {
        ExternalWallPlaybackPolicy.mayReplaceItem(
            isCaptureBusy: isCaptureBusy, thermal: thermalLevel)
    }
    private var thermalLevel: ExternalWallPlaybackPolicy.ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    private func updateRunningState() {
        guard canRun else {
            refreshTask?.cancel()
            refreshTask = nil
            cancelCardImagePreparation()
            player.pause()
            if !isConnected || !isEnabled {
                clearPlayback()
                items = []
                posterImages = [:]
                qrImages = [:]
                failedPosterIDs = []
                failedIDs = []
            }
            if !isConnected { statusText = "尚未连接电视" }
            else if !isEnabled { statusText = "独立电视大屏已关闭" }
            else { statusText = "回到 Booth360 后继续播放" }
            return
        }
        enforceCapturePriority()
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshPlaylist()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { break }
            }
        }
        resumeCurrentPlayback()
    }

    private func refreshPlaylist() {
        guard canRun, let storage, let modelContext else { return }
        enforceCapturePriority()
        let activeID = EventManager.activeEventID
        if playlistEventID != activeID {
            cancelCardImagePreparation()
            clearPlayback()
            items = []
            posterImages = [:]
            qrImages = [:]
            failedPosterIDs = []
            failedIDs = []
            playlistEventID = activeID
            wantsLatest = true
            enforceCapturePriority()
        }
        // During capture/export, even database and file existence scans wait.
        // The already loaded video can keep playing without a new decoder.
        guard !isCaptureBusy, !isPlaybackHeld else { return }
        let predicate: Predicate<RenderedVideo>
        if let activeID {
            predicate = #Predicate { !$0.hiddenFromWall && $0.eventID == activeID }
        } else {
            predicate = #Predicate { !$0.hiddenFromWall }
        }
        var descriptor = FetchDescriptor<RenderedVideo>(
            predicate: predicate,
            sortBy: [SortDescriptor(\RenderedVideo.createdAt, order: .reverse)])
        descriptor.fetchLimit = 24
        guard let renders = try? modelContext.fetch(descriptor) else { return }
        let name = EventManager.activeEvent(in: modelContext)?.name ?? "Booth360"
        let previousNewest = items.first?.id
        let previousItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let updatedItems = Array(renders.compactMap { render -> ExternalWallItem? in
            let url = storage.renderURL(fileName: render.fileName)
            guard storage.fileExists(at: url) else { return nil }
            let payload = render.uploadState == .done ? render.remoteURLString : nil
            return ExternalWallItem(id: render.id, eventName: name,
                                    createdAt: render.createdAt, videoURL: url,
                                    qrPayload: payload)
        }.prefix(8))
        let updatedByID = Dictionary(uniqueKeysWithValues: updatedItems.map { ($0.id, $0) })
        posterImages = posterImages.filter { id, _ in
            guard let updated = updatedByID[id] else { return false }
            return previousItems[id]?.videoURL == updated.videoURL
        }
        qrImages = qrImages.filter { id, _ in
            guard let updated = updatedByID[id] else { return false }
            return previousItems[id]?.qrPayload == updated.qrPayload
        }
        items = updatedItems
        failedPosterIDs.formIntersection(Set(items.map(\.id)))
        failedIDs.formIntersection(Set(items.map(\.id)))
        if previousNewest != items.first?.id { wantsLatest = true }

        if let current = currentItem {
            if let updated = items.first(where: { $0.id == current.id && $0.videoURL == current.videoURL }) {
                // QR becomes available after upload without reloading video.
                currentItem = updated
                if qrPayload != updated.qrPayload {
                    qrImage = nil
                    if mayReplaceItem { updateQRCode(updated.qrPayload) }
                }
            } else {
                // Hidden/deleted videos and the previous activity leave the TV
                // immediately, even during a capture. Never show a stale QR.
                clearPlayback()
            }
        }
        guard mayReplaceItem, !isPlaybackHeld else { return }
        let candidates = items.filter { !failedIDs.contains($0.id) }
        guard !candidates.isEmpty else {
            clearPlayback()
            statusText = items.isEmpty ? "等待当前活动的成片" : "暂无可播放的成片"
            return
        }
        if wantsLatest || currentItem == nil {
            wantsLatest = false
            if let latest = candidates.first, latest.id != currentItem?.id { present(latest) }
        } else if itemEnded {
            advanceOrLoop()
        } else if layoutMode == .cinema, candidates.count > 1,
                  Date().timeIntervalSince(cycleBeganAt) >= 12 {
            advanceOrLoop()
        }
        cinemaProgress = min(1, max(0, Date().timeIntervalSince(cycleBeganAt) / 12))
        if let currentItem, qrPayload != currentItem.qrPayload { updateQRCode(currentItem.qrPayload) }
        // Handles items that fail during initial preparation (no end notification).
        if player.currentItem?.status == .failed { playbackFailed() }
        prepareCardImagesIfIdle()
    }

    private func updateQRCode(_ payload: String?) {
        qrPayload = payload
        guard let currentItem else { qrImage = nil; return }
        if let payload {
            let image = qrImages[currentItem.id] ?? QRCodeGenerator.image(for: payload, sidePixels: 544)
            qrImage = image
            qrImages[currentItem.id] = image
        } else {
            qrImage = nil
            qrImages[currentItem.id] = nil
        }
    }

    private func present(_ item: ExternalWallItem) {
        guard canRun, mayReplaceItem, !isPlaybackHeld else { return }
        currentItem = item
        itemEnded = false
        cycleBeganAt = Date()
        cinemaProgress = 0
        updateQRCode(item.qrPayload)
        let playerItem = AVPlayerItem(url: item.videoURL)
        playerItem.preferredForwardBufferDuration = 1
        player.replaceCurrentItem(with: playerItem)
        statusText = "电视独立轮播中"
        player.play()
    }

    private func playbackEnded() {
        itemEnded = true
        guard canRun, !isPlaybackHeld else { return }
        if mayReplaceItem, layoutMode == .grid { advanceOrLoop() }
        else { resumeCurrentPlayback() }
    }

    private func advanceOrLoop() {
        let candidates = items.filter { !failedIDs.contains($0.id) }
        guard let id = ExternalWallPlaybackPolicy.selectNextID(
            currentID: currentItem?.id, orderedIDs: candidates.map(\.id)),
              let next = candidates.first(where: { $0.id == id }) else {
            clearPlayback()
            statusText = "暂无可播放的成片"
            return
        }
        if currentItem?.id == next.id { resumeCurrentPlayback() }
        else { present(next) }
    }

    private func resumeCurrentPlayback() {
        guard canRun, !isPlaybackHeld, currentItem != nil else { return }
        if itemEnded {
            itemEnded = false
            player.seek(to: .zero)
        }
        player.play()
    }

    private func playbackFailed() {
        if let currentItem { failedIDs.insert(currentItem.id) }
        player.pause()
        itemEnded = true
        statusText = "正在跳过无法播放的成片"
        if mayReplaceItem, !isPlaybackHeld { advanceOrLoop() }
    }

    private func clearPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        qrImage = nil
        qrPayload = nil
        itemEnded = false
        isPlaybackHeld = false
        cinemaProgress = 0
    }

    /// Posters and per-card QRs are bounded to the visible eight items. Generate
    /// them sequentially only while idle; countdown/record/export cancels work.
    private func prepareCardImagesIfIdle() {
        guard canRun, mayReplaceItem, !isPlaybackHeld, layoutMode != .cinema,
              cardImageTask == nil else { return }
        let pending = items.filter {
            ($0.qrPayload != nil && qrImages[$0.id] == nil)
                || (posterImages[$0.id] == nil && !failedPosterIDs.contains($0.id))
        }
        guard !pending.isEmpty else { return }
        let generationID = UUID()
        cardImageGenerationID = generationID
        cardImageTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.cardImageGenerationID == generationID {
                    self.cardImageGenerationID = nil
                    self.cardImageTask = nil
                }
            }
            for snapshot in pending {
                guard !Task.isCancelled, self.cardImageGenerationID == generationID,
                      self.canRun, self.mayReplaceItem,
                      let item = self.items.first(where: { $0.id == snapshot.id && $0.videoURL == snapshot.videoURL })
                else { return }
                if let payload = item.qrPayload, self.qrImages[item.id] == nil {
                    self.qrImages[item.id] = QRCodeGenerator.image(for: payload, sidePixels: 544)
                }
                await Task.yield()
                guard !Task.isCancelled, self.cardImageGenerationID == generationID,
                      self.canRun, self.mayReplaceItem,
                      self.items.contains(where: { $0.id == item.id && $0.videoURL == item.videoURL })
                else { return }
                if self.posterImages[item.id] == nil && !self.failedPosterIDs.contains(item.id) {
                    do {
                        let image = try await self.posterLoader.image(for: item.videoURL)
                        guard !Task.isCancelled, self.cardImageGenerationID == generationID,
                              self.canRun, self.mayReplaceItem,
                              self.items.contains(where: { $0.id == item.id && $0.videoURL == item.videoURL })
                        else { return }
                        self.posterImages[item.id] = image
                    } catch {
                        guard !Task.isCancelled, self.cardImageGenerationID == generationID else { return }
                        self.failedPosterIDs.insert(item.id)
                    }
                }
                await Task.yield()
            }
        }
    }

    private func cancelCardImagePreparation() {
        cardImageGenerationID = nil
        cardImageTask?.cancel()
        cardImageTask = nil
        posterLoader.cancel()
    }
}
