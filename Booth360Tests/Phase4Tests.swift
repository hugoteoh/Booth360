import XCTest
import CoreImage
@testable import Booth360

final class Phase4Tests: XCTestCase {

    // MARK: - SpinDetector（Motion Trigger 判定）

    func testTriggersAfterSustainedSpin() {
        var detector = SpinDetector()
        // 0.0s 起持续 2.0 rad/s，应在 sustain (0.5s) 后触发一次
        XCTAssertFalse(detector.process(rate: 2.0, at: 0.0))
        XCTAssertFalse(detector.process(rate: 2.0, at: 0.2))
        XCTAssertFalse(detector.process(rate: 2.0, at: 0.4))
        XCTAssertTrue(detector.process(rate: 2.0, at: 0.55), "持续超阈 0.5s 应触发")
    }

    func testBriefSpikeDoesNotTrigger() {
        var detector = SpinDetector()
        XCTAssertFalse(detector.process(rate: 3.0, at: 0.0))
        XCTAssertFalse(detector.process(rate: 0.1, at: 0.2), "回落即重置")
        XCTAssertFalse(detector.process(rate: 3.0, at: 0.4))
        XCTAssertFalse(detector.process(rate: 3.0, at: 0.6), "重新计时未到 0.5s 不触发")
        XCTAssertTrue(detector.process(rate: 3.0, at: 0.95))
    }

    func testBelowThresholdNeverTriggers() {
        var detector = SpinDetector()
        for i in 0..<100 {
            XCTAssertFalse(detector.process(rate: 0.8, at: Double(i) * 0.1))
        }
    }

    func testCooldownBlocksRetrigger() {
        var detector = SpinDetector()
        _ = detector.process(rate: 2.0, at: 0.0)
        XCTAssertTrue(detector.process(rate: 2.0, at: 0.6))
        // 冷却期（8s）内持续旋转不再触发
        XCTAssertFalse(detector.process(rate: 2.0, at: 1.0))
        XCTAssertFalse(detector.process(rate: 2.0, at: 5.0))
        // 冷却结束后重新累计 sustain 才触发
        XCTAssertFalse(detector.process(rate: 2.0, at: 9.0))
        XCTAssertTrue(detector.process(rate: 2.0, at: 9.6))
    }

    func testResetClearsState() {
        var detector = SpinDetector()
        _ = detector.process(rate: 2.0, at: 0.0)
        _ = detector.process(rate: 2.0, at: 0.6) // 已触发进入冷却
        detector.reset()
        XCTAssertFalse(detector.process(rate: 2.0, at: 1.0))
        XCTAssertTrue(detector.process(rate: 2.0, at: 1.6), "reset 后冷却清除")
    }

    // MARK: - HTTPRequestParser（局域网控制）

    func testParsesSimpleGet() {
        let request = HTTPRequestParser.parse("GET /api/status HTTP/1.1\r\nHost: x\r\n")
        XCTAssertEqual(request, ParsedHTTPRequest(method: "GET", path: "/api/status", query: [:]))
    }

    func testParsesQueryParameters() {
        let request = HTTPRequestParser.parse(
            "POST /api/guest/start?pin=1234&id=ABC HTTP/1.1\r\n")
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/api/guest/start")
        XCTAssertEqual(request?.query["pin"], "1234")
        XCTAssertEqual(request?.query["id"], "ABC")
    }

    func testParsesPercentEncoding() {
        let request = HTTPRequestParser.parse("GET /?name=%E6%B4%BB%E5%8A%A8 HTTP/1.1\r\n")
        XCTAssertEqual(request?.query["name"], "活动")
    }

    func testParsesValuelessParameter() {
        let request = HTTPRequestParser.parse("GET /a?flag HTTP/1.1\r\n")
        XCTAssertEqual(request?.query["flag"], "")
    }

    func testRejectsGarbage() {
        XCTAssertNil(HTTPRequestParser.parse(""))
        XCTAssertNil(HTTPRequestParser.parse("NOTHTTP"))
    }

    // MARK: - VideoPostFX（美颜/滤镜）

    func testPostFXKeepsFrameExtent() {
        let source = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        for preset in FilterPreset.allCases {
            let output = VideoPostFX.process(source, beautyStrength: 0.8, filter: preset)
            XCTAssertEqual(output.extent, source.extent, "\(preset.rawValue) 输出画幅必须不变")
        }
        // 强度 0 + 无滤镜 = 原样返回
        let untouched = VideoPostFX.process(source, beautyStrength: 0, filter: .none)
        XCTAssertEqual(untouched.extent, source.extent)
    }

    func testPostFXNeededLogic() {
        XCTAssertFalse(VideoPostFX.isNeeded(beautyEnabled: false, filter: .none))
        XCTAssertTrue(VideoPostFX.isNeeded(beautyEnabled: true, filter: .none))
        XCTAssertTrue(VideoPostFX.isNeeded(beautyEnabled: false, filter: .warm))
    }

    // MARK: - HexCommand（转台指令解析）

    func testHexParsingVariants() {
        XCTAssertEqual(HexCommand.parse("01"), Data([0x01]))
        XCTAssertEqual(HexCommand.parse("A5 01 5A"), Data([0xA5, 0x01, 0x5A]))
        XCTAssertEqual(HexCommand.parse("0xA5,0x01,0x5A"), Data([0xA5, 0x01, 0x5A]))
        XCTAssertEqual(HexCommand.parse("a5-01-5a"), Data([0xA5, 0x01, 0x5A]))
        XCTAssertEqual(HexCommand.parse("FFEE"), Data([0xFF, 0xEE]))
    }

    func testHexParsingRejectsInvalid() {
        XCTAssertNil(HexCommand.parse(""))
        XCTAssertNil(HexCommand.parse("XYZ"))
        XCTAssertNil(HexCommand.parse("1"), "奇数位数字不合法")
        XCTAssertNil(HexCommand.parse("0x1 0x2"), "单个半字节不合法")
    }

    // MARK: - OperatorProfile

    func testOperatorProfileRoundTrip() {
        let original = OperatorProfile(studioName: "妍妍乐摄影", contact: "138xxxx")
        AccountStore.save(original)
        XCTAssertEqual(AccountStore.load(), original)
        AccountStore.save(OperatorProfile())
    }
}
