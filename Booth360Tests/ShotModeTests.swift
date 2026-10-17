import XCTest
@testable import Booth360

final class ShotModeTests: XCTestCase {
    private let accuracy = 0.000000001

    func testOnlyFourForwardModesAppearInNewLibraries() {
        XCTAssertEqual(ShotModeKind.allCases, [.slowFastSlow, .fastSlowFast, .gradualSpeedUp, .doubleSlow])
        XCTAssertEqual(ShotMode.defaultLibrary.map(\.kind), ShotModeKind.activeKinds)
        XCTAssertTrue(ShotMode.defaultLibrary.allSatisfy(\.enabled))
        XCTAssertTrue(ShotModeKind.activeKinds.allSatisfy { !$0.usesReverse })
        XCTAssertEqual(ShotModeKind(rawValue: "rushback"), .rushback)
        XCTAssertEqual(ShotModeKind(rawValue: "elasticLoop"), .elasticLoop)
    }

    func testDefaultDurationsAndRatesMatchTheFourRequestedCurves() {
        let expectations: [(ShotModeKind, [Double], [Double], Double)] = [
            (.slowFastSlow, [2.5, 5, 2.5], [0.5, 2, 0.5], 12.5),
            (.fastSlowFast, [2.5, 5, 2.5], [2, 0.5, 2], 12.5),
            (.gradualSpeedUp, [3, 4, 3], [0.5, 1, 2], 11.5),
            (.doubleSlow, [1.5, 2.5, 2, 2.5, 1.5], [2, 0.5, 2, 0.5, 2], 12.5),
        ]
        for (kind, durations, rates, expectedOutput) in expectations {
            let mode = ShotMode(kind: kind, enabled: true)
            assertEqual(mode.phaseDurations, durations)
            assertEqual(mode.phaseRates, rates)
            XCTAssertEqual(mode.phaseTitles.count, durations.count)
            XCTAssertEqual(mode.estimatedOutputSeconds, expectedOutput, accuracy: accuracy)
        }
    }

    func testDurationEditingPreservesTotalAndTheOtherPhaseRatio() {
        var mode = ShotMode(kind: .fastSlowFast, enabled: true, recordingSeconds: 10)
        mode.setPhaseDuration(4, at: 0)
        assertEqual(mode.phaseDurations, [4, 4, 2])
        XCTAssertEqual(mode.recordingSeconds, 10)
        mode.recordingSeconds = 20
        assertEqual(mode.phaseDurations, [8, 8, 4])
    }

    func testExtremeDurationEditsRespectTheMinimumAndFixedRecordingLength() {
        for kind in ShotModeKind.activeKinds {
            var mode = ShotMode(kind: kind, enabled: true, recordingSeconds: 5)
            for index in mode.phaseDurations.indices {
                for requested in [-Double.greatestFiniteMagnitude, -1, 0, 0.25, 2.237, 20, Double.greatestFiniteMagnitude] {
                    mode.setPhaseDuration(requested, at: index)
                    assertValid(mode)
                }
            }
            let before = mode
            mode.setPhaseDuration(.nan, at: 0)
            mode.setPhaseDuration(.infinity, at: 0)
            mode.setPhaseDuration(1, at: -1)
            mode.setPhaseDuration(1, at: Int.max)
            XCTAssertEqual(mode, before)
        }
    }

    func testDurationWaterFillingLeavesEveryOtherPhaseAtItsMinimum() {
        var mode = ShotMode(kind: .doubleSlow, enabled: true, recordingSeconds: 5)
        mode.setPhaseDuration(1000, at: 0)
        assertEqual(mode.phaseDurations, [4, 0.25, 0.25, 0.25, 0.25])
        mode.setPhaseDuration(-1000, at: 0)
        assertEqual(mode.phaseDurations, [0.25, 1.1875, 1.1875, 1.1875, 1.1875])
    }

    func testRateEditingIsIndependentAndClamped() {
        var mode = ShotMode(kind: .fastSlowFast, enabled: true)
        let durations = mode.phaseDurations
        mode.setPhaseRate(-1, at: 1)
        assertEqual(mode.phaseRates, [2, 0.25, 2])
        mode.setPhaseRate(100, at: 1)
        assertEqual(mode.phaseRates, [2, 4, 2])
        mode.setPhaseRate(.nan, at: 1)
        mode.setPhaseRate(.infinity, at: 1)
        mode.setPhaseRate(1, at: 99)
        assertEqual(mode.phaseRates, [2, 4, 2])
        assertEqual(mode.phaseDurations, durations)
    }

