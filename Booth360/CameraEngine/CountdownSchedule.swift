import Foundation

/// All offsets are measured from one monotonic start time. Half seconds and
/// delayed UI updates never add extra one-second waits to the chosen duration.
struct CountdownSchedule: Equatable {
    struct Step: Equatable {
        let remainingSeconds: Double
        let endOffsetSeconds: Double
    }

    let durationSeconds: Double
    let steps: [Step]

    init(seconds: Double) {
        let duration = RecordingSettings.normalizedCountdown(seconds)
        durationSeconds = duration
        let wholeSeconds = Int(duration)
        let fraction = duration - Double(wholeSeconds)
        var planned: [Step] = []
        if fraction > 0 {
            planned.append(Step(remainingSeconds: duration, endOffsetSeconds: fraction))
        }
        for remaining in stride(from: wholeSeconds, through: 1, by: -1) {
            planned.append(Step(remainingSeconds: Double(remaining),
                                endOffsetSeconds: duration - Double(remaining) + 1))
        }
        steps = planned
    }

    @MainActor
    func run(startedAt: ContinuousClock.Instant, onStep: (Double) -> Void) async throws {
        let clock = ContinuousClock()
        try await run(
            hasTimeRemaining: { clock.now < startedAt.advanced(by: .seconds($0)) },
            sleepUntil: { try await clock.sleep(until: startedAt.advanced(by: .seconds($0))) },
            onStep: onStep
        )
    }

    /// Clock operations are injectable so deadline drift and cancellation can
    /// be checked without waiting several real seconds or starting a camera.
    @MainActor
    func run(hasTimeRemaining: (Double) -> Bool,
             sleepUntil: (Double) async throws -> Void,
             onStep: (Double) -> Void) async throws {
        for step in steps {
            try Task.checkCancellation()
            guard hasTimeRemaining(step.endOffsetSeconds) else { continue }
            onStep(step.remainingSeconds)
            try Task.checkCancellation()
            try await sleepUntil(step.endOffsetSeconds)
        }
        try Task.checkCancellation()
    }
}
