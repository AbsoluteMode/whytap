import Foundation

/// `whytap todo add | list`. Delivers to the running app over the helper socket
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
        Usage: whytap todo add "<task>" ["<task>" ...]
               whytap todo add -            (one task per stdin line; blank lines are skipped)
               whytap todo list [--all]
        """

    public func run(args: [String], readLine: () -> String? = { Swift.readLine() },
                    write: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        let operation: String
        let arguments: [String: AppControlValue]
        switch args.first {
        case "add" where args.count >= 2:
            var titles = Array(args.dropFirst())
            if titles == ["-"] {
                titles = []
                while let line = readLine() {
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { titles.append(line) }
                    guard titles.count <= PlannerTodoFile.maxBatch else { break }
                }
            }
            operation = "todo_add"
            arguments = ["titles": .array(titles.map(AppControlValue.string))]
        case "list" where args.count == 1 || args.dropFirst() == ["--all"]:
            operation = "todo_list"
            arguments = args.count == 2 ? ["includeCompleted": .bool(true)] : [:]
        default:
            write(Self.usage)
            return 2
        }
        let response = respond(operation, arguments)
        emit(response, write)
        if response.ok { return 0 }
        return Self.inputErrors.contains(response.data.object?["code"]?.string ?? "") ? 2 : 1
    }

    /// Codes for a request that is wrong as given; nothing was sent or written.
    static let inputErrors: Set<String> = ["invalid_arguments", "empty_title", "title_too_long", "batch_too_large"]

    /// `todo_add {titles: [String]}` or `todo_list {includeCompleted?: Bool}`, shared
    /// by the CLI and the `whytap app mcp` tools: validated locally, delivered to the
    /// running app, or applied to the file when nothing listens.
    public func respond(_ operation: String, _ arguments: [String: AppControlValue]) -> AppControlResponse {
        var arguments = arguments
        switch operation {
        case "todo_add":
            guard arguments.keys.allSatisfy({ $0 == "titles" }),
                  let raw = arguments["titles"]?.array, raw.allSatisfy({ $0.string != nil }) else {
                return .failure("invalid_arguments", "Pass titles as an array of 1–\(PlannerTodoFile.maxBatch) strings.")
            }
            do {
                arguments["titles"] = .array(try PlannerTodoFile.validatedTitles(raw.compactMap(\.string)).map(AppControlValue.string))
            } catch let failure as PlannerTodoFile.Failure { return failure.response } catch {
                return .failure("invalid_arguments", "Invalid task titles.")
            }
            // The app's socket reads at most 64 KiB per request; say so instead of failing unconfirmed.
            let line = try? CaseBrokerCodec.encodeLine(CaseBrokerRequest.appControl(AppControlRequest(operation, arguments: arguments)))
            guard let line, line.count <= Self.maxRequestBytes else {
                return .failure("batch_too_large", "This batch is too large for one request. Split it into smaller batches; nothing was added.")
            }
        case "todo_list":
            guard arguments.keys.allSatisfy({ $0 == "includeCompleted" }),
                  arguments["includeCompleted"] == nil || arguments["includeCompleted"]?.bool != nil else {
                return .failure("invalid_arguments", "includeCompleted must be a boolean.")
            }
        default:
            return .failure("unknown_operation", "Unknown to-do operation.")
        }

        guard let client else { return .failure("unavailable", "Use the helper inside the installed Whytap app.") }
        do {
            guard case .appControl(let answer) = try client.send(.appControl(AppControlRequest(operation, arguments: arguments))) else {
                throw CaseBrokerClientError.protocolFailure
            }
            return answer
        } catch CaseBrokerClientError.unavailable {
            // Nothing was sent and no app is listening: use the file directly.
            return offline(operation, arguments)
        } catch {
            return .failure("unconfirmed", "Whytap did not confirm the request. Run `whytap todo list` to check; retrying add is safe because matching active tasks are not duplicated.")
        }
    }

    private func offline(_ operation: String, _ arguments: [String: AppControlValue]) -> AppControlResponse {
        do {
            if operation == "todo_add" {
                let titles = arguments["titles"]?.array?.compactMap(\.string) ?? []
                return .success(try PlannerTodoFile.addOffline(titles, to: fileURL))
            }
            return .success(try PlannerTodoFile.listOffline(at: fileURL, includeCompleted: arguments["includeCompleted"]?.bool ?? false))
        } catch let failure as PlannerTodoFile.Failure {
            return failure.response
        } catch {
            return .failure("save_failed", "Couldn’t write the to-do file. Check available storage and folder access.")
        }
    }

    private func emit(_ response: AppControlResponse, _ write: (String) -> Void) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) { write(text) }
    }
}
