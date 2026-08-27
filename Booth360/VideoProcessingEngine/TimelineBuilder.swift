import Foundation

/// 时间轴片段：从哪个素材（原片/倒序片）取哪一段，放进成品后占多长。
/// targetDuration ≠ sourceDuration 即变速（target 更长 = 慢动作）。
struct TimelineSegment: Equatable {
    enum SourceKind: Equatable {
        case original
        case reversed
    }

    let source: SourceKind
    let sourceStartSeconds: Double
    let sourceDurationSeconds: Double
    let targetDurationSeconds: Double
}

/// 纯逻辑：把 (变速效果 + 播放方式 + 循环次数) 展开成时间轴片段列表。
/// 不接触 AVFoundation，单元测试完全覆盖。
enum TimelineBuilder {

    /// 慢动作/快动作的速率。0.5 = 半速（时长 ×2），2.0 = 两倍速（时长 ÷2）。
    static let slowRate = 0.5
    static let fastRate = 2.0
    /// 慢-快-慢的分段比例：前 25% 慢、中间 50% 快、后 25% 慢。
    static let slowFastSlowSplit = (slow: 0.25, fast: 0.5)

    // MARK: - 入口

    static func build(
        clipDurationSeconds duration: Double,
        effect: SpeedEffect,
        style: PlaybackStyle,
        loopCount: Int
    ) -> [TimelineSegment] {
        guard duration > 0 else { return [] }
        let forward = speedSegments(clipDurationSeconds: duration, effect: effect)

        let single: [TimelineSegment]
        switch style {
        case .forward:
            single = forward
        case .reverse:
            single = mirroredToReversed(forward, clipDurationSeconds: duration)
        case .boomerang:
            single = forward + mirroredToReversed(forward, clipDurationSeconds: duration)
        }

        let loops = max(1, loopCount)
        return Array(repeating: single, count: loops).flatMap { $0 }
    }

    static func totalDuration(of segments: [TimelineSegment]) -> Double {
        segments.reduce(0) { $0 + $1.targetDurationSeconds }
    }

    // MARK: - 变速分段（正放方向）

    static func speedSegments(clipDurationSeconds duration: Double, effect: SpeedEffect) -> [TimelineSegment] {
        switch effect {
        case .normal:
            return [TimelineSegment(
                source: .original, sourceStartSeconds: 0,
                sourceDurationSeconds: duration, targetDurationSeconds: duration)]

        case .slowMotion:
            return [TimelineSegment(
                source: .original, sourceStartSeconds: 0,
                sourceDurationSeconds: duration, targetDurationSeconds: duration / slowRate)]

        case .fastMotion:
            return [TimelineSegment(
                source: .original, sourceStartSeconds: 0,
                sourceDurationSeconds: duration, targetDurationSeconds: duration / fastRate)]

        case .slowFastSlow:
            let slowPart = duration * slowFastSlowSplit.slow
            let fastPart = duration * slowFastSlowSplit.fast
            return [
                TimelineSegment(
                    source: .original, sourceStartSeconds: 0,
                    sourceDurationSeconds: slowPart, targetDurationSeconds: slowPart / slowRate),
                TimelineSegment(
                    source: .original, sourceStartSeconds: slowPart,
                    sourceDurationSeconds: fastPart, targetDurationSeconds: fastPart / fastRate),
                TimelineSegment(
                    source: .original, sourceStartSeconds: slowPart + fastPart,
                    sourceDurationSeconds: duration - slowPart - fastPart,
                    targetDurationSeconds: (duration - slowPart - fastPart) / slowRate),
            ]
        }
    }

    // MARK: - 倒放映射

    /// 把正放的变速分段镜像成倒放版本：
    /// 片段顺序反转；每段在倒序素材中的起点 = 素材总长 - 原起点 - 原时长。
    /// 这样倒放也保留同样的变速节奏（镜像后首尾对称）。
    static func mirroredToReversed(
        _ forwardSegments: [TimelineSegment],
        clipDurationSeconds duration: Double
    ) -> [TimelineSegment] {
        forwardSegments.reversed().map { segment in
            TimelineSegment(
                source: .reversed,
                sourceStartSeconds: max(0, duration - segment.sourceStartSeconds - segment.sourceDurationSeconds),
                sourceDurationSeconds: segment.sourceDurationSeconds,
                targetDurationSeconds: segment.targetDurationSeconds
            )
        }
    }
}
