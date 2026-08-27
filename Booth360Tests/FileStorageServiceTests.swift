import XCTest
@testable import Booth360

final class FileStorageServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var storage: FileStorageService!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Booth360Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        storage = FileStorageService(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testEnsureDirectoriesCreatesAllDirectories() throws {
        try storage.ensureDirectoriesExist()
        for dir in FileStorageService.Directory.allCases {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: storage.url(for: dir).path, isDirectory: &isDirectory)
            XCTAssertTrue(exists, "\(dir.rawValue) 目录应存在")
            XCTAssertTrue(isDirectory.boolValue)
        }
        // 幂等：再跑一次不抛错
        XCTAssertNoThrow(try storage.ensureDirectoriesExist())
    }

    func testSourceClipFileNameFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 31
        components.hour = 14; components.minute = 30; components.second = 5
        let date = Calendar.current.date(from: components)!
        let uuid = UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000")!

        let name = FileStorageService.sourceClipFileName(date: date, uuid: uuid)

        XCTAssertEqual(name, "clip_20260731_143005_a1b2c3d4.mov")
    }

    func testNewSourceClipURLLandsInSourceClipsDirectory() {
        let url = storage.newSourceClipURL()
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            storage.url(for: .sourceClips).standardizedFileURL
        )
        XCTAssertEqual(url.pathExtension, "mov")
    }

    func testUniqueFileNamesForSameTimestamp() {
        let date = Date()
        let nameA = FileStorageService.sourceClipFileName(date: date, uuid: UUID())
        let nameB = FileStorageService.sourceClipFileName(date: date, uuid: UUID())
        XCTAssertNotEqual(nameA, nameB, "同秒两次录制不能互相覆盖")
    }

    func testFileNameRoundTrip() {
        let url = storage.newSourceClipURL()
        let resolved = storage.sourceClipURL(fileName: url.lastPathComponent)
        XCTAssertEqual(url.standardizedFileURL, resolved.standardizedFileURL)
    }

    func testDeleteFileIfExists() throws {
        try storage.ensureDirectoriesExist()
        let url = storage.newSourceClipURL()
        try Data("fake video".utf8).write(to: url)
        XCTAssertTrue(storage.fileExists(at: url))
        XCTAssertGreaterThan(storage.fileSizeInBytes(at: url), 0)

        storage.deleteFileIfExists(at: url)
        XCTAssertFalse(storage.fileExists(at: url))

        // 对不存在的文件调用不抛错
        storage.deleteFileIfExists(at: url)
    }
}
