import CryptoKit
import Foundation

/// Counts repeated corrections without keeping their words: each candidate is
/// an HMAC under a random per-install salt, with the days it was seen. Kept in
/// local defaults under a key outside the backup/sync allowlist and never
/// logged. A salted hash of a short word is a pseudonym, not encryption.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
final class DropLearningLedger {
    static let key = "sidekey.dropLearning.ledger.v1"
    /// Same correction in this many different takes...
    static let threshold = 2
    /// ...within this many days.
    static let windowDays = 14
    static let maxEntries = 2_000

    private struct Stored: Codable {
        var salt: Data
        var seen: [String: [Int]] = [:]
        var declined: Set<String> = []
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: () -> Date
    private var stored: Stored

    init(defaults: UserDefaults = .standard, key: String = DropLearningLedger.key, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.storageKey = key
        self.now = now
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored(salt: Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }))
        }
    }

    /// Records one take's candidates (each at most once) and returns those
    /// that reached the threshold and were never declined.
    func observe(_ candidates: [DropLearningCandidate]) -> [DropLearningCandidate] {
        let today = day(now())
        var ready: [DropLearningCandidate] = []
        var counted = Set<String>()
        for candidate in candidates {
            let hash = digest(candidate.ledgerKey)
            guard !stored.declined.contains(hash), counted.insert(hash).inserted else { continue }
            var days = (stored.seen[hash] ?? []).filter { $0 > today - Self.windowDays }
            days.append(today)
            stored.seen[hash] = days
            if days.count >= Self.threshold { ready.append(candidate) }
        }
        prune(today: today)
        save()
        return ready
    }

    /// Whether this candidate is new enough to count: not declined.
    func isDeclined(_ candidate: DropLearningCandidate) -> Bool {
        stored.declined.contains(digest(candidate.ledgerKey))
    }

    /// N: never offered again.
    func decline(_ candidate: DropLearningCandidate) {
        let hash = digest(candidate.ledgerKey)
        stored.declined.insert(hash)
        stored.seen[hash] = nil
        save()
    }

    /// Y, or shown and let go: counting starts over.
    func reset(_ candidate: DropLearningCandidate) {
        stored.seen[digest(candidate.ledgerKey)] = nil
        save()
    }

    func count(_ candidate: DropLearningCandidate) -> Int {
        let today = day(now())
        return (stored.seen[digest(candidate.ledgerKey)] ?? []).filter { $0 > today - Self.windowDays }.count
    }

    private func prune(today: Int) {
        stored.seen = stored.seen.compactMapValues { days in
            let kept = days.filter { $0 > today - Self.windowDays }
            return kept.isEmpty ? nil : kept
        }
        if stored.seen.count > Self.maxEntries {
            let oldest = stored.seen.sorted { ($0.value.max() ?? 0) < ($1.value.max() ?? 0) }
                .prefix(stored.seen.count - Self.maxEntries).map(\.key)
            for key in oldest { stored.seen[key] = nil }
        }
    }

    private func digest(_ value: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: stored.salt))
        return Data(mac).base64EncodedString()
    }

    private func day(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 86_400) }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: storageKey) }
    }
}
