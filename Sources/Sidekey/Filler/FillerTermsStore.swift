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

    /// Posted after every write so every open editor (island, Toolbox) shows
    /// a term added or removed in another one.
    static let didChangeNotification = Notification.Name("sidekey.filler.didChange")

    private let defaults: UserDefaults
    // legacy key name kept across the Replace→Filler rename so saved lists survive
    private let key = "sidekey.replace.terms"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func terms() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// The editor's rules for one term against `current`. Pure: callers that
    /// check a batch before adding (application controls) use it too.
    static func validate(_ raw: String, against current: [String]) -> AddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.empty) }
        guard trimmed.count <= maxTermLength else { return .rejected(.tooLong) }
        guard !current.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return .rejected(.duplicate)
        }
        guard current.count < maxTermCount else { return .rejected(.tooMany) }
        return .added
    }

    @discardableResult
    func add(_ raw: String) -> AddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = terms()
        let result = Self.validate(trimmed, against: current)
        guard result == .added else { return result }
        current.append(trimmed)
        defaults.set(current, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return .added
    }

    func remove(_ term: String) {
        let next = terms().filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        defaults.set(next, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
