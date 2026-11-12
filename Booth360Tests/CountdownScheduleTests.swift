import Foundation
import SwiftData
import XCTest
@testable import Booth360

@MainActor
final class CountdownScheduleTests: XCTestCase {
    func testChoicesDefaultsAndLabelsMatchTheFiveSupportedDurations() {
        XCTAssertEqual(RecordingSettings.countdownChoices, [3, 3.5, 4, 4.5, 5])
        XCTAssertEqual(RecordingSettings().countdownSeconds, 3)
        XCTAssertEqual(RecordingSettings.countdownChoices.map(RecordingSettings.countdownLabel),
                       ["3", "3.5", "4", "4.5", "5"])
        XCTAssertEqual(RecordingSettings.countdownLabel(1), "1", "Remaining time must not be normalized back to 3")
        XCTAssertEqual(RecordingSettings.countdownLabel(2), "2")
    }

    func testInvalidAndLegacySettingsNormalizeWithoutLosingHalfSeconds() {
        XCTAssertEqual(RecordingSettings(countdownSeconds: 0).countdownSeconds, 3)
        XCTAssertEqual(RecordingSettings(countdownSeconds: 10).countdownSeconds, 5)
        XCTAssertEqual(RecordingSettings(countdownSeconds: .nan).countdownSeconds, 3)
        XCTAssertEqual(RecordingSettings(countdownSeconds: .infinity).countdownSeconds, 3)
        XCTAssertEqual(RecordingSettings(countdownSeconds: -.infinity).countdownSeconds, 3)
        var settings = RecordingSettings(countdownSeconds: 3.5)
        XCTAssertEqual(settings.countdownSeconds, 3.5)
        settings.countdownSeconds = 4.5
        XCTAssertEqual(settings.countdownSeconds, 4.5)
        settings.countdownSeconds = 3.25
        XCTAssertEqual(settings.countdownSeconds, 3.5)
    }

