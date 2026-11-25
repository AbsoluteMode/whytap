import Foundation

/// `whytap case ls | run`. Logic lives in the kit so it is testable; the
/// executable only wires real I/O.
public struct CaseCommand {
    public static let exitDenied: Int32 = 2
    public static let exitAmbiguous: Int32 = 3
    public static let exitUnavailable: Int32 = 4
    public static let exitUsage: Int32 = 64

    private let client: CaseBrokerCalling?
    private let executablePath: String
    private let unavailableMessage: String
    private let cwd: URL
    private let stdout: FileHandle
    private let stderr: FileHandle
    /// `case mcp` of the installed helper follows a Whytap update in place.
    // WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md
    private let mcpHandover: MCPBuildHandover?

    /// `client == nil` means the app could not be located (exit 4 with `unavailableMessage`).
    public init(
        client: CaseBrokerCalling?,
        executablePath: String = "whytap",
        unavailableMessage: String = "Whytap is not available. Open the Whytap app and try again.",
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError,
        mcpHandover: MCPBuildHandover? = nil
    ) {
        self.mcpHandover = mcpHandover
        self.client = client
        self.executablePath = executablePath
        self.unavailableMessage = unavailableMessage
        self.cwd = cwd
        self.stdout = stdout
        self.stderr = stderr
    }

    public static let usage = """
    usage: whytap case <command>

    commands:
      ls [-p <project>]                          list key names (no values)
      mcp                                        serve names (never values) over MCP on stdio
      run [-p <project>] [--only A,B] '<cmd>'    run a command with Case keys in its environment
    """

    /// `args` excludes the program name and starts with `case`.
    public func run(args: [String]) -> Int32 {
        guard args.first == "case", args.count >= 2 else { return usageError() }
        let rest = Array(args.dropFirst(2))
        switch args[1] {
        case "ls": return list(rest)
        case "run": return runCommand(rest)
        case "mcp": return serveMCP()
        default: return usageError()
        }
    }

    // MARK: mcp

    private func serveMCP() -> Int32 {
        let server = CaseMCPServer(client: client, executablePath: executablePath)
        if let mcpHandover {
            server.run(source: FileDescriptorLineSource(prefill: mcpHandover.resumed?.input ?? Data()),
                       write: { write(stdout, $0 + "\n") }, handover: mcpHandover)
        } else {
            server.run(readLine: { Swift.readLine(strippingNewline: true) }, write: { write(stdout, $0 + "\n") })
        }
        return 0
    }

    // MARK: ls

    private func list(_ args: [String]) -> Int32 {
        var project: String?
        var i = 0
        while i < args.count {
            if args[i] == "-p", i + 1 < args.count { project = args[i + 1]; i += 2 } else { return usageError() }
        }
        switch call(.listKeys(project: project)) {
        case .exit(let code): return code
        case .response(.keys(let keys)):
            let nameWidth = max(4, keys.map { $0.name.count }.max() ?? 0)
            let projWidth = max(7, keys.map { $0.project.count }.max() ?? 0)
            func row(_ a: String, _ b: String, _ c: String) -> String {
                a.padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  "
                    + b.padding(toLength: projWidth, withPad: " ", startingAt: 0) + "  " + c
            }
            var lines = [row("NAME", "PROJECT", "DESCRIPTION")]
            lines += keys.map { row($0.name, $0.project, $0.description) }
            write(stdout, lines.joined(separator: "\n") + "\n")
            return 0
        case .response(let other): return handleNonSuccess(other)
        }
    }

    // MARK: run

    private func runCommand(_ args: [String]) -> Int32 {
        var project: String?
        var only: [String]?
        var rest: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            // Options end at the command: `run grep --only x f` keeps `--only x`
            // and `run git checkout -- file` keeps `--` in the command.
            if !rest.isEmpty { rest += args[i...]; break }
            // Only a `--` before the command word ends Case options.
            if a == "--" { rest += args[(i + 1)...]; break }
            if a == "-p", i + 1 < args.count { project = args[i + 1]; i += 2; continue }
            if a == "--only", i + 1 < args.count {
                only = args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                i += 2; continue
            }
            if a.hasPrefix("-") { return usageError() }
            rest.append(a); i += 1
        }
        guard !rest.isEmpty else { return usageError() }
        let command = rest.joined(separator: " ")

        switch call(.resolveRun(project: project, only: only, command: command, cwd: cwd.path)) {
        case .exit(let code): return code
        case .response(.runEnvironment(let env)):
            let masker = CaseOutputMasker(secrets: Array(env.values))
            do {
                return try MaskedProcessRunner.run(
                    command: command, environment: env, cwd: cwd, masker: masker,
                    stdout: stdout, stderr: stderr)
            } catch {
                write(stderr, "whytap: could not start the command.\n")
                return 126
            }
        case .response(let other): return handleNonSuccess(other)
        }
    }

    // MARK: helpers

    private func call(_ request: CaseBrokerRequest) -> Outcome {
        guard let client else {
            write(stderr, unavailableMessage + "\n")
            return .exit(CaseCommand.exitUnavailable)
        }
        do { return .response(try client.send(request)) } catch {
            write(stderr, "Whytap Case broker is unavailable. Open the Whytap app, unlock Case and try again.\n")
            return .exit(CaseCommand.exitUnavailable)
        }
    }

    private func handleNonSuccess(_ response: CaseBrokerResponse) -> Int32 {
        switch response {
        case .denied(let reason):
            write(stderr, "Access denied: \(Self.describe(reason)).\n"
                + "Register this app in Whytap -> Case -> Connect.\n")
            return CaseCommand.exitDenied
        case .ambiguous(let key, let projects):
            var text = "The key \(key) exists in several projects:\n"
            for p in projects { text += "\(p.name) - \(p.description)\n" }
            text += "Re-run with -p <project>; if unsure, ask the user which project\n"
            write(stderr, text)
            return CaseCommand.exitAmbiguous
        default:
            write(stderr, "Unexpected answer from the Whytap Case broker.\n")
            return CaseCommand.exitUnavailable
        }
    }

    static func describe(_ reason: CaseDenyReason) -> String {
        switch reason {
        case .notRegistered: return "this app is not registered"
        case .unknownAIApp: return "the calling app is not recognized"
        case .userDeclined: return "the user declined the request"
        case .timedOut: return "the approval request timed out"
        case .touchIDFailed: return "Touch ID verification failed"
        case .unknownProject: return "unknown project"
        case .unknownKey: return "unknown key"
        case .untrustedHelper: return "this helper is not trusted"
        case .vaultUnavailable: return "the vault is locked or unavailable"
        }
    }

    private func usageError() -> Int32 {
        write(stderr, CaseCommand.usage + "\n")
        return CaseCommand.exitUsage
    }

    private func write(_ handle: FileHandle, _ text: String) {
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private enum Outcome { case response(CaseBrokerResponse), exit(Int32) }
}
