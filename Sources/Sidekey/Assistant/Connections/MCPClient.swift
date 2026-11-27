import Foundation

/// One tool as the server describes it.
struct MCPToolInfo: Codable, Hashable, Sendable {
    var name: String
    var title: String?
    var description: String
    var inputSchema: MCPValue
    var readOnlyHint: Bool?
    var destructiveHint: Bool?

    /// Pinning: an approved tool whose name, description, schema or hints
    /// change must be approved again. WHY: .project-docs/decisions/2026-11-26-agent-sources.md
    var pinHash: String {
        MCPHash.sha256([name, title ?? "", description, inputSchema.canonicalJSON,
                        readOnlyHint.map(String.init) ?? "-", destructiveHint.map(String.init) ?? "-"]
            .joined(separator: "\n"))
    }

    init(name: String, title: String? = nil, description: String, inputSchema: MCPValue = .object(["type": .string("object")]),
         readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint
    }

    init?(_ value: MCPValue) {
        guard let name = value["name"]?.string, !name.isEmpty, name.count <= 128 else { return nil }
        self.name = name
        title = value["title"]?.string ?? value["annotations"]?["title"]?.string
        description = String((value["description"]?.string ?? "").prefix(2000))
        inputSchema = value["inputSchema"] ?? .object(["type": .string("object")])
        readOnlyHint = value["annotations"]?["readOnlyHint"]?.bool
        destructiveHint = value["annotations"]?["destructiveHint"]?.bool
    }

    /// "search_issues(query*: string, owner: string)": compact enough to list
    /// every allowed tool in the Agent's prompt.
    var signature: String {
        let properties = inputSchema["properties"]?.object ?? [:]
        let required = Set(inputSchema["required"]?.array?.compactMap(\.string) ?? [])
        let parameters = properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
            .prefix(12).map { key -> String in
                let type = properties[key]?["type"]?.string ?? properties[key]?["type"]?.array?.compactMap(\.string).first ?? "any"
                return key + (required.contains(key) ? "*" : "") + ": " + type
            }
        return name + "(" + parameters.joined(separator: ", ") + (properties.count > 12 ? ", …" : "") + ")"
    }
}

struct MCPToolResult: Equatable, Sendable {
    var text: String
    var isError: Bool
    var shortened: Bool
}

