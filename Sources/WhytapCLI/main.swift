import Foundation
import WhytapCaseKit

// `whytap case ls | run`, `whytap app …`, `whytap todo …`. Locates the enclosing app (Ruling 3) at runtime.
let executable = URL(fileURLWithPath: CommandLine.arguments[0].contains("/")
    ? CommandLine.arguments[0]
    : (Bundle.main.executablePath ?? CommandLine.arguments[0]))
let hostExecutable = Bundle.main.executableURL ?? executable

var client: CaseBrokerCalling?
var directClient: CaseBrokerCalling?
let message = "Whytap is not available: this helper is not inside the Whytap app bundle."
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
}
let resolvedPath = hostExecutable.resolvingSymlinksInPath().path
if CommandLine.arguments.dropFirst().first == "todo" {
    // Never launches Whytap: when it is not running the planner file is edited directly.
    exit(TodoCommand(client: directClient).run(args: Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "app" {
    exit(AppControlCommand(client: client).run(args: Array(CommandLine.arguments.dropFirst(2))))
}
exit(CaseCommand(client: client, executablePath: resolvedPath, unavailableMessage: message)
    .run(args: Array(CommandLine.arguments.dropFirst())))
