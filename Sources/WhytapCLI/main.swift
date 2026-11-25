import Foundation
import WhytapCaseKit

// `whytap mcp`, `whytap case ls | run | mcp`, `whytap app …`, `whytap todo …`. Locates the enclosing app (Ruling 3) at runtime.
let executable = URL(fileURLWithPath: CommandLine.arguments[0].contains("/")
    ? CommandLine.arguments[0]
    : (Bundle.main.executablePath ?? CommandLine.arguments[0]))
let arguments = Array(CommandLine.arguments.dropFirst())
let servesMCP = [["mcp"], ["app", "mcp"], ["app", "screen-mcp"], ["case", "mcp"]].contains(arguments)
// A long-lived MCP server started before a Whytap update follows the new
// helper file in place instead of being denied until the harness reconnects.
// The state is taken in every mode so no child process inherits it.
// WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md
let carried = MCPResumeState.takeFromEnvironment()
// Resume only as the exact build the previous image verified. It keeps
// running from its private copy (the app reads the helper's executable path).
let resumed = carried.flatMap { state -> MCPResumeState? in
    guard servesMCP else { return nil }
    return state.admitted(runningHash: SystemHelperBuildIdentity.runningHash()) {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }
}
// A resumed image runs from that copy but serves as the installed helper.
let hostExecutable = resumed?.helperPath.map { URL(fileURLWithPath: $0) } ?? Bundle.main.executableURL ?? executable

var client: CaseBrokerCalling?
var directClient: CaseBrokerCalling?
let message = "Whytap is not available: this helper is not inside the Whytap app bundle."
let resolvedPath = hostExecutable.resolvingSymlinksInPath().path
var handover: MCPBuildHandover?
if servesMCP, let bundleID = CaseHostBundle.bundleID(forExecutable: hostExecutable) {
    let stagingRoot = HelperStaging.root(bundleID: bundleID)
    let identity = SystemHelperBuildIdentity(executable: URL(fileURLWithPath: resolvedPath), stagingRoot: stagingRoot)
    // The signer this image was launched with; read while the file still is
    // the running code, off the handshake path.
    identity.captureBaselineInBackground()
    let runningFrom = resumed?.stagingDirectory
    DispatchQueue.global(qos: .utility).async { HelperStaging.sweep(root: stagingRoot, keeping: runningFrom) }
    handover = MCPBuildHandover(
        identity: identity,
        resumed: resumed,
        helperPath: resolvedPath,
        relaunch: { staged, state in
            // Exactly the private copy that passed validation.
            HelperRelauncher.exec(path: staged.executable, arguments: CommandLine.arguments, state: state)
            return false // exec returned: nothing was executed
        })
}
if let bundleID = CaseHostBundle.bundleID(forExecutable: hostExecutable) {
    let socket = CaseBrokerPaths.socketURL(bundleID: bundleID)
    directClient = UnixSocketBrokerClient(socketURL: socket, timeout: 15)
    client = LaunchingBrokerClient(
        inner: UnixSocketBrokerClient(socketURL: socket),
        launch: {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-b", bundleID]
            try? open.run()
            open.waitUntilExit()
        })
    if let handover, let inner = client, let direct = directClient {
        client = BuildFollowingBrokerClient(inner: inner, handover: handover)
        directClient = BuildFollowingBrokerClient(inner: direct, handover: handover)
    }
}
if CommandLine.arguments.dropFirst().first == "todo" {
    // Never launches Whytap: when it is not running the planner file is edited directly.
    exit(TodoCommand(client: directClient).run(args: Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "mcp" {
    // One MCP server for agents: the `app mcp` tools plus the names-only Case
    // tools of `case mcp`. Both older commands keep working for existing setups.
    // WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
    guard CommandLine.arguments.count == 2 else {
        FileHandle.standardError.write(Data("usage: whytap mcp\n".utf8))
        exit(CaseCommand.exitUsage)
    }
    exit(AppControlCommand(client: client, todo: TodoCommand(client: directClient), direct: directClient, handover: handover)
        .serveMCP(caseServer: CaseMCPServer(client: client, executablePath: resolvedPath)))
}
if CommandLine.arguments.dropFirst().first == "app" {
    // `app mcp` also serves the To-do tools through the same non-launching path.
    exit(AppControlCommand(client: client, todo: TodoCommand(client: directClient), direct: directClient, handover: handover)
        .run(args: Array(CommandLine.arguments.dropFirst(2))))
}
exit(CaseCommand(client: client, executablePath: resolvedPath, unavailableMessage: message, mcpHandover: handover)
    .run(args: Array(CommandLine.arguments.dropFirst())))
