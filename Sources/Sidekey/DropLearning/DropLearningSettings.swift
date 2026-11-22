import Foundation

/// Learning from edits is opt-in (`enabled`, off by default; its switch ships
/// with the drops UI). Calibration is a hidden developer mode for tuning the
/// rules on real dictation: it reads the field longer, writes a local journal
/// and saves nothing on Y. It switches itself off after 14 days and deletes the
/// journal and its own counters.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
struct DropLearningSettings {
    static let enabledKey = "sidekey.dropLearning.enabled"
    static let calibrationKey = "sidekey.dropLearning.calibration"
    static let calibrationSinceKey = "sidekey.dropLearning.calibration.since"
    static let calibrationLedgerKey = "sidekey.dropLearning.calibrationLedger.v1"
    static let calibrationDays = 14

    let defaults: UserDefaults
    let now: () -> Date
    let journal: DropLearningJournal

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, journal: DropLearningJournal) {
        self.defaults = defaults
        self.now = now
        self.journal = journal
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// True while calibration is on and younger than 14 days. The first call
    /// after it is switched on starts the clock; expiry cleans up.
    func isCalibrating() -> Bool {
        guard defaults.bool(forKey: Self.calibrationKey) else {
            if defaults.object(forKey: Self.calibrationSinceKey) != nil { endCalibration() }
            return false
        }
        guard let since = defaults.object(forKey: Self.calibrationSinceKey) as? Date else {
            defaults.set(now(), forKey: Self.calibrationSinceKey)
            return true
        }
        guard now().timeIntervalSince(since) < Double(Self.calibrationDays) * 86_400 else {
            endCalibration()
            return false
        }
        return true
    }

    func endCalibration() {
        defaults.removeObject(forKey: Self.calibrationKey)
        defaults.removeObject(forKey: Self.calibrationSinceKey)
        defaults.removeObject(forKey: Self.calibrationLedgerKey)
        journal.delete()
    }
}

/// Calibration journal: one JSON line per read, private to the user (0600),
/// outside backups, settings sync and logs. Holds the edited words, because
/// judging false positives needs them; deleted when calibration ends.
final class DropLearningJournal {
    let url: URL

    init(url: URL) { self.url = url }

    static var production: DropLearningJournal {
        DropLearningJournal(url: ArtifactBackupLocations.production.bundleRoot
            .appendingPathComponent("drop-learning", isDirectory: true)
            .appendingPathComponent("calibration.jsonl"))
    }

    func append(_ entry: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(entry),
              var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
