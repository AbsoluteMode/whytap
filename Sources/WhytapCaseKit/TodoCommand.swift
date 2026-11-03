import Foundation

/// `whytap todo add | set | done | reopen | list`. Delivers to the running app over the helper socket
/// without launching it; when nothing listens there, edits the planner file
/// under the shared lock instead. Prints one JSON object.
// WHY: .project-docs/decisions/2026-11-03-todo-helper.md
public final class TodoCommand {
    private let client: CaseBrokerCalling?
    private let fileURL: URL

    /// `client` must not launch the app: an unreachable socket selects the file path.
    public init(client: CaseBrokerCalling?, fileURL: URL = PlannerTodoFile.defaultURL) {
        self.client = client
        self.fileURL = fileURL
    }

    /// Below the broker's 64 KiB request limit (`CaseBrokerServer.defaultMaxRequestBytes`).
    static let maxRequestBytes = 60 * 1024

    public static let usage = """
        Usage: whytap todo add [--parent ID] [--status TEXT] "<task>" ["<task>" ...]
               whytap todo add [--parent ID] -              (one task per stdin line; blank lines are skipped)
               whytap todo add [--parent ID] --json '<JSON>'   (or --json - for stdin)
                   JSON: [{"title": "...", "status": "...", "children": [ ... ]}, ...]
               whytap todo set ID [--title TEXT] [--status TEXT | --no-status] [--parent ID | --top]
               whytap todo done ID      (closes the task and all its open subtasks)
               whytap todo reopen ID
               whytap todo list [--all]
        IDs are full task ids or a unique prefix of at least 8 characters.
        """

    public func run(args: [String], readLine: () -> String? = { Swift.readLine() },
                    write: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        guard let (operation, arguments) = parse(args, readLine: readLine) else {
            write(Self.usage)
            return 2
        }
        let response = respond(operation, arguments)
        emit(response, write)
        if response.ok { return 0 }
        return Self.inputErrors.contains(response.data.object?["code"]?.string ?? "") ? 2 : 1
    }

    private func parse(_ args: [String], readLine: () -> String?) -> (String, [String: AppControlValue])? {
        guard let command = args.first else { return nil }
        var rest = Array(args.dropFirst())
        func take(_ flag: String) -> String?? {
            guard let index = rest.firstIndex(of: flag) else { return .some(nil) }
            guard index + 1 < rest.count else { return nil }
            let value = rest[index + 1]
            rest.removeSubrange(index...index + 1)
            return .some(value)
        }
        func flag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }
        func stdinLines() -> [String] {
            var lines: [String] = []
            while let line = readLine() {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
                guard lines.count <= PlannerTodoFile.maxBatch else { break }
            }
            return lines
        }
        switch command {
        case "add":
            guard let parent = take("--parent"), let status = take("--status"), let json = take("--json") else { return nil }
            var arguments: [String: AppControlValue] = [:]
            if let parent { arguments["parentID"] = .string(parent) }
            if let json {
                guard rest.isEmpty, status == nil else { return nil }
                let text = json == "-" ? stdinLines().joined(separator: "\n") : json
                // Malformed JSON reaches validation as a non-array and is reported there.
                arguments["tasks"] = (try? JSONDecoder().decode(AppControlValue.self, from: Data(text.utf8))) ?? .string(text)
                return ("todo_add", arguments)
            }
            let titles = rest == ["-"] ? stdinLines() : rest
            guard !rest.isEmpty, !rest.contains(where: { $0.hasPrefix("--") }) else { return nil }
            if let status {
                arguments["tasks"] = .array(titles.map { .object(["title": .string($0), "status": .string(status)]) })
            } else {
                arguments["titles"] = .array(titles.map(AppControlValue.string))
            }
            return ("todo_add", arguments)
        case "set":
            guard let id = rest.first, !id.hasPrefix("--") else { return nil }
            rest.removeFirst()
            guard let title = take("--title"), let status = take("--status"), let parent = take("--parent") else { return nil }
            let clearStatus = flag("--no-status"), top = flag("--top")
            guard rest.isEmpty, !(clearStatus && status != nil), !(top && parent != nil) else { return nil }
            var arguments: [String: AppControlValue] = ["id": .string(id)]
            if let title { arguments["title"] = .string(title) }
            if let status { arguments["status"] = .string(status) }
            if clearStatus { arguments["status"] = .null }
            if let parent { arguments["parentID"] = .string(parent) }
            if top { arguments["parentID"] = .null }
            return ("todo_update", arguments)
        case "done", "reopen":
            guard rest.count == 1 else { return nil }
            return ("todo_update", ["id": .string(rest[0]), "completed": .bool(command == "done")])
        case "list":
            guard rest.isEmpty || rest == ["--all"] else { return nil }
            return ("todo_list", rest.isEmpty ? [:] : ["includeCompleted": .bool(true)])
        default:
            return nil
        }
    }

    /// Codes for a request that is wrong as given; nothing was sent or written.
    static let inputErrors: Set<String> = ["invalid_arguments", "empty_title", "title_too_long", "status_too_long",
                                           "too_deep", "batch_too_large"]

    /// `todo_add`, `todo_update` or `todo_list`, shared by the CLI and the
    /// `whytap app mcp` tools: validated locally, delivered to the running app,
    /// or applied to the file when nothing listens.
    public func respond(_ operation: String, _ arguments: [String: AppControlValue]) -> AppControlResponse {
        let request: TodoRequest
        do { request = try TodoRequest(operation, arguments) } catch let failure as PlannerTodoFile.Failure {
            return failure.response
        } catch { return .failure("invalid_arguments", "Invalid to-do request.") }
        if request.mutates {
            // The app's socket reads at most 64 KiB per request; say so instead of failing unconfirmed.
            let line = try? CaseBrokerCodec.encodeLine(CaseBrokerRequest.appControl(AppControlRequest(operation, arguments: request.arguments)))
            guard let line, line.count <= Self.maxRequestBytes else {
                return .failure("batch_too_large", "This batch is too large for one request. Split it into smaller batches; nothing was changed.")
            }
        }
        guard let client else { return .failure("unavailable", "Use the helper inside the installed Whytap app.") }
        do {
            guard case .appControl(let answer) = try client.send(.appControl(AppControlRequest(operation, arguments: request.arguments))) else {
                throw CaseBrokerClientError.protocolFailure
            }
            return answer
        } catch CaseBrokerClientError.unavailable {
            // Nothing was sent and no app is listening: use the file directly.
            return offline(request)
        } catch {
            return .failure("unconfirmed", "Whytap did not confirm the request. Run `whytap todo list` to check; retrying add is safe because matching active tasks are not duplicated.")
        }
    }

    private func offline(_ request: TodoRequest) -> AppControlResponse {
        do { return .success(try PlannerTodoFile.applyOffline(request, at: fileURL)) }
        catch let failure as PlannerTodoFile.Failure { return failure.response }
        catch { return .failure("save_failed", "Couldn’t write the to-do file. Check available storage and folder access.") }
    }

    private func emit(_ response: AppControlResponse, _ write: (String) -> Void) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) { write(text) }
    }
}
