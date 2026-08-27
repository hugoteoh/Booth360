import XCTest
@testable import Booth360

final class ControlClampTests: XCTestCase {

    private let limits = ManualControlLimits(
        minISO: 32,
        maxISO: 3200,
        minShutterSeconds: 1.0 / 8000.0,
        maxShutterSeconds: 1.0 / 3.0,
        minExposureBias: -8,
        maxExposureBias: 8,
        maxWhiteBalanceGain: 4
    )

    func testISOClamping() {
        XCTAssertEqual(ControlClamp.iso(10, limits: limits), 32)
        XCTAssertEqual(ControlClamp.iso(100, limits: limits), 100)
        XCTAssertEqual(ControlClamp.iso(99999, limits: limits), 3200)
    }

    func testShutterClamping() {
        XCTAssertEqual(ControlClamp.shutterSeconds(0, limits: limits), 1.0 / 8000.0)
        XCTAssertEqual(ControlClamp.shutterSeconds(1.0 / 120.0, limits: limits), 1.0 / 120.0)
        XCTAssertEqual(ControlClamp.shutterSeconds(5, limits: limits), 1.0 / 3.0)
    }

    func testExposureBiasClamping() {
        XCTAssertEqual(ControlClamp.exposureBias(-20, limits: limits), -8)
        XCTAssertEqual(ControlClamp.exposureBias(1.5, limits: limits), 1.5)
        XCTAssertEqual(ControlClamp.exposureBias(20, limits: limits), 8)
    }

    func testLensPositionClampedToUnitRange() {
        XCTAssertEqual(ControlClamp.lensPosition(-0.5), 0)
        XCTAssertEqual(ControlClamp.lensPosition(0.7), 0.7)
        XCTAssertEqual(ControlClamp.lensPosition(1.5), 1)
    }

    func testWhiteBalanceGainNeverBelowOneOrAboveMax() {
        XCTAssertEqual(ControlClamp.whiteBalanceGain(0.2, maxGain: 4), 1)
        XCTAssertEqual(ControlClamp.whiteBalanceGain(2.5, maxGain: 4), 2.5)
        XCTAssertEqual(ControlClamp.whiteBalanceGain(9, maxGain: 4), 4)
    }

    func testTemperatureAndTintClamping() {
        XCTAssertEqual(ControlClamp.temperature(1000), 2500)
        XCTAssertEqual(ControlClamp.temperature(5600), 5600)
        XCTAssertEqual(ControlClamp.temperature(20000), 8000)
        XCTAssertEqual(ControlClamp.tint(-500), -150)
        XCTAssertEqual(ControlClamp.tint(500), 150)
    }

    func testShutterLabel() {
        XCTAssertEqual(ManualControlState.shutterLabel(1.0 / 120.0), "1/120")
        XCTAssertEqual(ManualControlState.shutterLabel(1.0 / 60.0), "1/60")
    }
}
