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
            do { titles = try PlannerTodoFile.validatedTitles(titles) } catch let failure as PlannerTodoFile.Failure {
                emit(failure.response, write)
                return 2
            } catch { return 2 }
            operation = "todo_add"
            arguments = ["titles": .array(titles.map(AppControlValue.string))]
            // The app's socket reads at most 64 KiB per request; say so instead of failing unconfirmed.
            let line = try? CaseBrokerCodec.encodeLine(CaseBrokerRequest.appControl(AppControlRequest(operation, arguments: arguments)))
            guard let line, line.count <= Self.maxRequestBytes else {
                emit(.failure("batch_too_large", "This batch is too large for one request. Split it into smaller batches; nothing was added."), write)
                return 2
            }
        case "list" where args.count == 1 || args.dropFirst() == ["--all"]:
            operation = "todo_list"
            arguments = args.count == 2 ? ["includeCompleted": .bool(true)] : [:]
        default:
            write(Self.usage)
            return 2
        }

        guard let client else {
            emit(.failure("unavailable", "Use the helper inside the installed Whytap app."), write)
            return 1
        }
        let response: AppControlResponse
        do {
            guard case .appControl(let answer) = try client.send(.appControl(AppControlRequest(operation, arguments: arguments))) else {
                throw CaseBrokerClientError.protocolFailure
            }
            response = answer
        } catch CaseBrokerClientError.unavailable {
            // Nothing was sent and no app is listening: use the file directly.
            response = offline(operation, arguments)
        } catch {
            response = .failure("unconfirmed", "Whytap did not confirm the request. Run `whytap todo list` to check; retrying add is safe because matching active tasks are not duplicated.")
        }
        emit(response, write)
        return response.ok ? 0 : 1
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