/// A minimal MCP client: initialize, tools/list, tools/call, ping and
/// cancellation. No sampling, elicitation or roots: a server cannot ask our
/// model anything. Hand-written instead of the official Swift SDK, which would
/// add swift-nio and three more packages.
///
/// Approval is bound to the exact list: `listTools` returns the epoch it was
/// read under and records each tool's pin; `callTool` checks the caller's
/// lease, the epoch and the tool's pin in the same actor step that sends the
/// request, the transport checks the same authorization again right before
/// the first byte leaves, and the answer is returned only if the epoch and pin
/// still hold when it arrives. A `tools/list_changed` notice, every completed
/// list and an ended session move the epoch, so nothing approved on an older
/// list is sent or returned.
///
/// Every server text is masked with the source's known values when it is
/// decoded, before anything derived from it is clipped (descriptions, results,
/// error messages), so a clip can never leave a fragment of a value.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md
actor MCPClient {
    static let requestedVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"]
    static let maxTools = 500

    private let transport: MCPTransport
    private let mask: SourceSecretMask
    /// `listEpoch` and the closed state, readable off the actor at the send boundary.
    private let authority = MCPAuthority()
    private var pending: [Int: CheckedContinuation<MCPValue, Error>] = [:]
    private var abandoned: Set<Int> = []
    private var nextID = 1
    private var consumer: Task<Void, Never>?
    private(set) var closedError: MCPError?
    private(set) var protocolVersion: String?
    private(set) var serverName: String?
    /// Moved by every `tools/list_changed` notice.
    private(set) var listEpoch = 0
    /// The epoch whose complete list produced `pins`; nil before a list.
    private var pinsEpoch: Int?
    private var pins: [String: String] = [:]
    /// Sends in flight, cancelled when their request is abandoned.
    private var sends: [Int: Task<Void, Never>] = [:]
    private var started = false

    init(transport: MCPTransport, mask: SourceSecretMask = SourceSecretMask([])) {
        self.transport = transport
        self.mask = mask
    }

    private func moveEpoch() {
        listEpoch += 1
        authority.set(epoch: listEpoch, open: closedError == nil)
    }

    var isOpen: Bool { started && closedError == nil }

    /// True until a list read entirely after the last change notice completes.
    var toolsChanged: Bool { pinsEpoch != listEpoch }

    /// The connection's identity for approval: same client, same list.
    var currentEpoch: Int? { isOpen && pinsEpoch == listEpoch ? listEpoch : nil }

    /// One deadline and one cancellation for starting the transport,
    /// initialize and the initialized notice. A start that finishes after the
    /// deadline or a cancellation is closed at once.
    func connect(timeout: TimeInterval) async throws {
        guard !started else { return }
        started = true
        let deadline = Date().addingTimeInterval(timeout)
        do {
            try await MCPDeadline.run(until: deadline, timeout: .timedOut(seconds: MCPDeadline.seconds(until: deadline))) {
                try await self.handshake(deadline: deadline)
            }
        } catch {
            let failure = error as? MCPError ?? .notConnected
            end(failure)
            await transport.close()
            throw failure
        }
    }

    private func handshake(deadline: Date) async throws {
        let (stream, continuation) = AsyncStream<MCPTransportEvent>.makeStream()
        consumer = Task { [weak self] in
            for await event in stream { await self?.handle(event) }
        }
        do { try await transport.start { continuation.yield($0) } }
        catch {
            let failure = error as? MCPError ?? .notConnected
            closedError = failure
            throw failure
        }
        // Started late: the caller already gave up (deadline or cancellation).
        guard !Task.isCancelled, deadline.timeIntervalSinceNow > 0, closedError == nil else {
            await transport.close()
            throw closedError ?? MCPError.cancelled
        }
        let result = try await request("initialize", params: .object([
            "protocolVersion": .string(Self.requestedVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Whytap"), "version": .string(AppBuildIdentity.current.version)]),
        ]), deadline: deadline)
        guard let version = result["protocolVersion"]?.string else { throw MCPError.invalidResponse }
        guard Self.supportedVersions.contains(version) else { throw MCPError.unsupportedProtocol(version) }
        protocolVersion = version
        serverName = result["serverInfo"]?["name"]?.string
        transport.setProtocolVersion(version)
        try await notify("notifications/initialized", deadline: deadline)
    }

    /// Every page under one deadline. `transform` is applied to each tool
    /// before its pin is recorded (the controller masks known secrets), so
    /// pins compare what the controller stores. Returns the epoch the list
    /// was read under; its pins count only if no change notice arrived meanwhile.
    func listTools(timeout: TimeInterval, transform: @Sendable (MCPToolInfo) -> MCPToolInfo? = { $0 })
        async throws -> (tools: [MCPToolInfo], epoch: Int) {
        let deadline = Date().addingTimeInterval(timeout)
        var tools: [MCPToolInfo] = [], cursor: String?
        let epoch = listEpoch
        for _ in 0..<20 {
            let params: MCPValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await request("tools/list", params: params, deadline: deadline)
            // Already masked when decoded; descriptions are clipped only now.
            tools += (result["tools"]?.array ?? []).compactMap(MCPToolInfo.init).compactMap(transform)
            cursor = result["nextCursor"]?.string
            if cursor == nil || tools.count >= Self.maxTools { break }
        }
        var seen = Set<String>()
        let unique = Array(tools.filter { seen.insert($0.name).inserted }.prefix(Self.maxTools))
        // A completed list starts a new epoch: calls approved under an older
        // list, even one with the same tools, are no longer sent or returned.
        // A list overtaken by a change notice keeps its old epoch, which is
        // never current again.
        guard listEpoch == epoch else { return (unique, epoch) }
        moveEpoch()
        pins = Dictionary(uniqueKeysWithValues: unique.map { ($0.name, $0.pinHash) })
        pinsEpoch = listEpoch
        return (unique, listEpoch)
    }

    /// Calls a tool and turns its content into text, clipped to
    /// `maxCharacters`. Sent only if, at the moment of sending, `lease` is
    /// valid, the list is still `epoch` and the tool's pin is `expectedPin`.
    func callTool(_ name: String, arguments: MCPValue, timeout: TimeInterval, maxCharacters: Int,
                  lease: SourceLease, epoch: Int, expectedPin: String) async throws -> MCPToolResult {
        let authority = authority
        let result = try await request("tools/call", params: .object(["name": .string(name), "arguments": arguments]),
                                       deadline: Date().addingTimeInterval(timeout),
                                       authorize: { lease.isValid && authority.isCurrent(epoch) }) { [self] in
            guard lease.isValid, listEpoch == epoch, pinsEpoch == epoch, pins[name] == expectedPin else {
                throw MCPError.notAllowed
            }
        }
        // The answer counts only under the list it was approved for: a change
        // notice or a new list that arrived first voids it.
        guard lease.isValid, isOpen, listEpoch == epoch, pinsEpoch == epoch, pins[name] == expectedPin else {
            throw MCPError.notAllowed
        }
        return Self.toolResult(result, maxCharacters: maxCharacters)
    }

    func ping(timeout: TimeInterval) async throws {
        _ = try await request("ping", params: nil, deadline: Date().addingTimeInterval(timeout))
    }

    func close() async {
        end(.notConnected)
        await transport.close()
        consumer?.cancel()
    }

    /// Ends the client without waiting for the transport: pending requests
    /// fail, sends stop, and the epoch moves so no approval carries over.
    private func end(_ error: MCPError) {
        closedError = closedError ?? error
        moveEpoch()
        failAll(.cancelled)
        sends.values.forEach { $0.cancel() }
        sends.removeAll()
    }

    static func toolResult(_ result: MCPValue, maxCharacters: Int) -> MCPToolResult {
        var parts: [String] = []
        for item in result["content"]?.array ?? [] {
            switch item["type"]?.string {
            case "text": parts.append(item["text"]?.string ?? "")
            case "image", "audio": parts.append("[\(item["type"]?.string ?? "media") omitted]")
            case "resource":
                let resource = item["resource"]
                parts.append(resource?["text"]?.string ?? "[resource \(resource?["uri"]?.string ?? "")]")
            case "resource_link":
                parts.append("[link: \(item["name"]?.string ?? "") \(item["uri"]?.string ?? "")]")
            default: break
            }
        }
        if parts.allSatisfy({ $0.isEmpty }), let structured = result["structuredContent"] {
            parts = [structured.canonicalJSON]
        }
        let text = parts.joined(separator: "\n")
        let shortened = text.count > maxCharacters
        return MCPToolResult(text: shortened ? String(text.prefix(maxCharacters)) : text,
                             isError: result["isError"]?.bool == true, shortened: shortened)
    }

    // MARK: - JSON-RPC

    /// `gate` runs in the same actor step that registers and sends the
    /// request; if it throws, nothing is sent.
    private func request(_ method: String, params: MCPValue?, deadline: Date,
                         authorize: @escaping @Sendable () -> Bool = { true },
                         gate: (() throws -> Void)? = nil) async throws -> MCPValue {
        if let closedError { throw closedError }
        let id = nextID
        nextID += 1
        var message: [String: MCPValue] = ["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        let data = try MCPValue.object(message).encoded()
        let seconds = MCPDeadline.seconds(until: deadline)
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, deadline.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.abandon(id, reason: .timedOut(seconds: seconds))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPValue, Error>) in
                register(id, continuation, data: data, deadline: deadline, authorize: authorize, gate: gate)
            }
        } onCancel: {
            Task { [weak self] in await self?.abandon(id, reason: .cancelled) }
        }
    }

    private func register(_ id: Int, _ continuation: CheckedContinuation<MCPValue, Error>, data: Data, deadline: Date,
                          authorize: @escaping @Sendable () -> Bool, gate: (() throws -> Void)?) {
        if abandoned.remove(id) != nil { continuation.resume(throwing: MCPError.cancelled); return }
        if let closedError { continuation.resume(throwing: closedError); return }
        do { try gate?() } catch { continuation.resume(throwing: error); return }
        pending[id] = continuation
        let transport = transport
        sends[id] = Task { [weak self] in
            // The transport checks `authorize` again right before the first byte.
            do { try await transport.send(data, responseID: id, deadline: deadline, authorize: authorize) }
            catch { await self?.sendFailed(id, error as? MCPError ?? .network) }
            await self?.sendFinished(id)
        }
    }

    private func sendFinished(_ id: Int) { sends[id] = nil }

    private func sendFailed(_ id: Int, _ error: MCPError) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
        // Another session or a stopped server: this client is done.
        if error == .sessionExpired || error == .notConnected { end(error) }
        if case .timedOut = error, closedError == nil { end(error) }
    }

    /// Timeout or cancellation: stop waiting, stop the send itself, and tell
    /// the server within a bounded time.
    private func abandon(_ id: Int, reason: MCPError) async {
        guard let continuation = pending.removeValue(forKey: id) else {
            if id >= nextID - 1, reason == .cancelled { abandoned.insert(id) }
            return
        }
        continuation.resume(throwing: reason)
        sends.removeValue(forKey: id)?.cancel()
        guard closedError == nil, let data = try? MCPValue.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(Double(id)), "reason": .string(reason == .cancelled ? "cancelled" : "timeout")])
        ]).encoded() else { return }
        let transport = transport
        Task { try? await transport.send(data, responseID: nil, deadline: Date().addingTimeInterval(3)) }
    }

    private func notify(_ method: String, params: MCPValue? = nil, deadline: Date) async throws {
        guard closedError == nil else { return }
        var message: [String: MCPValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        let data = try MCPValue.object(message).encoded()
        let transport = transport
        try await MCPDeadline.run(until: deadline, timeout: .timedOut(seconds: MCPDeadline.seconds(until: deadline))) {
            try await transport.send(data, responseID: nil, deadline: deadline)
        }
    }

    private func failAll(_ error: MCPError) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    private func handle(_ event: MCPTransportEvent) async {
        switch event {
        case .closed(let error):
            if closedError == nil { closedError = error }
            moveEpoch()
            failAll(closedError ?? error)
        case .message(let data):
            // Servers sometimes print logs to stdout; a non-JSON line is skipped.
            guard let decoded = try? MCPValue.decode(data) else { return }
            // Masked whole, before any clip derived from it.
            let value = mask.value(decoded)
            for message in value.array ?? [value] { await handleMessage(message) }
        }
    }

    private func handleMessage(_ message: MCPValue) async {
        let method = message["method"]?.string
        if method == nil, let id = message["id"]?.int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: MCPError.server(code: error["code"]?.int ?? 0,
                                                              message: error["message"]?.string ?? ""))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        guard let method else { return }
        if let id = message["id"] {
            // Server-to-client requests: only ping is answered.
            let reply: [String: MCPValue] = method == "ping"
                ? ["jsonrpc": .string("2.0"), "id": id, "result": .object([:])]
                : ["jsonrpc": .string("2.0"), "id": id,
                   "error": .object(["code": .number(-32601), "message": .string("Method not supported by Whytap")])]
            if let data = try? MCPValue.object(reply).encoded() {
                let transport = transport
                Task { try? await transport.send(data, responseID: nil, deadline: Date().addingTimeInterval(5)) }
            }
            return
        }
        if method == "notifications/tools/list_changed" { moveEpoch() }
    }
}

/// The client's list epoch and open state, readable from any thread, so a
/// transport can check a call's authorization at the moment it sends.
final class MCPAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = 0
    private var open = true
    func set(epoch: Int, open: Bool) { lock.withLock { self.epoch = epoch; self.open = open } }
    func isCurrent(_ epoch: Int) -> Bool { lock.withLock { open && self.epoch == epoch } }
}
