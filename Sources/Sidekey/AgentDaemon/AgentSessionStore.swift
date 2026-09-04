import Foundation

@MainActor
protocol AgentSessionStoring: AnyObject {
    func sessionID(for provider: CLIProviderID) -> String?
    func setSessionID(_ sessionID: String?, for provider: CLIProviderID)
}

@MainActor
final class AgentSessionStore: AgentSessionStoring {
    static let fileName = "sessions.json"
    /// Resume a provider session only while the conversation is "live": once
    /// the last turn is older than this, the next ask starts a fresh session.
    /// Endless resume makes every turn replay the whole history — a week-old
    /// session was observed costing ~30s of resume init plus ~70K context
    /// tokens per question.
    static let resumeWindow: TimeInterval = 15 * 60
    static let shared = AgentSessionStore(fileURL: defaultFileURL())

    private struct Snapshot: Codable, Equatable {
        var claude: String?
        var claudeUpdatedAt: Date?
        var codex: String?
        var codexUpdatedAt: Date?
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private var snapshot: Snapshot

    init(fileURL: URL, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
        self.snapshot = Self.load(from: fileURL)
    }

    func sessionID(for provider: CLIProviderID) -> String? {
        let stored: (id: String?, updatedAt: Date?)
        switch provider {
        case .claude:
            stored = (snapshot.claude, snapshot.claudeUpdatedAt)
        case .codex:
            stored = (snapshot.codex, snapshot.codexUpdatedAt)
        }
        guard let id = stored.id else { return nil }
        // No timestamp (legacy sessions.json) means unknown age — do not resume.
        guard let updatedAt = stored.updatedAt,
              now().timeIntervalSince(updatedAt) < Self.resumeWindow else { return nil }
        return id
    }

    func setSessionID(_ sessionID: String?, for provider: CLIProviderID) {
        let normalized = Self.normalized(sessionID)
        let updatedAt = normalized == nil ? nil : now()
        switch provider {
        case .claude:
            snapshot.claude = normalized
            snapshot.claudeUpdatedAt = updatedAt
        case .codex:
            snapshot.codex = normalized
            snapshot.codexUpdatedAt = updatedAt
        }
        persist()
    }

    private static func defaultFileURL() -> URL {
        let dir = (try? AgentDaemonWorkingDirectory.ensure()) ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("whytap", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    private static func load(from url: URL) -> Snapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return Snapshot()
        }
        return snapshot
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}
