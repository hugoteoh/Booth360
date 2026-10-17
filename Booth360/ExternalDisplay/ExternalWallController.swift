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

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var storage: FileStorageService?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var busyProvider: (() -> Bool)?
    @ObservationIgnored private var playlist: [ExternalWallItem] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var connectedSessionID: String?
    @ObservationIgnored private var mainSceneActive = true
    @ObservationIgnored private var displayActive = false
    @ObservationIgnored private var wantsLatest = false
    @ObservationIgnored private var itemEnded = false
    @ObservationIgnored private var qrPayload: String?
    @ObservationIgnored private var failedIDs = Set<UUID>()
    @ObservationIgnored private var playlistEventID: UUID?

    init(defaults: UserDefaults = .standard) {
        preferences = defaults
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
            player.pause()
            if !isConnected || !isEnabled {
                clearPlayback()
                playlist = []
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
            clearPlayback()
            playlist = []
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
        let previousNewest = playlist.first?.id
        playlist = Array(renders.compactMap { render -> ExternalWallItem? in
            let url = storage.renderURL(fileName: render.fileName)
            guard storage.fileExists(at: url) else { return nil }
            let payload = render.uploadState == .done ? render.remoteURLString : nil
            return ExternalWallItem(id: render.id, eventName: name,
                                    createdAt: render.createdAt, videoURL: url,
                                    qrPayload: payload)
        }.prefix(8))
        failedIDs.formIntersection(Set(playlist.map(\.id)))
        if previousNewest != playlist.first?.id { wantsLatest = true }

        if let current = currentItem {
            if let updated = playlist.first(where: { $0.id == current.id && $0.videoURL == current.videoURL }) {
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
        let candidates = playlist.filter { !failedIDs.contains($0.id) }
        guard !candidates.isEmpty else {
            clearPlayback()
            statusText = playlist.isEmpty ? "等待当前活动的成片" : "暂无可播放的成片"
            return
        }
        if wantsLatest || currentItem == nil {
            wantsLatest = false
            if let latest = candidates.first, latest.id != currentItem?.id { present(latest) }
        } else if itemEnded {
            advanceOrLoop()
        }
        if let currentItem, qrPayload != currentItem.qrPayload { updateQRCode(currentItem.qrPayload) }
        // Handles items that fail during initial preparation (no end notification).
        if player.currentItem?.status == .failed { playbackFailed() }
    }

    private func updateQRCode(_ payload: String?) {
        qrPayload = payload
        qrImage = payload.flatMap { QRCodeGenerator.image(for: $0, sidePixels: 544) }
    }

    private func present(_ item: ExternalWallItem) {
        guard canRun, mayReplaceItem, !isPlaybackHeld else { return }
        currentItem = item
        itemEnded = false
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
        if mayReplaceItem { advanceOrLoop() }
        else { resumeCurrentPlayback() }
    }

    private func advanceOrLoop() {
        let candidates = playlist.filter { !failedIDs.contains($0.id) }
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
    }
}
