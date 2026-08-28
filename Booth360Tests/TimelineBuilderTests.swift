import XCTest
@testable import Booth360

final class TimelineBuilderTests: XCTestCase {

    private let accuracy = 0.0001

    // MARK: - 变速分段

    func testNormalKeepsDuration() {
        let segments = TimelineBuilder.speedSegments(clipDurationSeconds: 10, effect: .normal)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].targetDurationSeconds, 10, accuracy: accuracy)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 10, accuracy: accuracy)
    }

    func testSlowMotionDoublesDuration() {
        let segments = TimelineBuilder.speedSegments(clipDurationSeconds: 10, effect: .slowMotion)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 20, accuracy: accuracy)
    }

    func testFastMotionHalvesDuration() {
        let segments = TimelineBuilder.speedSegments(clipDurationSeconds: 10, effect: .fastMotion)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 5, accuracy: accuracy)
    }

    func testSlowFastSlowStructure() {
        // 10 秒：前 2.5s 慢（→5s）+ 中 5s 快（→2.5s）+ 后 2.5s 慢（→5s）= 12.5s
        let segments = TimelineBuilder.speedSegments(clipDurationSeconds: 10, effect: .slowFastSlow)
        XCTAssertEqual(segments.count, 3)

        XCTAssertEqual(segments[0].sourceStartSeconds, 0, accuracy: accuracy)
        XCTAssertEqual(segments[0].sourceDurationSeconds, 2.5, accuracy: accuracy)
        XCTAssertEqual(segments[0].targetDurationSeconds, 5, accuracy: accuracy)

        XCTAssertEqual(segments[1].sourceStartSeconds, 2.5, accuracy: accuracy)
        XCTAssertEqual(segments[1].sourceDurationSeconds, 5, accuracy: accuracy)
        XCTAssertEqual(segments[1].targetDurationSeconds, 2.5, accuracy: accuracy)

        XCTAssertEqual(segments[2].sourceStartSeconds, 7.5, accuracy: accuracy)
        XCTAssertEqual(segments[2].sourceDurationSeconds, 2.5, accuracy: accuracy)
        XCTAssertEqual(segments[2].targetDurationSeconds, 5, accuracy: accuracy)

        // 源片段应无缝覆盖整个素材
        XCTAssertEqual(
            segments.reduce(0) { $0 + $1.sourceDurationSeconds }, 10, accuracy: accuracy)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 12.5, accuracy: accuracy)
    }

    // MARK: - 倒放映射

    func testReverseMirrorsSegments() {
        let segments = TimelineBuilder.build(
            clipDurationSeconds: 10, effect: .slowFastSlow, style: .reverse, loopCount: 1)
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments.allSatisfy { $0.source == .reversed })

        // 倒放第一段对应正放最后一段（原片 7.5–10s → 倒序素材 0–2.5s），仍是慢速
        XCTAssertEqual(segments[0].sourceStartSeconds, 0, accuracy: accuracy)
        XCTAssertEqual(segments[0].sourceDurationSeconds, 2.5, accuracy: accuracy)
        XCTAssertEqual(segments[0].targetDurationSeconds, 5, accuracy: accuracy)

        // 中段（原片 2.5–7.5s → 倒序素材 2.5–7.5s），快速
        XCTAssertEqual(segments[1].sourceStartSeconds, 2.5, accuracy: accuracy)
        XCTAssertEqual(segments[1].targetDurationSeconds, 2.5, accuracy: accuracy)

        // 总时长与正放一致
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 12.5, accuracy: accuracy)
    }

    func testBoomerangIsForwardPlusReversed() {
        let segments = TimelineBuilder.build(
            clipDurationSeconds: 8, effect: .normal, style: .boomerang, loopCount: 1)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].source, .original)
        XCTAssertEqual(segments[1].source, .reversed)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 16, accuracy: accuracy)
    }

    func testLoopRepeatsTimeline() {
        let segments = TimelineBuilder.build(
            clipDurationSeconds: 6, effect: .fastMotion, style: .boomerang, loopCount: 3)
        // 单次 boomerang = 2 段，×3 = 6 段；时长 = (3+3) × 3 = 18
        XCTAssertEqual(segments.count, 6)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 18, accuracy: accuracy)
    }

    // MARK: - 拍摄模式曲线

    func testSlowGlideCurve() {
        // 常-慢-常：9s → 3+6+3 = 12s，源区间无缝覆盖
        let segments = TimelineBuilder.build(kind: .slowGlide, clipDurationSeconds: 9, loopCount: 1)
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments.allSatisfy { $0.source == .original })
        XCTAssertEqual(segments[0].targetDurationSeconds, 3, accuracy: accuracy)
        XCTAssertEqual(segments[1].targetDurationSeconds, 6, accuracy: accuracy)
        XCTAssertEqual(segments[2].targetDurationSeconds, 3, accuracy: accuracy)
        XCTAssertEqual(segments[1].sourceStartSeconds, 3, accuracy: accuracy)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 12, accuracy: accuracy)
    }

    func testRushbackCurveWithMidReverse() {
        // 常-快-回旋-慢-快：8s；倒放段对应原片 [2,4]，在倒序素材中起点 = 8-4 = 4
        let segments = TimelineBuilder.build(kind: .rushback, clipDurationSeconds: 8, loopCount: 1)
        XCTAssertEqual(segments.count, 5)
        let reversed = segments[2]
        XCTAssertEqual(reversed.source, .reversed)
        XCTAssertEqual(reversed.sourceStartSeconds, 4, accuracy: accuracy)
        XCTAssertEqual(reversed.sourceDurationSeconds, 2, accuracy: accuracy)
        XCTAssertEqual(reversed.targetDurationSeconds, 1, accuracy: accuracy)
        // 2 + 1 + 1 + 4 + 1 = 9
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 9, accuracy: accuracy)
    }

    func testElasticLoopSymmetry() {
        // 变速回旋：正放 1.25D + 镜像倒放 1.25D = 2.5D
        let segments = TimelineBuilder.build(kind: .elasticLoop, clipDurationSeconds: 4, loopCount: 1)
        XCTAssertEqual(segments.count, 6)
        XCTAssertEqual(TimelineBuilder.totalDuration(of: segments), 10, accuracy: accuracy)
        XCTAssertEqual(segments.filter { $0.source == .reversed }.count, 3)
    }

    func testShotModeLoopAndReverseFlags() {
        let looped = TimelineBuilder.build(kind: .slowGlide, clipDurationSeconds: 6, loopCount: 2)
        XCTAssertEqual(looped.count, 6)
        XCTAssertTrue(ShotModeKind.rushback.usesReverse)
        XCTAssertTrue(ShotModeKind.elasticLoop.usesReverse)
        XCTAssertFalse(ShotModeKind.slowGlide.usesReverse)
        XCTAssertFalse(ShotModeKind.fastFlow.usesReverse)
        // 默认库覆盖全部模式且有默认启用项
        let library = ShotMode.defaultLibrary
        XCTAssertEqual(library.count, ShotModeKind.allCases.count)
        XCTAssertFalse(library.filter(\.enabled).isEmpty)
    }

    func testZeroDurationProducesNothing() {
        XCTAssertTrue(TimelineBuilder.build(
            clipDurationSeconds: 0, effect: .slowMotion, style: .boomerang, loopCount: 2).isEmpty)
    }

    func testLoopCountClampedToAtLeastOne() {
        let segments = TimelineBuilder.build(
            clipDurationSeconds: 5, effect: .normal, style: .forward, loopCount: 0)
        XCTAssertEqual(segments.count, 1)
    }
}
