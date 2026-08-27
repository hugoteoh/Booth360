import XCTest
import CoreGraphics
@testable import Booth360

final class CropGeometryTests: XCTestCase {

    private let accuracy: CGFloat = 0.01

    /// iPhone 竖拍典型元数据：传感器 1920×1080 + 90° 旋转。
    private let portraitTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    private let landscape = CGSize(width: 1920, height: 1080)

    func testDisplaySizeForPortraitRecording() {
        let size = CropGeometry.displaySize(naturalSize: landscape, preferredTransform: portraitTransform)
        XCTAssertEqual(size.width, 1080, accuracy: accuracy)
        XCTAssertEqual(size.height, 1920, accuracy: accuracy)
    }

    func testDisplaySizeForLandscapeRecording() {
        let size = CropGeometry.displaySize(naturalSize: landscape, preferredTransform: .identity)
        XCTAssertEqual(size.width, 1920, accuracy: accuracy)
        XCTAssertEqual(size.height, 1080, accuracy: accuracy)
    }

    /// 竖拍源 → 9:16 输出：应该无缩放、内容原点落在 (0,0)。
    func testPortraitSourceTo916FitsExactly() {
        let renderSize = CGSize(width: 1080, height: 1920)
        let transform = CropGeometry.exportTransform(
            naturalSize: landscape, preferredTransform: portraitTransform, renderSize: renderSize)

        let mapped = CGRect(origin: .zero, size: landscape).applying(transform)
        XCTAssertEqual(mapped.minX, 0, accuracy: accuracy)
        XCTAssertEqual(mapped.minY, 0, accuracy: accuracy)
        XCTAssertEqual(mapped.width, 1080, accuracy: accuracy)
        XCTAssertEqual(mapped.height, 1920, accuracy: accuracy)
    }

    /// 横拍源 → 9:16 输出：等比放大铺满高度，水平居中裁切。
    func testLandscapeSourceTo916CenterCrops() {
        let renderSize = CGSize(width: 1080, height: 1920)
        let transform = CropGeometry.exportTransform(
            naturalSize: landscape, preferredTransform: .identity, renderSize: renderSize)

        let mapped = CGRect(origin: .zero, size: landscape).applying(transform)
        // 高度铺满 1920 → 缩放 1920/1080 = 1.7778 → 宽 3413.3
        XCTAssertEqual(mapped.height, 1920, accuracy: 0.5)
        XCTAssertEqual(mapped.width, 1920.0 / 1080.0 * 1920.0, accuracy: 0.5)
        // 水平居中：两侧超出量相等
        XCTAssertEqual(mapped.midX, renderSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(mapped.minY, 0, accuracy: 0.5)
    }

    /// 源中心必须映射到输出中心（任何画幅居中裁切的核心不变量）。
    func testCenterMapsToCenterForAllAspects() {
        let sourceCenter = CGPoint(x: landscape.width / 2, y: landscape.height / 2)
        for aspect in OutputAspect.allCases {
            let renderSize = EffectSettings.renderSize(aspect: aspect, resolution: .r1080)
            for (natural, preferred) in [(landscape, CGAffineTransform.identity),
                                         (landscape, portraitTransform)] {
                let transform = CropGeometry.exportTransform(
                    naturalSize: natural, preferredTransform: preferred, renderSize: renderSize)
                let mapped = sourceCenter.applying(transform)
                XCTAssertEqual(mapped.x, renderSize.width / 2, accuracy: 0.5,
                               "\(aspect) 水平中心偏移")
                XCTAssertEqual(mapped.y, renderSize.height / 2, accuracy: 0.5,
                               "\(aspect) 垂直中心偏移")
            }
        }
    }

    // MARK: - 输出尺寸

    func testRenderSizes() {
        XCTAssertEqual(EffectSettings.renderSize(aspect: .portrait916, resolution: .r1080),
                       CGSize(width: 1080, height: 1920))
        XCTAssertEqual(EffectSettings.renderSize(aspect: .landscape169, resolution: .r1080),
                       CGSize(width: 1920, height: 1080))
        XCTAssertEqual(EffectSettings.renderSize(aspect: .square11, resolution: .r1080),
                       CGSize(width: 1080, height: 1080))
        XCTAssertEqual(EffectSettings.renderSize(aspect: .portrait45, resolution: .r1080),
                       CGSize(width: 1080, height: 1350))
        XCTAssertEqual(EffectSettings.renderSize(aspect: .portrait916, resolution: .r720),
                       CGSize(width: 720, height: 1280))
    }

    func testRenderSizesAreEven() {
        for aspect in OutputAspect.allCases {
            for resolution in OutputResolution.allCases {
                let size = EffectSettings.renderSize(aspect: aspect, resolution: resolution)
                XCTAssertEqual(Int(size.width) % 2, 0, "\(aspect) \(resolution) 宽须为偶数")
                XCTAssertEqual(Int(size.height) % 2, 0, "\(aspect) \(resolution) 高须为偶数")
            }
        }
    }
}
