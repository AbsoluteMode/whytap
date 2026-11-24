import XCTest
@testable import Sidekey

/// The shelved Drop learning collects nothing, but its calibration journal
/// still ends 14 days after calibration was switched on.
/// WHY: .project-docs/decisions/2026-11-23-drop-learning-shelved.md
final class ShelvedDropLearningDataTests: XCTestCase {
    private var defaults: UserDefaults!
    private var journal: URL!
    private var now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "shelved-drop-learning.\(UUID().uuidString)"))
        journal = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("calibration.jsonl")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: journal)
    }

    private func data() -> ShelvedDropLearningData {
        ShelvedDropLearningData(defaults: defaults, journal: journal, now: { [unowned self] in now })
    }

    private var journalExists: Bool { FileManager.default.fileExists(atPath: journal.path) }

    func testTheJournalStaysForFourteenDaysThenGoesWithTheCalibrationKeys() {
        defaults.set(true, forKey: ShelvedDropLearningData.calibrationKey)
        defaults.set(now, forKey: ShelvedDropLearningData.calibrationSinceKey)
        defaults.set(["x": 1], forKey: ShelvedDropLearningData.calibrationLedgerKey)
        now += 13 * 86_400
        data().expireCalibration()
        XCTAssertTrue(journalExists)
        now += 86_400
        data().expireCalibration()
        XCTAssertFalse(journalExists)
        XCTAssertNil(defaults.object(forKey: ShelvedDropLearningData.calibrationKey))
        XCTAssertNil(defaults.object(forKey: ShelvedDropLearningData.calibrationSinceKey))
        XCTAssertNil(defaults.object(forKey: ShelvedDropLearningData.calibrationLedgerKey))
    }

    func testCalibrationSwitchedOffEndsAtOnce() {
        defaults.set(false, forKey: ShelvedDropLearningData.calibrationKey)
        defaults.set(now, forKey: ShelvedDropLearningData.calibrationSinceKey)
        data().expireCalibration()
        XCTAssertFalse(journalExists)
    }

    func testCalibrationOnWithoutAClockStartsItAndWritesNothingElse() {
        defaults.set(true, forKey: ShelvedDropLearningData.calibrationKey)
        data().expireCalibration()
        XCTAssertEqual(defaults.object(forKey: ShelvedDropLearningData.calibrationSinceKey) as? Date, now)
        XCTAssertTrue(journalExists)
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "{}\n", "Nothing is collected")
    }

    func testNeverCalibratedLeavesEverythingAlone() {
        defaults.set(["a"], forKey: ShelvedDropLearningData.replacementsKey)
        data().expireCalibration()
        XCTAssertTrue(journalExists)
        XCTAssertEqual(defaults.stringArray(forKey: ShelvedDropLearningData.replacementsKey), ["a"])
    }
}
