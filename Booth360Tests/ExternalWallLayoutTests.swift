import XCTest
import CoreGraphics
@testable import Booth360

final class ExternalWallLayoutTests: XCTestCase {
    private let accuracy: CGFloat = 0.000001
    private let fullHD = CGSize(width: 1920, height: 1080)

    func testModeNamesAndRawValuesMatchTheWebWall() {
        XCTAssertEqual(ExternalWallLayoutMode.allCases.map(\.rawValue), ["grid", "featured", "cinema"])
        XCTAssertEqual(ExternalWallLayoutMode.allCases.map(\.displayName), ["网格", "最新主打", "全屏轮播"])
        XCTAssertEqual(ExternalWallLayoutMode.allCases.map(\.id), ["grid", "featured", "cinema"])
    }

    func testAllLayoutsStayInsideDifferentScreensWithoutOverlappingVideosOrQRCodes() {
        let sizes = [fullHD, CGSize(width: 1280, height: 720), CGSize(width: 3840, height: 2160),
                     CGSize(width: 1024, height: 768), CGSize(width: 375, height: 812),
                     CGSize(width: 1080, height: 1920), CGSize(width: 2560, height: 720),
                     CGSize(width: 320, height: 100), CGSize(width: 100, height: 320)]
        for size in sizes {
            for mode in ExternalWallLayoutMode.allCases {
                for count in 1...10 {
                    for active in [-1, 0, min(count - 1, 7), Int.max] {
                        let placements = ExternalWallLayout.placements(size: size, count: count, activeIndex: active, mode: mode)
                        assertValid(placements, screen: size)
                        XCTAssertEqual(Set(placements.map(\.index)).count, placements.count)
                        XCTAssertTrue(placements.allSatisfy { $0.index >= 0 && $0.index < min(count, 8) })
                    }
                }
            }
        }
    }

    func testEmptyOrInvalidScreensHaveNoPlacements() {
        let invalidSizes = [CGSize.zero, CGSize(width: -1, height: 1080), CGSize(width: 1920, height: 0),
                            CGSize(width: CGFloat.nan, height: 1080), CGSize(width: 1920, height: CGFloat.infinity)]
        for mode in ExternalWallLayoutMode.allCases {
            XCTAssertTrue(ExternalWallLayout.placements(size: fullHD, count: 0, activeIndex: 0, mode: mode).isEmpty)
            XCTAssertTrue(ExternalWallLayout.placements(size: fullHD, count: -1, activeIndex: 0, mode: mode).isEmpty)
            for size in invalidSizes {
                XCTAssertTrue(ExternalWallLayout.placements(size: size, count: 8, activeIndex: 0, mode: mode).isEmpty)
            }
        }
    }

    func testEightGridItemsUseFourColumnsAndTwoSeparateRows() {
        let placements = ExternalWallLayout.placements(size: fullHD, count: 8, activeIndex: 0, mode: .grid)
        XCTAssertEqual(placements.count, 8)
        for column in 0..<4 {
            XCTAssertEqual(placements[column].videoFrame.minY, placements[0].videoFrame.minY, accuracy: accuracy)
            XCTAssertEqual(placements[column + 4].videoFrame.minY, placements[4].videoFrame.minY, accuracy: accuracy)
            XCTAssertEqual(placements[column].videoFrame.minX, placements[column + 4].videoFrame.minX, accuracy: accuracy)
        }
        XCTAssertLessThan(placements[0].videoFrame.maxY, placements[4].videoFrame.minY)
    }

    func testSparseGridKeepsEightItemVideoSizeAndCentersTheSingleRow() {
        let full = ExternalWallLayout.placements(size: fullHD, count: 8, activeIndex: 0, mode: .grid)
        for count in 1...4 {
            let sparse = ExternalWallLayout.placements(size: fullHD, count: count, activeIndex: 0, mode: .grid)
            XCTAssertEqual(sparse.count, count)
            XCTAssertEqual(sparse[0].videoFrame.size, full[0].videoFrame.size)
            XCTAssertEqual(sparse[0].videoFrame.midY, fullHD.height / 2, accuracy: accuracy)
            XCTAssertEqual(rowBounds(sparse).midX, fullHD.width / 2, accuracy: accuracy)
        }
    }

    func testPartialSecondGridRowIsCenteredIndependently() {
        for count in 5...7 {
            let placements = ExternalWallLayout.placements(size: fullHD, count: count, activeIndex: 0, mode: .grid)
            XCTAssertEqual(rowBounds(Array(placements.prefix(4))).midX, fullHD.width / 2, accuracy: accuracy)
            XCTAssertEqual(rowBounds(Array(placements.dropFirst(4))).midX, fullHD.width / 2, accuracy: accuracy)
        }
    }

