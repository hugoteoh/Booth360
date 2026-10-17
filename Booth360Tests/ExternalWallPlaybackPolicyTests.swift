import XCTest
@testable import Booth360

final class ExternalWallPlaybackPolicyTests: XCTestCase {
    private typealias Policy = ExternalWallPlaybackPolicy

    func testPlaybackAndReplacementRespectEveryBusyThermalCombination() {
        let expectations: [(Policy.ThermalLevel, Bool, Bool, Bool)] = [
            (.nominal, false, false, true),
            (.nominal, true, false, false),
            (.fair, false, false, true),
            (.fair, true, true, false),
            (.serious, false, true, false),
            (.serious, true, true, false),
            (.critical, false, true, false),
            (.critical, true, true, false),
        ]
        for (thermal, busy, shouldHold, mayReplace) in expectations {
            XCTAssertEqual(Policy.shouldHoldPlayback(isCaptureBusy: busy, thermal: thermal), shouldHold)
            XCTAssertEqual(Policy.mayReplaceItem(isCaptureBusy: busy, thermal: thermal), mayReplace)
        }
    }

    func testBusyNominalCanKeepTheCurrentVideoButCannotStartLoadingAnother() {
        XCTAssertFalse(Policy.shouldHoldPlayback(isCaptureBusy: true, thermal: .nominal))
        XCTAssertFalse(Policy.mayReplaceItem(isCaptureBusy: true, thermal: .nominal))
        XCTAssertTrue(Policy.mayReplaceItem(isCaptureBusy: false, thermal: .nominal))
    }

    func testRecoveringFromHeatUsesTheCurrentBusyState() {
        XCTAssertTrue(Policy.shouldHoldPlayback(isCaptureBusy: false, thermal: .serious))
        XCTAssertFalse(Policy.shouldHoldPlayback(isCaptureBusy: false, thermal: .fair))
        XCTAssertTrue(Policy.shouldHoldPlayback(isCaptureBusy: true, thermal: .fair))
        XCTAssertFalse(Policy.shouldHoldPlayback(isCaptureBusy: true, thermal: .nominal))
        XCTAssertFalse(Policy.mayReplaceItem(isCaptureBusy: true, thermal: .nominal))
    }

    func testEmptyPlaylistNeverProducesAnItem() {
        XCTAssertNil(Policy.selectNextID(currentID: nil, orderedIDs: []))
        XCTAssertNil(Policy.selectNextID(currentID: UUID(), orderedIDs: []))
    }

    func testNewPlaybackStartsAtTheNewestItem() {
        let newest = UUID()
        let older = UUID()
        XCTAssertEqual(Policy.selectNextID(currentID: nil, orderedIDs: [newest, older]), newest)
    }

    func testPlaylistKeepsOrderAndWrapsFromOldestBackToNewest() {
        let newest = UUID()
        let middle = UUID()
        let oldest = UUID()
        let order = [newest, middle, oldest]
        XCTAssertEqual(Policy.selectNextID(currentID: newest, orderedIDs: order), middle)
        XCTAssertEqual(Policy.selectNextID(currentID: middle, orderedIDs: order), oldest)
        XCTAssertEqual(Policy.selectNextID(currentID: oldest, orderedIDs: order), newest)
    }

    func testOneItemPlaylistLoopsTheSameItem() {
        let only = UUID()
        XCTAssertEqual(Policy.selectNextID(currentID: nil, orderedIDs: [only]), only)
        XCTAssertEqual(Policy.selectNextID(currentID: only, orderedIDs: [only]), only)
    }

    func testDeletingTheCurrentItemFallsBackToTheNewestRemainingItem() {
        let newest = UUID()
        let deletedCurrent = UUID()
        let oldest = UUID()
        XCTAssertEqual(Policy.selectNextID(currentID: deletedCurrent, orderedIDs: [newest, oldest]), newest)
    }

    func testDeletingTheUpcomingItemSkipsItWithoutChangingTheRemainingOrder() {
        let newest = UUID()
        let oldest = UUID()
        XCTAssertEqual(Policy.selectNextID(currentID: newest, orderedIDs: [newest, oldest]), oldest)
    }

    func testNewlyAddedItemBecomesTheNextNewestWhenThePlaylistWraps() {
        let added = UUID()
        let previouslyNewest = UUID()
        let oldest = UUID()
        let updated = [added, previouslyNewest, oldest]
        XCTAssertEqual(Policy.selectNextID(currentID: previouslyNewest, orderedIDs: updated), oldest)
        XCTAssertEqual(Policy.selectNextID(currentID: oldest, orderedIDs: updated), added)
        XCTAssertEqual(Policy.selectNextID(currentID: nil, orderedIDs: updated), added)
    }

    func testReorderedPlaylistUsesTheLatestSuppliedOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        XCTAssertEqual(Policy.selectNextID(currentID: first, orderedIDs: [third, first, second]), second)
        XCTAssertEqual(Policy.selectNextID(currentID: second, orderedIDs: [third, first, second]), third)
    }

    func testQRCodeCanArriveWithoutChangingThePlayingVideoIdentity() {
        let initial = ExternalWallItem(
            id: UUID(), eventName: "活动", createdAt: Date(timeIntervalSince1970: 100),
            videoURL: URL(fileURLWithPath: "/Renders/completed.mp4"), qrPayload: nil)
        var uploaded = initial
        uploaded.qrPayload = "https://booth360.yanyanle.com/booth360/\(initial.id.uuidString.lowercased())/index.html"
        XCTAssertEqual(uploaded.id, initial.id)
        XCTAssertEqual(uploaded.videoURL, initial.videoURL)
        XCTAssertNotEqual(uploaded, initial, "展示层应能检测到二维码变化，不必因此替换播放器素材")
        XCTAssertFalse(Policy.mayReplaceItem(isCaptureBusy: true, thermal: .nominal))
    }
}
