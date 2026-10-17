import AVFoundation
import XCTest
@testable import Booth360

/// Connection ownership must not create two TV players or let media routing
/// replace the dedicated display (and drop its QR). No camera/TV is started.
@MainActor
final class ExternalWallConnectionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var controller: ExternalWallController!

    override func setUpWithError() throws {
        suite = "ExternalWallTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        controller = ExternalWallController(defaults: defaults)
    }

    override func tearDownWithError() throws {
        controller = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testSecondDisplayCannotStealPlayerAndForeignDisconnectCannotStopFirst() {
        XCTAssertTrue(controller.connect(sessionID: "tv-one"))
        XCTAssertTrue(controller.connect(sessionID: "tv-one"), "Repeated lifecycle callbacks are safe")
        XCTAssertFalse(controller.connect(sessionID: "tv-two"))
        controller.disconnect(sessionID: "tv-two")
        XCTAssertTrue(controller.isConnected)
        controller.disconnect(sessionID: "tv-one")
        XCTAssertFalse(controller.isConnected)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertNil(controller.currentItem)
        XCTAssertNil(controller.qrImage)
        XCTAssertTrue(controller.connect(sessionID: "tv-two"), "A disconnected screen releases ownership")
    }

    func testExternalVideoStaysInsideTVSceneWithQRCodeInsteadOfTakingMediaRoute() {
        XCTAssertFalse(controller.player.allowsExternalPlayback)
        XCTAssertFalse(controller.player.usesExternalPlaybackWhileExternalScreenIsActive)
        XCTAssertTrue(controller.player.isMuted)
        XCTAssertEqual(controller.player.volume, 0)
        XCTAssertNil(controller.player.currentItem, "No local player or decoder until a real display has content")
    }

    func testDisablingDisplayClearsPlaybackAndPersistsWithoutDisconnectingSystemRoute() {
        XCTAssertTrue(controller.connect(sessionID: "tv"))
        controller.isEnabled = false
        XCTAssertTrue(controller.isConnected, "Only the system/user controls the AirPlay connection")
        XCTAssertNil(controller.player.currentItem)
        XCTAssertNil(controller.currentItem)
        XCTAssertNil(controller.qrImage)
        XCTAssertEqual(controller.player.rate, 0)
        let relaunched = ExternalWallController(defaults: defaults)
        XCTAssertFalse(relaunched.isEnabled)
        controller.isEnabled = true
        XCTAssertTrue(controller.isEnabled)
    }
}
