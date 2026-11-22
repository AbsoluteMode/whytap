import Foundation

/// Why takes did or did not teach anything, as counts per fixed reason name
/// ("end.cleared", "sub.notSoundAlike", "candidate.vocabAdd"). Never words,
/// hashes or app names: a developer can see where learning stops without any
/// of the text. Local defaults only, outside backups and settings sync;
/// deleted when learning and calibration are both switched off.
/// Read it with `defaults read com.rootwise.sidekey sidekey.dropLearning.stats.v1`.
// WHY: .project-docs/decisions/2026-11-22-drop-learning-cut-tail.md
struct DropLearningStats {
    static let key = "sidekey.dropLearning.stats.v1"
    /// Names are fixed in code; a cap keeps a bug from growing the key.
    static let maxReasons = 64

    let defaults: UserDefaults

    var counts: [String: Int] { defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:] }

    func add(_ reasons: [String]) {
        guard !reasons.isEmpty else { return }
        var counts = self.counts
        for reason in reasons where counts[reason] != nil || counts.count < Self.maxReasons {
            counts[reason, default: 0] += 1
        }
        defaults.set(counts, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
