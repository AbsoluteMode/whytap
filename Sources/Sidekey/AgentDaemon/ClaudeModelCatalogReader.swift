import Foundation
import os.log

/// One model Claude Code offers, as its own `initialize` answer lists it.
struct ClaudeModelOption: Codable, Equatable, Identifiable, Sendable {
    /// Sent verbatim as `--model`: an alias (`sonnet`) or a full ID.
    let value: String
    let displayName: String
    var description: String? = nil
    /// Reasoning levels the model takes; nil when it takes none.
    var supportedEffortLevels: [String]? = nil

    var id: String { value }
    var efforts: [String] { supportedEffortLevels ?? [] }
    /// Claude Code's own default entry: Whytap then sends no `--model`.
    var isCLIDefault: Bool { value == ClaudeModelCatalog.cliDefaultValue }
}

struct ClaudeModelCatalog: Equatable, Sendable {
    static let cliDefaultValue = "default"
    var models: [ClaudeModelOption]
    /// Claude Code's version, shown in the Harness status.
    var cliVersion: String?
}

enum ClaudeModelCatalogError: Error, Equatable {
    case notInstalled
    case timedOut
    case unreadable
}

/// Reads the model list from the user's Claude Code: one `initialize` control
/// request over the stream-json protocol, answered without a model request,
/// so it costs nothing and sends no prompt. The answer also carries the
/// account (e-mail, organization); only models and the version are decoded,
/// and nothing from it is logged. Replaces the earlier scan of the binary for
/// model names, which could not see new families or what the account offers.
// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
struct ClaudeModelCatalogReader {
    static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "agent.cli")
    static let requestID = "whytap-models"
    static let initializeRequest =
        #"{"type":"control_request","request_id":"whytap-models","request":{"subtype":"initialize"}}"#

    var locate: () -> URL? = { ClaudeBinaryLocator().locate() }
    var timeout: TimeInterval = 15
    /// Runs the handshake and returns the matching control_response line.
    var handshake: @Sendable (URL, TimeInterval) throws -> String = ClaudeModelCatalogReader.defaultHandshake

    func read() async throws -> ClaudeModelCatalog {
        guard let binary = locate() else { throw ClaudeModelCatalogError.notInstalled }
        let handshake = self.handshake
        let timeout = self.timeout
        let line = try await Task.detached(priority: .userInitiated) {
            try handshake(binary, timeout)
        }.value
        guard let catalog = Self.parse(controlResponse: line) else {
            os_log("claude catalog: unreadable answer", log: Self.log, type: .error)
            throw ClaudeModelCatalogError.unreadable
        }
        os_log("claude catalog: models=%{public}d", log: Self.log, type: .default, catalog.models.count)
        return catalog
    }

    /// Decodes the `initialize` control_response line. Nil for any other line
    /// or a response without models.
    static func parse(controlResponse line: String) -> ClaudeModelCatalog? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == requestID,
              response["subtype"] as? String == "success",
              let body = response["response"] as? [String: Any],
              let rawModels = body["models"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let models = rawModels.compactMap { entry -> ClaudeModelOption? in
            guard let value = (entry["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !value.contains(where: \.isWhitespace), seen.insert(value).inserted
            else { return nil }
            let name = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
            let supportsEffort = entry["supportsEffort"] as? Bool ?? false
            let levels = supportsEffort ? (entry["supportedEffortLevels"] as? [String]) ?? [] : []
            return ClaudeModelOption(value: value, displayName: name,
                                     description: entry["description"] as? String,
                                     supportedEffortLevels: levels.isEmpty ? nil : levels)
        }
        guard !models.isEmpty else { return nil }
        return ClaudeModelCatalog(models: models, cliVersion: body["claude_code_version"] as? String)
    }

    /// Starts `claude -p` in stream-json mode in the Agent's own folder (the
    /// settings a turn loads), sends `initialize` and stops the child as soon
    /// as the answer arrives. No user message is ever written.
    @Sendable
    static func defaultHandshake(binary: URL, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        process.environment = ClaudeCodeProvider.childEnvironment()
        if let folder = try? AgentDaemonWorkingDirectory.ensure() { process.currentDirectoryURL = folder }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let state = HandshakeState()
        output.fileHandleForReading.readabilityHandler = { handle in
            state.receive(handle.availableData)
        }
        process.terminationHandler = { _ in state.finish(nil) }
        do { try process.run() } catch { throw ClaudeModelCatalogError.notInstalled }
        try? input.fileHandleForWriting.write(contentsOf: Data((initializeRequest + "\n").utf8))

        let timedOut = state.done.wait(timeout: .now() + timeout) == .timedOut
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        if timedOut { throw ClaudeModelCatalogError.timedOut }
        guard let line = state.answer else { throw ClaudeModelCatalogError.unreadable }
        return line
    }
}

/// Collects the handshake's stdout on one serial queue.
private final class HandshakeState: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "com.sidekey.claude-catalog")
    private var lines = ProcessLineBuffer()
    private var received = 0
    private var finished = false
    private var line: String?

    var answer: String? { queue.sync { line } }

    func receive(_ chunk: Data) {
        queue.async {
            guard !self.finished else { return }
            guard !chunk.isEmpty else { return self.complete(nil) }
            self.received += chunk.count
            // Hooks can print before the answer; a runaway stream is cut off.
            guard self.received <= 4 * 1024 * 1024 else { return self.complete(nil) }
            if let match = self.lines.append(chunk).first(where: {
                ClaudeModelCatalogReader.parse(controlResponse: $0) != nil
            }) {
                self.complete(match)
            }
        }
    }

    func finish(_ value: String?) {
        queue.async { self.complete(value) }
    }

    private func complete(_ value: String?) {
        guard !finished else { return }
        finished = true
        line = value
        done.signal()
    }
}
