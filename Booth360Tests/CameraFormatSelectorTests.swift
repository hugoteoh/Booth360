import XCTest
@testable import Booth360

final class CameraFormatSelectorTests: XCTestCase {

    /// 模拟一台典型 iPhone 广角镜头的格式表。
    private let typicalFormats: [FormatCandidate] = [
        FormatCandidate(index: 0, width: 1280, height: 720, maxFrameRate: 60, isBinned: false, isMultiCamOnly: false),
        FormatCandidate(index: 1, width: 1920, height: 1080, maxFrameRate: 30, isBinned: false, isMultiCamOnly: false),
        FormatCandidate(index: 2, width: 1920, height: 1080, maxFrameRate: 60, isBinned: true, isMultiCamOnly: false),
        FormatCandidate(index: 3, width: 1920, height: 1080, maxFrameRate: 60, isBinned: false, isMultiCamOnly: false),
        FormatCandidate(index: 4, width: 1920, height: 1080, maxFrameRate: 240, isBinned: false, isMultiCamOnly: false),
        FormatCandidate(index: 5, width: 3840, height: 2160, maxFrameRate: 60, isBinned: false, isMultiCamOnly: false),
    ]

    func testSelects1080p60NonBinnedNearestRate() {
        let selection = CameraFormatSelector.select(
            from: typicalFormats, resolution: .hd1080, requestedFrameRate: 60)
        // 期望 index 3：非 binned 优先于 index 2，maxFrameRate 60 比 240 更贴近需求
        XCTAssertEqual(selection?.index, 3)
        XCTAssertEqual(selection?.frameRate, 60)
        XCTAssertEqual(selection?.didFallBack, false)
    }

    func testSelects4K60() {
        let selection = CameraFormatSelector.select(
            from: typicalFormats, resolution: .uhd4K, requestedFrameRate: 60)
        XCTAssertEqual(selection?.index, 5)
        XCTAssertEqual(selection?.didFallBack, false)
    }

    func testFallsBackTo30WhenOnly30Supported() {
        // 类似超广角只支持 1080p30 的情况
        let formats = [
            FormatCandidate(index: 0, width: 1920, height: 1080, maxFrameRate: 30, isBinned: false, isMultiCamOnly: false),
        ]
        let selection = CameraFormatSelector.select(
            from: formats, resolution: .hd1080, requestedFrameRate: 60)
        XCTAssertEqual(selection?.index, 0)
        XCTAssertEqual(selection?.frameRate, 30)
        XCTAssertEqual(selection?.didFallBack, true)
    }

    func testFallsBackFrom240Through120To60() {
        let formats = [
            FormatCandidate(index: 0, width: 1920, height: 1080, maxFrameRate: 60, isBinned: false, isMultiCamOnly: false),
        ]
        let selection = CameraFormatSelector.select(
            from: formats, resolution: .hd1080, requestedFrameRate: 240)
        XCTAssertEqual(selection?.frameRate, 60)
        XCTAssertEqual(selection?.didFallBack, true)
    }

    func testReturnsNilWhenResolutionMissing() {
        let selection = CameraFormatSelector.select(
            from: typicalFormats, resolution: .uhd4K, requestedFrameRate: 240)
        // 4K 只有 60fps 格式：应降级成功而不是 nil
        XCTAssertEqual(selection?.frameRate, 60)

        let none = CameraFormatSelector.select(
            from: [], resolution: .hd1080, requestedFrameRate: 60)
        XCTAssertNil(none)
    }

    func testExcludesMultiCamOnlyFormats() {
        let formats = [
            FormatCandidate(index: 0, width: 1920, height: 1080, maxFrameRate: 60, isBinned: false, isMultiCamOnly: true),
            FormatCandidate(index: 1, width: 1920, height: 1080, maxFrameRate: 60, isBinned: false, isMultiCamOnly: false),
        ]
        let selection = CameraFormatSelector.select(
            from: formats, resolution: .hd1080, requestedFrameRate: 60)
        XCTAssertEqual(selection?.index, 1)
    }

    func testBinnedChosenWhenOnlyOption() {
        let formats = [
            FormatCandidate(index: 0, width: 1920, height: 1080, maxFrameRate: 60, isBinned: true, isMultiCamOnly: false),
        ]
        let selection = CameraFormatSelector.select(
            from: formats, resolution: .hd1080, requestedFrameRate: 60)
        XCTAssertEqual(selection?.index, 0)
    }
}
