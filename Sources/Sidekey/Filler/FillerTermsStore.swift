import Foundation

/// Local, on-device storage for Filler word terms. Never leaves
/// the device — the list is a sensitive speech profile (see
/// docs/specs/filler.md). Backed by UserDefaults; synchronous read in
/// the drop hot-path needs no separate cache.
struct FillerTermsStore {
    static let maxTermCount = 100
    static let maxTermLength = 50

    enum Rejection: Equatable { case empty, tooLong, duplicate, tooMany }
    enum AddResult: Equatable { case added, rejected(Rejection) }

    private let defaults: UserDefaults
    // legacy key name kept across the Replace→Filler rename so saved lists survive
    private let key = "sidekey.replace.terms"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func terms() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    @discardableResult
    func add(_ raw: String) -> AddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.empty) }
        guard trimmed.count <= Self.maxTermLength else { return .rejected(.tooLong) }
        var current = terms()
        guard !current.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return .rejected(.duplicate)
        }
        guard current.count < Self.maxTermCount else { return .rejected(.tooMany) }
        current.append(trimmed)
        defaults.set(current, forKey: key)
        return .added
    }

    func remove(_ term: String) {
        let next = terms().filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        defaults.set(next, forKey: key)
    }
}