    func testResetKeepsIdentityEnabledAndRecordingLength() {
        var mode = ShotMode(kind: .doubleSlow, enabled: false, recordingSeconds: 17)
        let id = mode.id
        mode.setPhaseDuration(6.5, at: 1)
        mode.setPhaseRate(0.25, at: 3)
        mode.resetTiming()
        XCTAssertEqual(mode.id, id)
        XCTAssertFalse(mode.enabled)
        XCTAssertEqual(mode.recordingSeconds, 17)
        XCTAssertNil(mode.durationWeights)
        XCTAssertNil(mode.rates)
        let original = ShotMode(kind: .doubleSlow, enabled: true, recordingSeconds: 17)
        assertEqual(mode.phaseDurations, original.phaseDurations)
        assertEqual(mode.phaseRates, original.phaseRates)
    }

    func testRecordingLengthAlwaysStaysWithinSupportedLimits() {
        var mode = ShotMode(kind: .doubleSlow, enabled: true, recordingSeconds: Int.max)
        XCTAssertEqual(mode.recordingSeconds, 20)
        mode.recordingSeconds = Int.min
        XCTAssertEqual(mode.recordingSeconds, 5)
        assertValid(mode)
    }

    func testMalformedStoredArraysAreSanitizedBeforeUseAndEncoding() throws {
        var mode = ShotMode(kind: .doubleSlow, enabled: true)
        mode.durationWeights = [1, 2] // 数量错误：退回默认曲线。
        mode.rates = [0.5]
        assertValid(mode)
        assertEqual(mode.phaseRates, [2, 0.5, 2, 0.5, 2])
        mode.durationWeights = [.nan, -.infinity, -1, 0, .greatestFiniteMagnitude]
        mode.rates = [.nan, .infinity, -1, 0, .greatestFiniteMagnitude]
        assertValid(mode)
        let encoded = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(ShotMode.self, from: encoded)
        assertValid(decoded)
        XCTAssertEqual(decoded.id, mode.id)
        assertEqual(decoded.phaseDurations, mode.phaseDurations)
        assertEqual(decoded.phaseRates, mode.phaseRates)
    }

