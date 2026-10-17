import XCTest
import SwiftData
import AVFoundation
@testable import Booth360

/// 覆盖活动 → 拍摄快照 → 重新编辑的参数传递；不配置或启动相机。
@MainActor
final class ShotModeFlowTests: XCTestCase {
    private var tempRoot: URL!
    private var storage: FileStorageService!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var readingContexts: [ModelContext] = []

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotModeFlowTests-\(UUID().uuidString)", isDirectory: true)
        storage = FileStorageService(rootURL: tempRoot)
        try storage.ensureDirectoriesExist()
        let schema = Schema([EventTemplate.self, SourceClip.self, RenderedVideo.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDownWithError() throws {
        readingContexts.removeAll()
        context = nil
        container = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCustomModeAndPreferredSelectionSurviveSaveAndFreshContextFetch() throws {
        let event = EventTemplate(name: "自定义节奏活动")
        let custom = adjustedMode(kind: .doubleSlow, recordingSeconds: 16)
        replaceMode(custom, in: event)
        event.selectShotMode(custom)
        context.insert(event)
        try context.save()

        // 使用新 context，避免只验证同一个 @Model 实例的内存值。
        let reloaded = try fetchEvent(event.id, in: freshReadingContext())
        let savedMode = try XCTUnwrap(reloaded.shotModes.first { $0.id == custom.id })
        XCTAssertEqual(savedMode, custom)
        XCTAssertEqual(reloaded.preferredShotMode, custom)
        XCTAssertEqual(reloaded.effectSettings.shotMode, custom)
        XCTAssertEqual(reloaded.effectSettings.shotKindRaw, custom.kindRaw)
        XCTAssertEqual(reloaded.resolvedEffectSettings().shotMode, custom)
    }

    func testPreferredSelectionUsesCurrentLibraryAndFallsBackWhenDisabled() throws {
        let event = EventTemplate(name: "选择与禁用")
        var selected = adjustedMode(kind: .fastSlowFast, recordingSeconds: 9)
        replaceMode(selected, in: event)
        event.selectShotMode(selected)
        let selectedID = selected.id

        // 调节同一个库条目后，不能继续使用 effectSettings 里旧的选择快照。
        selected.recordingSeconds = 17
        selected.setPhaseRate(0.25, at: 1)
        replaceMode(selected, in: event)
        XCTAssertEqual(event.preferredShotMode, selected)
        XCTAssertEqual(event.preferredShotMode.id, selectedID)
        XCTAssertEqual(event.preferredShotMode.id, event.preferredShotMode.id)

        selected.enabled = false
        replaceMode(selected, in: event)
        let fallback = try XCTUnwrap(event.enabledShotModes.first)
        XCTAssertNotEqual(fallback.id, selectedID)
        XCTAssertEqual(event.preferredShotMode.id, fallback.id)
        XCTAssertTrue(event.preferredShotMode.enabled)
    }

    func testAllDisabledLegacyLibraryStillHasOneStableUsableFallback() {
        let event = EventTemplate(name: "旧活动全部禁用")
        var modes = event.shotModes
        for index in modes.indices { modes[index].enabled = false }
        event.shotModes = modes
        event.selectShotMode(modes[modes.count - 1])

        XCTAssertEqual(event.enabledShotModes.count, 1)
        XCTAssertTrue(event.preferredShotMode.enabled)
        XCTAssertEqual(event.preferredShotMode.id, modes[0].id)
        XCTAssertEqual(event.preferredShotMode.id, event.preferredShotMode.id)
    }

    func testChangingActivityDoesNotChangePersistedCapturedClipSnapshot() throws {
        let event = EventTemplate(name: "拍摄时的节奏")
        let captured = adjustedMode(kind: .slowFastSlow, recordingSeconds: 12)
        replaceMode(captured, in: event)
        event.selectShotMode(captured)
        let clip = makeClip(eventID: event.id, mode: captured)
        context.insert(event)
        context.insert(clip)
        try context.save()

        var changed = captured
        changed.recordingSeconds = 20
        changed.setPhaseDuration(7, at: 0)
        changed.setPhaseRate(4, at: 0)
        replaceMode(changed, in: event)
        try context.save()

        let reader = freshReadingContext()
        let savedEvent = try fetchEvent(event.id, in: reader)
        let savedClip = try fetchClip(clip.id, in: reader)
        XCTAssertEqual(savedEvent.preferredShotMode, changed)
        XCTAssertEqual(savedEvent.resolvedEffectSettings().shotMode, changed)
        XCTAssertEqual(savedEvent.resolvedEffectSettings(mode: captured).shotMode, captured)
        XCTAssertEqual(savedClip.capturedShotMode, captured)
        XCTAssertNotEqual(savedClip.capturedShotMode, savedEvent.preferredShotMode)
    }

    func testEditModelKeepsCapturedSnapshotAfterLoadingChangedEventLibrary() throws {
        let event = EventTemplate(name: "旧片段重新剪辑")
        let captured = adjustedMode(kind: .doubleSlow, recordingSeconds: 14)
        replaceMode(captured, in: event)
        event.selectShotMode(captured)
        let clip = makeClip(eventID: event.id, mode: captured)
        context.insert(event)
        context.insert(clip)

        var changed = captured
        changed.recordingSeconds = 6
        changed.resetTiming()
        replaceMode(changed, in: event)
        event.selectShotMode(changed)
        try context.save()

        let editor = EditViewModel(clip: clip, storage: storage)
        XCTAssertEqual(editor.editingShotMode, captured)
        editor.configureShotModes(in: context)
        XCTAssertEqual(editor.editingShotMode, captured)
        XCTAssertEqual(editor.settings.shotMode, captured)
        XCTAssertEqual(editor.settings.shotKindRaw, captured.kindRaw)
        XCTAssertEqual(editor.estimatedOutputSeconds, captured.estimatedOutputSeconds, accuracy: 0.000001)
        XCTAssertEqual(clip.capturedShotMode, captured)
    }

    func testLegacyClipWithoutSnapshotLoadsItsOwningActivityPreferredMode() throws {
        let event = EventTemplate(name: "旧源片兼容")
        let selected = adjustedMode(kind: .gradualSpeedUp, recordingSeconds: 18)
        replaceMode(selected, in: event)
        event.selectShotMode(selected)
        let clip = makeClip(eventID: event.id, mode: nil, duration: 18)
        context.insert(event)
        context.insert(clip)
        try context.save()

        XCTAssertNil(clip.capturedShotMode)
        let editor = EditViewModel(clip: clip, storage: storage)
        editor.configureShotModes(in: context)
        XCTAssertEqual(editor.editingShotMode, selected)
        XCTAssertEqual(editor.settings.shotMode, selected)
        XCTAssertEqual(editor.estimatedOutputSeconds, selected.estimatedOutputSeconds, accuracy: 0.000001)
        XCTAssertNil(clip.capturedShotMode, "加载活动参数不应补写或篡改旧源片快照")
    }

    func testEditEstimateScalesModeToTheActualShorterClipDuration() {
        let mode = ShotMode(kind: .slowFastSlow, enabled: true, recordingSeconds: 20)
        let clip = makeClip(eventID: nil, mode: mode, duration: 8)
        let editor = EditViewModel(clip: clip, storage: storage)

        // 20 秒模式默认成片 25 秒；实际只录了 8 秒时应为 10 秒。
        XCTAssertEqual(editor.editingShotMode, mode)
        XCTAssertEqual(editor.estimatedOutputSeconds, 10, accuracy: 0.000001)
    }

    func testGuestSelectionUsesSelectedModeLengthAndPersistsWithoutStartingCamera() throws {
        let event = EventTemplate(name: "嘉宾选择模式")
        event.recordingSeconds = 5 // 与模式时长故意不同，防止误用活动旧字段。
        let initial = adjustedMode(kind: .slowFastSlow, recordingSeconds: 8)
        let selected = adjustedMode(kind: .doubleSlow, recordingSeconds: 17)
        replaceMode(initial, in: event)
        replaceMode(selected, in: event)
        event.selectShotMode(initial)
        context.insert(event)
        try context.save()

        let camera = CameraEngine()
        let queue = UploadQueue(modelContext: context, storage: storage)
        let guest = GuestFlowViewModel(event: event, cameraEngine: camera, storage: storage, uploadQueue: queue)
        guest.modelContext = context
        XCTAssertEqual(guest.selectedShotMode.recordingSeconds, 8)

        guest.selectShotMode(selected)
        XCTAssertEqual(guest.selectedShotMode, selected)
        XCTAssertEqual(guest.selectedShotMode.recordingSeconds, 17)
        XCTAssertEqual(guest.phase, .welcome)
        XCTAssertEqual(camera.status, .idle)
        XCTAssertFalse(camera.session.isRunning)
        let reloaded = try fetchEvent(event.id, in: freshReadingContext())
        XCTAssertEqual(reloaded.preferredShotMode, selected)
    }

    func testGuestSelectionUsesLiveLibraryEntryAndIgnoresDisabledMode() throws {
        let event = EventTemplate(name: "嘉宾选择安全回退")
        let stale = adjustedMode(kind: .fastSlowFast, recordingSeconds: 7)
        var live = stale
        live.recordingSeconds = 19
        live.setPhaseRate(0.25, at: 1)
        replaceMode(live, in: event)
        var disabled = adjustedMode(kind: .doubleSlow, recordingSeconds: 13)
        disabled.enabled = false
        replaceMode(disabled, in: event)

        let camera = CameraEngine()
        let queue = UploadQueue(modelContext: context, storage: storage)
        let guest = GuestFlowViewModel(event: event, cameraEngine: camera, storage: storage, uploadQueue: queue)
        guest.selectShotMode(stale)
        XCTAssertEqual(guest.selectedShotMode, live)
        XCTAssertEqual(event.preferredShotMode, live)

        guest.selectShotMode(disabled)
        XCTAssertEqual(guest.selectedShotMode, live)
        XCTAssertEqual(event.preferredShotMode, live)
        XCTAssertEqual(guest.phase, .welcome)
        XCTAssertEqual(camera.status, .idle)
    }

    func testCaptureRefreshUsesNewActivityPreferenceAndReloadsEditedTimingWithoutStartingCamera() throws {
        let previousActiveID = EventManager.activeEventID
        defer { EventManager.activeEventID = previousActiveID }

        let eventA = EventTemplate(name: "活动 A")
        var selectedA = try XCTUnwrap(eventA.shotModes.first { $0.kind == .slowFastSlow })
        selectedA.recordingSeconds = 9
        selectedA.setPhaseDuration(4, at: 0)
        replaceMode(selectedA, in: eventA)
        let initialA = try XCTUnwrap(eventA.shotModes.first { $0.kind == .fastSlowFast })
        eventA.selectShotMode(initialA)

        let eventB = EventTemplate(name: "活动 B")
        var selectedB = try XCTUnwrap(eventB.shotModes.first { $0.kind == .doubleSlow })
        selectedB.recordingSeconds = 17
        selectedB.setPhaseRate(0.25, at: 1)
        replaceMode(selectedB, in: eventB)
        eventB.selectShotMode(selectedB)
        // 默认模式 ID 在活动间相同，旧选项在 B 中也合法；必须仍切到 B 自己的偏好。
        XCTAssertTrue(eventB.enabledShotModes.contains { $0.id == selectedA.id })
        context.insert(eventA)
        context.insert(eventB)
        try context.save()

        let camera = CameraEngine()
        let capture = CaptureViewModel(engine: camera, storage: storage)
        capture.modelContext = context
        EventManager.activeEventID = eventA.id
        capture.refreshActivityConfiguration()
        XCTAssertEqual(capture.selectedShotMode, initialA)

        capture.selectedShotModeID = selectedA.id
        XCTAssertEqual(capture.selectedShotMode, selectedA)
        XCTAssertEqual(capture.effectiveRecordingSeconds, 9)
        XCTAssertEqual(eventA.preferredShotMode.id, selectedA.id)

        EventManager.activeEventID = eventB.id
        capture.refreshActivityConfiguration()
        XCTAssertEqual(capture.selectedShotMode, selectedB)
        XCTAssertEqual(capture.effectiveRecordingSeconds, 17)

        var editedB = selectedB
        editedB.recordingSeconds = 19
        editedB.setPhaseDuration(8, at: 1)
        editedB.setPhaseRate(0.25, at: 3)
        replaceMode(editedB, in: eventB)
        try context.save()
        capture.refreshActivityConfiguration()

        XCTAssertEqual(capture.selectedShotModeID, selectedB.id)
        XCTAssertEqual(capture.selectedShotMode, editedB)
        XCTAssertEqual(capture.effectiveRecordingSeconds, 19)
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(camera.status, .idle)
        XCTAssertFalse(camera.session.isRunning)
    }

    private func adjustedMode(kind: ShotModeKind, recordingSeconds: Int) -> ShotMode {
        var mode = ShotMode(kind: kind, enabled: true, recordingSeconds: recordingSeconds)
        mode.setPhaseDuration(Double(recordingSeconds) * 0.4, at: 0)
        mode.setPhaseRate(0.25, at: 0)
        mode.setPhaseRate(3.25, at: mode.phaseRates.count - 1)
        return mode
    }

    private func replaceMode(_ mode: ShotMode, in event: EventTemplate) {
        var modes = event.shotModes
        guard let index = modes.firstIndex(where: { $0.kind == mode.kind }) else {
            XCTFail("测试模式必须存在于活动模式库")
            return
        }
        modes[index] = mode
        event.shotModes = modes
    }

    private func makeClip(eventID: UUID?, mode: ShotMode?, duration: Double? = nil) -> SourceClip {
        SourceClip(
            fileName: "test-\(UUID().uuidString).mov",
            durationSeconds: duration ?? Double(mode?.recordingSeconds ?? 10),
            width: 1080,
            height: 1920,
            frameRate: 60,
            lensRawValue: CameraLens.wide.rawValue,
            eventID: eventID,
            shotMode: mode
        )
    }

    private func fetchEvent(_ id: UUID, in reader: ModelContext) throws -> EventTemplate {
        let events = try reader.fetch(FetchDescriptor<EventTemplate>())
        return try XCTUnwrap(events.first { $0.id == id })
    }

    private func fetchClip(_ id: UUID, in reader: ModelContext) throws -> SourceClip {
        let clips = try reader.fetch(FetchDescriptor<SourceClip>())
        return try XCTUnwrap(clips.first { $0.id == id })
    }

    private func freshReadingContext() -> ModelContext {
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        // 保持 context 存活，直到断言结束，避免模型属性尚未读取时已释放 context。
        readingContexts.append(reader)
        return reader
    }
}
