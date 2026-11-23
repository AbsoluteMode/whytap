import Foundation

/// What is left on a Mac from Drop learning, which is shelved on branch
/// `shelf/drop-learning`. Nothing here reads, collects or applies any of it.
/// The hidden developer calibration journal can hold edited words and was
/// promised to end itself 14 days after calibration was switched on, so that
/// end still runs at launch and hourly; it deletes the journal and the
/// calibration keys, exactly as the shelved code did.
/// WHY: .project-docs/decisions/2026-11-23-drop-learning-shelved.md
struct ShelvedDropLearningData {
    static let calibrationKey = "sidekey.dropLearning.calibration"
    static let calibrationSinceKey = "sidekey.dropLearning.calibration.since"
    static let calibrationLedgerKey = "sidekey.dropLearning.calibrationLedger.v1"
    /// Saved Replace rules: still accepted in backups and settings history so
    /// an older archive restores, but nothing applies them.
    static let replacementsKey = "sidekey.drop.replacements.v1"
    static let calibrationDays = 14

    let defaults: UserDefaults
    let journal: URL
    let now: () -> Date

    init(defaults: UserDefaults = .standard,
         journal: URL = ShelvedDropLearningData.productionJournal,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.journal = journal
        self.now = now
    }

    static var productionJournal: URL {
        ArtifactBackupLocations.production.bundleRoot
            .appendingPathComponent("drop-learning", isDirectory: true)
            .appendingPathComponent("calibration.jsonl")
    }

    /// Same rule as the shelved calibration: switched off with a clock set,
    /// or 14 days after it was switched on, ends it; switched on without a
    /// clock starts the clock. Calibration that was never on is left alone.
    func expireCalibration() {
        let since = defaults.object(forKey: Self.calibrationSinceKey) as? Date
        guard defaults.bool(forKey: Self.calibrationKey) else {
            if since != nil { end() }
            return
        }
        guard let since else {
            defaults.set(now(), forKey: Self.calibrationSinceKey)
            return
        }
        if now().timeIntervalSince(since) >= Double(Self.calibrationDays) * 86_400 { end() }
    }

    private func end() {
        defaults.removeObject(forKey: Self.calibrationKey)
        defaults.removeObject(forKey: Self.calibrationSinceKey)
        defaults.removeObject(forKey: Self.calibrationLedgerKey)
        try? FileManager.default.removeItem(at: journal)
    }
}
