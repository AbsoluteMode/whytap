import Foundation

/// Uses only `.appControl` requests, even when sharing the authenticated socket.
public final class AppControlCommand {
    private let client: CaseBrokerCalling?
    private let todo: TodoCommand?
    public init(client: CaseBrokerCalling?, todo: TodoCommand? = nil) { self.client = client; self.todo = todo }

    public func call(_ request: AppControlRequest) -> AppControlResponse {
        call(request, cancellation: nil)
    }

    public func call(_ request: AppControlRequest, cancellation: AppControlCancellation?) -> AppControlResponse {
        guard let client else { return .failure("unavailable", "Use the helper inside the installed Whytap app.") }
        do {
            let answer: CaseBrokerResponse
            if let client = client as? CancellableCaseBrokerCalling {
                answer = try client.send(.appControl(request), cancellation: cancellation)
            } else { answer = try client.send(.appControl(request)) }
            guard case .appControl(let response) = answer else {
                return .failure("unavailable", "Application controls are unavailable. Check that the helper belongs to the running Whytap build.")
            }
            return response
        } catch {
            return .failure("unavailable", "Open or update Whytap to a build with application controls, then retry. No change was confirmed; read the current state before retrying a write.")
        }
    }

    public func run(args: [String], readLine: () -> String? = { Swift.readLine() }, write: @escaping (String) -> Void = {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }) -> Int32 {
        if args == ["mcp"] || args == ["screen-mcp"] {
            let server = AppControlMCPServer(screenOnly: args == ["screen-mcp"], todo: todo.map { todo in { todo.respond($0, $1) } },
                                             cancellableCall: { self.call($0, cancellation: $1) })
            server.run(readLine: readLine, write: write)
            return 0
        }
        let names = ["status": "get_state", "settings": "get_settings", "models": "list_models",
                     "set-model": "set_model", "providers": "list_providers", "set-provider": "set_provider",
                     "set-setting": "set_setting"]
        guard let name = args.first, let operation = names[name], args.count <= 2 else {
            write("Usage: whytap app status | settings | models | set-model | providers | set-provider | set-setting [JSON object] | mcp")
            return 2
        }
        let arguments: [String: AppControlValue]
        if args.count == 2 {
            guard args[1].utf8.count <= 16_384, let data = args[1].data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: AppControlValue].self, from: data) else {
                write("Arguments must be a JSON object of at most 16 KiB.")
                return 2
            }
            arguments = decoded
        } else { arguments = [:] }
        let response = call(AppControlRequest(operation, arguments: arguments))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) { write(text) }
        return response.ok ? 0 : 1
    }
}