    func testDecodingNonFiniteAndWrongCountJSONDoesNotLoseOtherFields() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","kindRaw":"doubleSlow","enabled":false,"recordingSeconds":99,
         "durationWeights":[-1,0,"NaN","Infinity",1e300],"rates":["NaN",-1,0,1e300,0.05]}
        """
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let mode = try decoder.decode(ShotMode.self, from: Data(json.utf8))
        XCTAssertEqual(mode.id, id)
        XCTAssertFalse(mode.enabled)
        XCTAssertEqual(mode.recordingSeconds, 20)
        assertEqual(mode.phaseRates, [2, 0.5, 2, 4, 0.25])
        assertValid(mode)
        XCTAssertNoThrow(try JSONEncoder().encode(mode))
    }

    func testEveryLegacyRawValueDecodesWithoutTheNewFields() throws {
        let legacyKinds: [ShotModeKind] = [.slowFastSlow, .slowGlide, .rapidFade, .fastFlow, .rushback, .reverseSprint, .elasticLoop]
        for kind in legacyKinds {
            let id = UUID()
            let data = Data("{\"id\":\"\(id.uuidString)\",\"kindRaw\":\"\(kind.rawValue)\",\"enabled\":false,\"recordingSeconds\":7}".utf8)
            let decoded = try JSONDecoder().decode(ShotMode.self, from: data)
            XCTAssertEqual(decoded.id, id)
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertEqual(decoded.recordingSeconds, 7)
            XCTAssertFalse(decoded.enabled)
            XCTAssertNil(decoded.durationWeights)
            XCTAssertNil(decoded.rates)
        }
    }

    func testLibraryMigrationPreservesOldSelectionIdentityAndRecordingLength() {
        let oldKinds: [ShotModeKind] = [.slowFastSlow, .slowGlide, .rapidFade, .rushback]
        let saved = oldKinds.enumerated().map { index, kind in
            ShotMode(kind: kind, enabled: index != 2, recordingSeconds: 7 + index)
        }
        let migrated = ShotMode.migrated(from: saved)
        XCTAssertEqual(migrated.map(\.kind), ShotModeKind.activeKinds)
        XCTAssertEqual(migrated.map(\.id), saved.map(\.id))
        XCTAssertEqual(migrated.map(\.recordingSeconds), saved.map(\.recordingSeconds))
        XCTAssertEqual(migrated.map(\.enabled), saved.map(\.enabled))
        XCTAssertTrue(migrated.allSatisfy { !$0.kind.usesReverse })
    }

    func testNewSavedModesWinOverAliasesAndAliasCollisionsKeepAnEnabledEntry() {
        let disabledAlias = ShotMode(kind: .rapidFade, enabled: false, recordingSeconds: 7)
        let enabledAlias = ShotMode(kind: .fastFlow, enabled: true, recordingSeconds: 13)
        var newMode = ShotMode(kind: .gradualSpeedUp, enabled: false, recordingSeconds: 17)
        newMode.setPhaseRate(0.25, at: 0)
        let existingWins = ShotMode.migrated(from: [disabledAlias, enabledAlias, newMode])
        XCTAssertEqual(existingWins.first { $0.kind == .gradualSpeedUp }, newMode)
        let enabledWins = ShotMode.migrated(from: [disabledAlias, enabledAlias])
        XCTAssertEqual(enabledWins.first { $0.kind == .gradualSpeedUp }?.id, enabledAlias.id)
        XCTAssertEqual(enabledWins.first { $0.kind == .gradualSpeedUp }?.recordingSeconds, 13)
    }

    func testDefaultAndMissingLibraryIDsAreStableAcrossGetterCalls() {
        XCTAssertEqual(ShotMode.defaultLibrary.map(\.id), ShotMode.defaultLibrary.map(\.id))
        XCTAssertEqual(Set(ShotMode.defaultLibrary.map(\.id)).count, 4)
        XCTAssertEqual(ShotMode.migrated(from: []).map(\.id), ShotMode.migrated(from: []).map(\.id))
        let old = ShotMode(kind: .rushback, enabled: true, recordingSeconds: 7)
        XCTAssertEqual(ShotMode.migrated(from: [old]).map(\.id), ShotMode.migrated(from: [old]).map(\.id))
    }

    func testCustomConfigurationAndMigratedLibraryReencodeWithoutLosingEdits() throws {
        var mode = ShotMode(kind: .doubleSlow, enabled: false, recordingSeconds: 13)
        mode.setPhaseDuration(4.875, at: 3)
        mode.setPhaseRate(0.25, at: 1)
        mode.setPhaseRate(4, at: 4)
        let saved = ShotMode.migrated(from: [mode])
        let decoded = try JSONDecoder().decode([ShotMode].self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(ShotMode.migrated(from: decoded), saved)
    }

    func testEffectSnapshotWinsOverLegacyReverseSettings() throws {
        var effect = EffectSettings()
        effect.shotKindRaw = ShotModeKind.elasticLoop.rawValue
        effect.style = .reverse
        effect.speed = .normal
        effect.shotMode = ShotMode(kind: .fastSlowFast, enabled: true)
        XCTAssertEqual(effect.shotKind, .fastSlowFast)
        XCTAssertFalse(effect.needsReversedAsset)
        XCTAssertFalse(effect.canUseOriginalAudio)
        XCTAssertTrue(effect.summaryText.contains(ShotModeKind.fastSlowFast.displayName))
        XCTAssertFalse(effect.summaryText.contains(ShotModeKind.elasticLoop.displayName))
        var mode = try XCTUnwrap(effect.shotMode)
        for index in mode.phaseRates.indices { mode.setPhaseRate(1, at: index) }
        effect.shotMode = mode
        XCTAssertTrue(effect.canUseOriginalAudio)
        let roundTrip = try JSONDecoder().decode(EffectSettings.self, from: JSONEncoder().encode(effect))
        XCTAssertEqual(roundTrip, effect)
        XCTAssertTrue(roundTrip.canUseOriginalAudio)
    }

    func testLegacyEffectSettingsWithoutSnapshotRetainReverseSemantics() throws {
        let data = Data("{\"shotKindRaw\":\"rushback\",\"speed\":\"normal\",\"style\":\"forward\"}".utf8)
        let effect = try JSONDecoder().decode(EffectSettings.self, from: data)
        XCTAssertNil(effect.shotMode)
        XCTAssertTrue(effect.needsReversedAsset)
        XCTAssertFalse(effect.canUseOriginalAudio)
        XCTAssertTrue(effect.summaryText.contains(ShotModeKind.rushback.displayName))
    }

    private func assertEqual(_ actual: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (value, wanted) in zip(actual, expected) {
            XCTAssertEqual(value, wanted, accuracy: accuracy, file: file, line: line)
        }
    }

    private func assertValid(_ mode: ShotMode, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mode.phaseDurations.reduce(0, +), Double(mode.recordingSeconds), accuracy: accuracy, file: file, line: line)
        XCTAssertTrue(mode.phaseDurations.allSatisfy { $0.isFinite && $0 >= ShotMode.minimumPhaseDuration - accuracy }, file: file, line: line)
        XCTAssertTrue(mode.phaseRates.allSatisfy { $0.isFinite && ShotMode.phaseRateRange.contains($0) }, file: file, line: line)
        XCTAssertTrue(mode.estimatedOutputSeconds.isFinite && mode.estimatedOutputSeconds > 0, file: file, line: line)
    }
}
