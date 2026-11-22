import Foundation

/// Learning from edits is on by default (Settings, Other, Drop, "Learn from my
/// edits"); a user who switched it off stays off. Calibration is a hidden developer mode for tuning the
/// rules on real dictation: it watches the field the same way, writes a local journal
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

    var isEnabled: Bool { Self.isEnabled(in: defaults) }

    /// On unless the user switched it off: the key is written only by the
    /// switch, so a missing key means "never touched" and reads as on, while
    /// an explicit `false` is kept. No migration is needed.
    // WHY: .project-docs/decisions/2026-11-22-drop-learning-default-on.md
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

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

    /// Appends only to a private destination: the folder is a real 0700
    /// directory, the file is a regular file of this user with one name
    /// (no hard link), opened without following links, and it is made 0600
    /// before anything is written.
    // WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
    func append(_ entry: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(entry),
              var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var dirInfo = stat()
        guard lstat(directory.path, &dirInfo) == 0, (dirInfo.st_mode & S_IFMT) == S_IFDIR,
              dirInfo.st_uid == getuid() else { return }
        if dirInfo.st_mode & 0o077 != 0 { chmod(directory.path, 0o700) }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        // A hard link would make this write land in another named file:
        // only a file with this one name is ever changed.
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { return }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
