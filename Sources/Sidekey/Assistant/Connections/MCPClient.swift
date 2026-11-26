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
/// add swift-nio and three more packages. WHY: .project-docs/decisions/2026-11-26-agent-sources.md
actor MCPClient {
    static let requestedVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"]
    static let maxTools = 500

    private let transport: MCPTransport
    private var pending: [Int: CheckedContinuation<MCPValue, Error>] = [:]
    private var abandoned: Set<Int> = []
    private var nextID = 1
    private var consumer: Task<Void, Never>?
    private(set) var closedError: MCPError?
    private(set) var protocolVersion: String?
    private(set) var serverName: String?
    /// Set by `notifications/tools/list_changed`; cleared only by a list that
    /// completed after the last such notice, so a failed or concurrent
    /// re-list never leaves old tools looking current.
    private(set) var toolsChanged = false
    private var changeEpoch = 0
    /// Sends in flight, cancelled when their request is abandoned.
    private var sends: [Int: Task<Void, Never>] = [:]
    private var started = false

    init(transport: MCPTransport) { self.transport = transport }

    var isOpen: Bool { started && closedError == nil }

    func connect(timeout: TimeInterval) async throws {
        guard !started else { return }
        started = true
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
        let result = try await request("initialize", params: .object([
            "protocolVersion": .string(Self.requestedVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Whytap"), "version": .string(AppBuildIdentity.current.version)]),
        ]), timeout: timeout)
        guard let version = result["protocolVersion"]?.string else { throw MCPError.invalidResponse }
        guard Self.supportedVersions.contains(version) else { throw MCPError.unsupportedProtocol(version) }
        protocolVersion = version
        serverName = result["serverInfo"]?["name"]?.string
        transport.setProtocolVersion(version)
        try await notify("notifications/initialized")
    }

    func listTools(timeout: TimeInterval) async throws -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = [], cursor: String?
        let epoch = changeEpoch
        for _ in 0..<20 {
            let params: MCPValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await request("tools/list", params: params, timeout: timeout)
            tools += (result["tools"]?.array ?? []).compactMap(MCPToolInfo.init)
            cursor = result["nextCursor"]?.string
            if cursor == nil || tools.count >= Self.maxTools { break }
        }
        var seen = Set<String>()
        if changeEpoch == epoch { toolsChanged = false }
        return Array(tools.filter { seen.insert($0.name).inserted }.prefix(Self.maxTools))
    }

    /// Calls a tool and turns its content into text, clipped to `maxCharacters`.
    func callTool(_ name: String, arguments: MCPValue, timeout: TimeInterval, maxCharacters: Int) async throws -> MCPToolResult {
        let result = try await request("tools/call", params: .object(["name": .string(name), "arguments": arguments]),
                                       timeout: timeout)
        return Self.toolResult(result, maxCharacters: maxCharacters)
    }

    func ping(timeout: TimeInterval) async throws { _ = try await request("ping", params: nil, timeout: timeout) }

    func close() async {
        closedError = closedError ?? .notConnected
        failAll(.cancelled)
        sends.values.forEach { $0.cancel() }
        sends.removeAll()
        await transport.close()
        consumer?.cancel()
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

    private func request(_ method: String, params: MCPValue?, timeout: TimeInterval) async throws -> MCPValue {
        if let closedError { throw closedError }
        let id = nextID
        nextID += 1
        var message: [String: MCPValue] = ["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        let data = try MCPValue.object(message).encoded()
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.abandon(id, reason: .timedOut(seconds: Int(timeout.rounded())))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPValue, Error>) in
                register(id, continuation, data: data)
            }
        } onCancel: {
            Task { [weak self] in await self?.abandon(id, reason: .cancelled) }
        }
    }

    private func register(_ id: Int, _ continuation: CheckedContinuation<MCPValue, Error>, data: Data) {
        if abandoned.remove(id) != nil { continuation.resume(throwing: MCPError.cancelled); return }
        if let closedError { continuation.resume(throwing: closedError); return }
        pending[id] = continuation
        let transport = transport
        sends[id] = Task { [weak self] in
            do { try await transport.send(data, responseID: id) }
            catch { await self?.fail(id, error as? MCPError ?? .network) }
            await self?.sendFinished(id)
        }
    }

    private func sendFinished(_ id: Int) { sends[id] = nil }

    /// Timeout or cancellation: stop waiting and tell the server.
    private func abandon(_ id: Int, reason: MCPError) async {
        guard let continuation = pending.removeValue(forKey: id) else {
            if id >= nextID - 1, reason == .cancelled { abandoned.insert(id) }
            return
        }
        continuation.resume(throwing: reason)
        // Stop the send itself (an HTTP request in flight), then tell the
        // server, without waiting for it.
        sends.removeValue(forKey: id)?.cancel()
        guard closedError == nil, let data = try? MCPValue.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(Double(id)), "reason": .string(reason == .cancelled ? "cancelled" : "timeout")])
        ]).encoded() else { return }
        let transport = transport
        let notice = Task { try? await transport.send(data, responseID: nil) }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); notice.cancel() }
    }

    private func fail(_ id: Int, _ error: MCPError) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func notify(_ method: String, params: MCPValue? = nil) async throws {
        guard closedError == nil else { return }
        var message: [String: MCPValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        try await transport.send(try MCPValue.object(message).encoded(), responseID: nil)
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
            failAll(closedError ?? error)
        case .message(let data):
            // Servers sometimes print logs to stdout; a non-JSON line is skipped.
            guard let value = try? MCPValue.decode(data) else { return }
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
            if let data = try? MCPValue.object(reply).encoded() { try? await transport.send(data, responseID: nil) }
            return
        }
        if method == "notifications/tools/list_changed" { toolsChanged = true; changeEpoch += 1 }
    }
}
