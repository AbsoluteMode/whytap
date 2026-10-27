import Foundation

/// Only completed answers (text and returned card descriptions/destinations)
/// survive a turn. Raw tool arguments/results, screenshots and reasoning do not.
struct NativeAgentConversation: Codable {
    struct Pair: Codable { let user: String; let assistant: String }
    var id: String
    var route: String
    var updatedAt: Date
    var pairs: [Pair]
    static let fileName = "native-conversation.json"
    static let maximumCharacters = 12_000

    static func load(directory: URL, resumeID: String?, route: String, now: Date = Date()) -> Self {
        let url = directory.appendingPathComponent(fileName)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 100_000,
           let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Self.self, from: data),
           stored.id == resumeID, stored.route == route, now.timeIntervalSince(stored.updatedAt) >= 0,
           now.timeIntervalSince(stored.updatedAt) < AgentSessionStore.resumeWindow {
            var bounded = stored
            bounded.trim()
            return bounded
        }
        return Self(id: UUID().uuidString, route: route, updatedAt: now, pairs: [])
    }

    mutating func append(user: String, assistant: String, directory: URL, now: Date = Date()) throws {
        pairs.append(Pair(user: user, assistant: assistant)); updatedAt = now
        trim()
        let data = try JSONEncoder().encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private mutating func trim() {
        // A long selection or answer used to evict even the newest pair,
        // leaving a follow-up with no context. Retain a bounded head and tail
        // of both sides, reserving half the budget for subsequent exchanges.
        // The actual user request follows selected evidence.
        // WHY: .project-docs/decisions/2026-10-22-native-agent.md (Follow-up context)
        let pairLimit = Self.maximumCharacters / 2
        if let latest = pairs.last, latest.user.count + latest.assistant.count > pairLimit {
            let userLimit = min(latest.user.count, pairLimit / 2)
            pairs[pairs.count - 1] = Pair(user: Self.shortened(latest.user, limit: userLimit),
                assistant: Self.shortened(latest.assistant, limit: pairLimit - userLimit))
        }
        while pairs.count > 6 || pairs.reduce(0, { $0 + $1.user.count + $1.assistant.count }) > Self.maximumCharacters {
            pairs.removeFirst()
        }
    }

    private static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n[Shortened for recent context]\n"
        let available = limit - marker.count
        let prefixCount = available / 2
        return String(text.prefix(prefixCount)) + marker + String(text.suffix(available - prefixCount))
    }
}