    func testSharedPreferenceReadsOldIntegersAndPersistsBothHalfSecondChoices() throws {
        let defaults = try isolatedDefaults()
        let originalKey = "booth360.capture.countdown"
        XCTAssertEqual(RecordingSettings.loadCountdownSeconds(defaults: defaults), 3)
        defaults.set(0, forKey: originalKey)
        XCTAssertEqual(RecordingSettings.loadCountdownSeconds(defaults: defaults), 3)
        defaults.set(10, forKey: originalKey)
        XCTAssertEqual(RecordingSettings.loadCountdownSeconds(defaults: defaults), 5)
        defaults.set(4, forKey: originalKey)
        XCTAssertEqual(RecordingSettings.loadCountdownSeconds(defaults: defaults), 4)
        for duration in [3.5, 4.5] {
            RecordingSettings.storeCountdownSeconds(duration, defaults: defaults)
            XCTAssertEqual(defaults.double(forKey: originalKey), duration)
            XCTAssertEqual(RecordingSettings.loadCountdownSeconds(defaults: defaults, fallback: 5), duration)
        }
        RecordingSettings.storeCountdownSeconds(10, defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: originalKey), 5)
    }

    func testLegacyEventIntegerDataRemainsUnchangedWhileGlobalPreferenceTakesPriority() throws {
        let container = try ModelContainer(for: EventTemplate.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(EventTemplate(name: "A", countdownSeconds: 0))
        context.insert(EventTemplate(name: "B", countdownSeconds: 10))
        try context.save()
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<EventTemplate>(
            sortBy: [SortDescriptor(\EventTemplate.name)]))
        XCTAssertEqual(reloaded.map(\.countdownSeconds), [0, 10], "Do not mutate legacy SwiftData Int values")
        XCTAssertEqual(reloaded.map { $0.recordingSettings.countdownSeconds }, [3, 5])
        let defaults = try isolatedDefaults()
        for event in reloaded {
            XCTAssertEqual(RecordingSettings.loadCountdownSeconds(defaults: defaults,
                fallback: Double(event.countdownSeconds)), event.recordingSettings.countdownSeconds)
        }
        RecordingSettings.storeCountdownSeconds(4.5, defaults: defaults)
        for event in reloaded {
            XCTAssertEqual(RecordingSettings.loadCountdownSeconds(defaults: defaults,
                fallback: Double(event.countdownSeconds)), 4.5)
        }
        XCTAssertEqual(reloaded.map(\.countdownSeconds), [0, 10])
    }

    func testHalfSecondPlansEndAtTheChosenDuration() {
        let threeAndHalf = CountdownSchedule(seconds: 3.5)
        XCTAssertEqual(threeAndHalf.steps.map(\.remainingSeconds), [3.5, 3, 2, 1])
        XCTAssertEqual(threeAndHalf.steps.map(\.endOffsetSeconds), [0.5, 1.5, 2.5, 3.5])
        let fourAndHalf = CountdownSchedule(seconds: 4.5)
        XCTAssertEqual(fourAndHalf.steps.map(\.remainingSeconds), [4.5, 4, 3, 2, 1])
        XCTAssertEqual(fourAndHalf.steps.map(\.endOffsetSeconds), [0.5, 1.5, 2.5, 3.5, 4.5])
        for duration in RecordingSettings.countdownChoices {
            let plan = CountdownSchedule(seconds: duration)
            XCTAssertEqual(plan.durationSeconds, duration)
            XCTAssertEqual(plan.steps.last?.endOffsetSeconds, duration)
            let starts = [0] + plan.steps.dropLast().map(\.endOffsetSeconds)
            let intervals = zip(plan.steps, starts).map { $0.0.endOffsetSeconds - $0.1 }
            XCTAssertTrue(intervals.allSatisfy { $0 > 0 && $0 <= 1 })
            XCTAssertEqual(intervals.reduce(0, +), duration, accuracy: 0.000001)
        }
    }

    func testTurntableAutoStopRoundsHalfSecondLeadUpInTheActualCommandFrame() {
        let timeout = TurntableConfig.recordingTimeoutSeconds(recordingSeconds: 15, leadSeconds: 3.5)
        XCTAssertEqual(timeout, 22)
        let frame = TurntableConfig.mweFrame(switchByte: 0x11, speedLevel: 4, seconds: timeout)
        XCTAssertEqual(frame[6], 22, "The hardware must not truncate 21.5 seconds to 21")
        XCTAssertEqual(TurntableConfig.recordingTimeoutSeconds(recordingSeconds: 15, leadSeconds: 4.5), 23)
        XCTAssertEqual(TurntableConfig.recordingTimeoutSeconds(recordingSeconds: 15, leadSeconds: 3), 21)
        XCTAssertEqual(TurntableConfig.recordingTimeoutSeconds(recordingSeconds: 15, leadSeconds: 0), 18)
    }

    func testExecutorUsesOriginalDeadlinesForBothHalfSecondChoices() async throws {
        for duration in [3.5, 4.5] {
            let plan = CountdownSchedule(seconds: duration)
            var elapsed = 0.0
            var deadlines: [Double] = []
            var shown: [Double] = []
            try await plan.run(hasTimeRemaining: { elapsed < $0 }, sleepUntil: { deadline in
                deadlines.append(deadline)
                elapsed = deadline
            }, onStep: { shown.append($0) })
            // The caller starts recording only after the final original deadline.
            XCTAssertEqual(elapsed, duration, accuracy: 0.000001)
            XCTAssertEqual(deadlines, plan.steps.map(\.endOffsetSeconds))
            XCTAssertEqual(shown, plan.steps.map(\.remainingSeconds))
        }
    }

    func testLateSchedulingSkipsExpiredNumbersWithoutExtendingTheCountdown() async throws {
        var elapsed = 1.8
        var deadlines: [Double] = []
        var shown: [Double] = []
        try await CountdownSchedule(seconds: 3.5).run(
            hasTimeRemaining: { elapsed < $0 }, sleepUntil: { deadline in
                deadlines.append(deadline)
                elapsed = deadline
            }, onStep: { shown.append($0) })
        XCTAssertEqual(shown, [2, 1])
        XCTAssertEqual(deadlines, [2.5, 3.5])
        XCTAssertEqual(elapsed, 3.5)
    }

    func testAnOversleptStepDoesNotAccumulateExtraWaits() async throws {
        var elapsed = 0.0
        var deadlines: [Double] = []
        var shown: [Double] = []
        try await CountdownSchedule(seconds: 3.5).run(
            hasTimeRemaining: { elapsed < $0 }, sleepUntil: { deadline in
                deadlines.append(deadline)
                elapsed = deadlines.count == 1 ? deadline + 1.25 : deadline
            }, onStep: { shown.append($0) })
        XCTAssertEqual(shown, [3.5, 2, 1])
        XCTAssertEqual(deadlines, [0.5, 2.5, 3.5])
        XCTAssertEqual(elapsed, 3.5)
    }

    func testCancellationWhileWaitingNeverReachesTheRecordingContinuation() async throws {
        var startedRecording = false
        var shown: [Double] = []
        do {
            try await CountdownSchedule(seconds: 4.5).run(
                hasTimeRemaining: { _ in true }, sleepUntil: { _ in throw CancellationError() },
                onStep: { shown.append($0) })
            startedRecording = true
            XCTFail("A cancelled wait must not finish the countdown")
        } catch is CancellationError {
            XCTAssertFalse(startedRecording)
            XCTAssertEqual(shown, [4.5])
        }
    }

    func testPreCancelledTaskDoesNotShowOrWaitOrStartRecording() async throws {
        var shown: [Double] = []
        var waits = 0
        var startedRecording = false
        let task = Task { @MainActor in
            try await CountdownSchedule(seconds: 3.5).run(
                hasTimeRemaining: { _ in true }, sleepUntil: { _ in waits += 1 },
                onStep: { shown.append($0) })
            startedRecording = true
        }
        // MainActor cannot run this child before the next suspension.
        task.cancel()
        do {
            try await task.value
            XCTFail("A pre-cancelled countdown must throw")
        } catch is CancellationError {
            XCTAssertTrue(shown.isEmpty)
            XCTAssertEqual(waits, 0)
            XCTAssertFalse(startedRecording)
        }
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "CountdownTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}