    func testFeaturedHeroRemainsOnTheScreenAxisAndUsesTheSelectedItem() {
        let placements = ExternalWallLayout.placements(size: fullHD, count: 8, activeIndex: 3, mode: .featured)
        XCTAssertEqual(placements.count, 7, "主角加最多六张底部小卡")
        XCTAssertEqual(placements[0].index, 3)
        XCTAssertEqual(placements[0].videoFrame.midX, fullHD.width / 2, accuracy: accuracy)
        XCTAssertGreaterThan(placements[0].qrFrame.minX, placements[0].videoFrame.maxX)
        XCTAssertGreaterThan(placements[0].videoFrame.height, placements[1].videoFrame.height * 2)
        XCTAssertTrue(placements.dropFirst().allSatisfy { $0.videoFrame.minY > placements[0].videoFrame.maxY })
        XCTAssertEqual(placements.dropFirst().map(\.index), [0, 1, 2, 4, 5, 6])
    }

    func testCinemaShowsOnlyTheActivePortraitVideoAndACornerQRCode() {
        let placements = ExternalWallLayout.placements(size: fullHD, count: 8, activeIndex: 7, mode: .cinema)
        XCTAssertEqual(placements.count, 1)
        let current = placements[0]
        XCTAssertEqual(current.index, 7)
        XCTAssertEqual(current.videoFrame.midX, fullHD.width / 2, accuracy: accuracy)
        XCTAssertEqual(current.videoFrame.midY, fullHD.height / 2, accuracy: accuracy)
        XCTAssertEqual(current.videoFrame.height, fullHD.height * 0.9, accuracy: accuracy)
        XCTAssertGreaterThan(current.qrFrame.midX, fullHD.width * 0.75)
        XCTAssertGreaterThan(current.qrFrame.midY, fullHD.height * 0.75)
        XCTAssertEqual(current.qrFrame.width, 176, accuracy: accuracy)
    }

    func testFourKActuallyDoublesVideoAndQRSizesInsteadOfKeepingPixelCaps() {
        for mode in ExternalWallLayoutMode.allCases {
            let base = ExternalWallLayout.placements(size: fullHD, count: 8, activeIndex: 0, mode: mode)
            let fourK = ExternalWallLayout.placements(size: CGSize(width: 3840, height: 2160), count: 8, activeIndex: 0, mode: mode)
            XCTAssertEqual(base.count, fourK.count)
            for (small, large) in zip(base, fourK) {
                XCTAssertEqual(large.index, small.index)
                assertScaled(large.videoFrame, from: small.videoFrame, by: 2)
                assertScaled(large.qrFrame, from: small.qrFrame, by: 2)
            }
        }
    }

    func testInvalidActiveIndexFallsBackToTheFirstVisibleItem() {
        for mode in [ExternalWallLayoutMode.featured, .cinema] {
            for active in [-1, 8, Int.max] {
                let placements = ExternalWallLayout.placements(size: fullHD, count: 8, activeIndex: active, mode: mode)
                XCTAssertEqual(placements.first?.index, 0)
            }
        }
    }

    private func rowBounds(_ placements: [ExternalWallPlacement]) -> CGRect {
        placements.reduce(CGRect.null) { $0.union($1.videoFrame).union($1.qrFrame) }
    }

    private func assertValid(_ placements: [ExternalWallPlacement], screen: CGSize,
                             file: StaticString = #filePath, line: UInt = #line) {
        for placement in placements {
            for rect in [placement.videoFrame, placement.qrFrame] {
                XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite, file: file, line: line)
                XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
                XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
                XCTAssertGreaterThanOrEqual(rect.minX, screen.width * 0.03 - accuracy, file: file, line: line)
                XCTAssertGreaterThanOrEqual(rect.minY, screen.height * 0.03 - accuracy, file: file, line: line)
                XCTAssertLessThanOrEqual(rect.maxX, screen.width * 0.97 + accuracy, file: file, line: line)
                XCTAssertLessThanOrEqual(rect.maxY, screen.height * 0.97 + accuracy, file: file, line: line)
            }
            XCTAssertEqual(placement.videoFrame.width / placement.videoFrame.height, 9.0 / 16.0, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(placement.qrFrame.width, placement.qrFrame.height, accuracy: accuracy, file: file, line: line)
        }
        for first in placements.indices {
            for second in placements.indices where first < second {
                XCTAssertFalse(placements[first].videoFrame.intersects(placements[second].videoFrame), file: file, line: line)
                XCTAssertFalse(placements[first].qrFrame.intersects(placements[second].qrFrame), file: file, line: line)
            }
            for other in placements {
                XCTAssertFalse(placements[first].qrFrame.intersects(other.videoFrame), file: file, line: line)
            }
        }
    }

    private func assertScaled(_ actual: CGRect, from reference: CGRect, by factor: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, reference.minX * factor, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, reference.minY * factor, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, reference.width * factor, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, reference.height * factor, accuracy: accuracy, file: file, line: line)
    }
}
