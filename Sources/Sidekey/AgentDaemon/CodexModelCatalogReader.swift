import Foundation
import Darwin

/// Codex is the authority for model availability and per-model controls.
/// WHY: docs/decisions/2026-09-07-codex-model-registry.md
struct CodexModelOption: Codable, Equatable, Identifiable, Sendable {
    struct Effort: Codable, Equatable, Sendable {
        let reasoningEffort: String
        var description: String? = nil
    }
    struct ServiceTier: Codable, Equatable, Sendable {
        let id: String
        var name: String? = nil
        var description: String? = nil
    }
    let model: String
    var displayName: String? = nil
    var hidden: Bool? = nil
    var supportedReasoningEfforts: [Effort]? = nil
    var defaultReasoningEffort: String? = nil
    var serviceTiers: [ServiceTier]? = nil
    var additionalSpeedTiers: [String]? = nil
    var defaultServiceTier: String? = nil
    var isDefault: Bool? = nil

    var id: String { model }
    var label: String { displayName ?? model }
    var efforts: [String] { supportedReasoningEfforts?.map(\.reasoningEffort) ?? [] }
    var tiers: [ServiceTier] {
        // Older app-server versions exposed only additionalSpeedTiers.
        serviceTiers ?? (additionalSpeedTiers ?? []).map {
            ServiceTier(id: $0 == "fast" ? "priority" : $0, name: $0.capitalized)
        }
    }
    func resolvedEffort(_ stored: String?) -> String? {
        if let stored = stored?.lowercased(), efforts.contains(stored) { return stored }
        if let fallback = defaultReasoningEffort, efforts.contains(fallback) { return fallback }
        return efforts.first
    }
    func resolvedTier(_ stored: String?) -> String {
        let value = stored?.lowercased() == "fast" ? "priority" : stored?.lowercased()
        if let value, tiers.contains(where: { $0.id == value }) { return value }
        if value == "default" || value == "normal" || value == "standard" { return "default" }
        if let fallback = defaultServiceTier, tiers.contains(where: { $0.id == fallback }) { return fallback }
        return "default"
    }
}

struct CodexModelCatalogReader: Sendable {
    enum Failure: Error { case notInstalled, timedOut, invalidResponse, unavailable }
    var locate: @Sendable () -> URL? = { CodexBinaryLocator().locate() }
    var timeout: TimeInterval = 8

    func read() async throws -> [CodexModelOption] {
        let task = Task.detached { try readSynchronously() }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { task.cancel() })
    }

    /// A short-lived stdio app-server. Never creates a thread or submits a prompt.
    /// poll keeps reads bounded; cancellation/timeout closes pipes and reaps the child.
    private func readSynchronously() throws -> [CodexModelOption] {
        try Task.checkCancellation()
        guard let binary = locate() else { throw Failure.notInstalled }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = binary
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = CodexProvider.childEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Parent does not own the child's ends of the pipes.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": [
            "clientInfo": ["name": "whytap", "title": "Whytap", "version": "1.0"]
        ]])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pendingID = 0, receivedBytes = 0
        var buffer = Data(), models: [CodexModelOption] = []
        var cursors = Set<String>()
        let fd = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
            guard count > 0 else { throw Failure.unavailable }
            receivedBytes += count
            guard receivedBytes <= 2_097_152 else { throw Failure.invalidResponse }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let envelope = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw Failure.invalidResponse
                }
                guard envelope["id"] as? Int == pendingID else { continue }
                guard envelope["error"] == nil, let result = envelope["result"] as? [String: Any] else {
                    throw Failure.unavailable
                }
                if pendingID == 0 {
                    try send(["method": "initialized", "params": [:]])
                    pendingID = 1
                    try send(["id": pendingID, "method": "model/list", "params": ["limit": 100, "includeHidden": false]])
                } else {
                    struct Page: Decodable { let data: [CodexModelOption]; let nextCursor: String? }
                    let page = try JSONDecoder().decode(Page.self, from: JSONSerialization.data(withJSONObject: result))
                    models.append(contentsOf: page.data.filter { $0.hidden != true && !$0.model.isEmpty })
                    if let cursor = page.nextCursor, !cursor.isEmpty {
                        guard cursors.insert(cursor).inserted, pendingID < 100 else { throw Failure.invalidResponse }
                        pendingID += 1
                        try send(["id": pendingID, "method": "model/list", "params": ["limit": 100, "includeHidden": false, "cursor": cursor]])
                    } else {
                        var seen = Set<String>()
                        let unique = models.filter { seen.insert($0.model).inserted }
                        guard !unique.isEmpty else { throw Failure.unavailable }
                        return unique
                    }
                }
            }
        }
        throw Failure.timedOut
    }
}
