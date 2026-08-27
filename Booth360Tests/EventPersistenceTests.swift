import XCTest
import SwiftData
@testable import Booth360

@MainActor
final class EventPersistenceTests: XCTestCase {

    private var tempRoot: URL!
    private var storage: FileStorageService!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: EventManager!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        storage = FileStorageService(rootURL: tempRoot)
        try storage.ensureDirectoriesExist()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: EventTemplate.self, configurations: config)
        context = ModelContext(container)
        manager = EventManager(storage: storage)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - EffectSettings 序列化

    func testEffectSettingsCodableRoundTrip() throws {
        var settings = EffectSettings()
        settings.speed = .slowFastSlow
        settings.style = .boomerang
        settings.loopCount = 2
        settings.musicEnabled = true
        settings.musicVolume = 0.65
        settings.aspect = .square11
        settings.codec = .h264

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EffectSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testEffectSettingsDecodesLegacyJSONMissingNewFields() throws {
        // Phase 2 时代的 JSON（没有 introEnabled/outroEnabled/overlayVideoEnabled 字段）
        let legacy = #"{"speed":"slowMotion","style":"reverse","loopCount":2,"overlayEnabled":true,"musicEnabled":true,"musicVolume":0.5,"originalAudioEnabled":false,"aspect":"square11","resolution":"r720","codec":"h264"}"#
        let decoded = try JSONDecoder().decode(EffectSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.speed, .slowMotion)
        XCTAssertEqual(decoded.style, .reverse)
        XCTAssertEqual(decoded.loopCount, 2)
        XCTAssertTrue(decoded.overlayEnabled)
        XCTAssertEqual(decoded.aspect, .square11)
        XCTAssertEqual(decoded.codec, .h264)
        // 新字段回落默认值，而不是整体解码失败
        XCTAssertTrue(decoded.introEnabled)
        XCTAssertTrue(decoded.outroEnabled)
        XCTAssertFalse(decoded.overlayVideoEnabled)
    }

    func testEventEffectSettingsAccessorFallsBackOnBadData() {
        let event = EventTemplate(name: "T", effectSettingsData: Data("垃圾数据".utf8))
        XCTAssertEqual(event.effectSettings, EffectSettings(), "坏数据应回落默认值而不是崩溃")
    }

    func testEventEffectSettingsWriteReadBack() {
        let event = EventTemplate(name: "T")
        var settings = event.effectSettings
        settings.style = .reverse
        settings.loopCount = 3
        event.effectSettings = settings
        XCTAssertEqual(event.effectSettings.style, .reverse)
        XCTAssertEqual(event.effectSettings.loopCount, 3)
    }

    // MARK: - EventManager

    func testCreateEventSetsActive() {
        EventManager.activeEventID = nil
        let event = manager.createEvent(named: "婚礼A", in: context)
        XCTAssertEqual(EventManager.activeEventID, event.id, "第一个活动自动设为当前")
        XCTAssertEqual(event.cameraConfiguration.frameRate, .fps60)
        XCTAssertEqual(event.recordingSettings.recordingSeconds, 15)
    }

    func testDuplicateCopiesFieldsAndAssets() throws {
        let event = manager.createEvent(named: "原活动", in: context)
        event.welcomeTitle = "自定义标题"
        event.recordingSeconds = 30
        var settings = event.effectSettings
        settings.style = .boomerang
        event.effectSettings = settings
        _ = try manager.importAsset(
            data: Data("fake png".utf8), kind: .overlay, into: event)

        let copy = manager.duplicate(event, in: context)

        XCTAssertEqual(copy.name, "原活动 副本")
        XCTAssertEqual(copy.welcomeTitle, "自定义标题")
        XCTAssertEqual(copy.recordingSeconds, 30)
        XCTAssertEqual(copy.effectSettings.style, .boomerang)
        XCTAssertEqual(copy.overlayFileName, "overlay.png")
        XCTAssertNotEqual(copy.id, event.id)
        // 素材文件真的复制到了新目录
        let copiedFile = manager.assetURL(event: copy, fileName: "overlay.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFile.path))
    }

    func testDeleteRemovesFolderAndClearsActive() throws {
        let event = manager.createEvent(named: "临时", in: context)
        _ = try manager.importAsset(data: Data("x".utf8), kind: .logo, into: event)
        let folder = manager.folderURL(for: event)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        EventManager.activeEventID = event.id
        manager.delete(event, in: context)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(EventManager.activeEventID)
    }

    func testImportMusicKeepsExtensionAndDisplayName() throws {
        let event = manager.createEvent(named: "音乐", in: context)
        let musicSource = tempRoot.appendingPathComponent("我的歌.mp3")
        try Data("fake mp3".utf8).write(to: musicSource)

        let fileName = try manager.importAsset(from: musicSource, kind: .music, into: event)

        XCTAssertEqual(fileName, "music.mp3")
        XCTAssertEqual(event.musicFileName, "music.mp3")
        XCTAssertEqual(event.musicDisplayName, "我的歌.mp3")
        XCTAssertNotNil(manager.musicURL(event: event))
    }
}
