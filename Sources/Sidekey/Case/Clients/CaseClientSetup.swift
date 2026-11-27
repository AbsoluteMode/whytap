import Foundation
import WhytapCaseKit

/// The apps offered as one-click registrations. Identities match
/// `CaseCallerResolver.knownAIApps` (Developer ID) or a bundle path.
enum CaseKnownClient: String, CaseIterable, Equatable {
    case claudeCode
    case codex
    case cursor
    case builtInOpenCode

    /// The current Connect catalog. Preserve legacy identities and registrations:
    /// `builtInOpenCode` (the earlier in-app agent) is kept only so a stored
    /// registration still reads and can be removed.
    // WHY: .project-docs/decisions/2026-11-23-case-connect-codex.md
    static let connectableClients: [CaseKnownClient] = [.claudeCode, .codex, .cursor]

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .builtInOpenCode: return "Whytap Agent"
        }
    }

    var identity: CaseAppIdentity {
        switch self {
        case .claudeCode: return .developerID(teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code")
        case .codex: return .developerID(teamID: "2DC432GLL2", signingIdentifier: "codex")
        case .cursor: return .executablePath(CursorCaseConnector.appPath)
        case .builtInOpenCode: return .builtInOpenCode
        }
    }

    /// One terminal for the person and the agent: in Bypass the person's
    /// commands there are not asked either (spec, «Коннектор» item 10).
    var hasSharedTerminal: Bool { self == .cursor }

    init?(identity: CaseAppIdentity) {
        guard let match = Self.allCases.first(where: { $0.identity == identity }) else { return nil }
        self = match
    }
}

struct CaseClientSetupReport: Equatable {
    /// User-facing lines, one per failed step. Empty = everything configured.
    var problems: [String] = []
}

/// Client-side work around a registration in Case: the CLI symlink and the
/// client's MCP entry. Failures are reported, never thrown, so the
/// registration in Case itself always stands.
/// A new registration and what could not be configured on the client side.
struct CaseRegistrationResult: Equatable {
    let appID: UUID
    let problems: [String]
}

protocol CaseClientConfiguring: AnyObject {
    func detectInstalledClients() async -> [CaseKnownClient]
    func connect(_ identity: CaseAppIdentity) async -> CaseClientSetupReport
    func disconnect(_ identity: CaseAppIdentity) async -> CaseClientSetupReport
}

final class CaseClientSetup: CaseClientConfiguring {
    static let helperMissingMessage = "The whytap helper is missing from the app, so agents weren’t set up"

    private let helperURL: URL?
    private let binDir: URL
    private let flavorName: String
    private let connectors: [CaseKnownClient: CaseClientConnector]

    init(helperURL: URL?, binDir: URL, flavorName: String,
         connectors: [CaseKnownClient: CaseClientConnector]) {
        self.helperURL = helperURL
        self.binDir = binDir
        self.flavorName = flavorName
        self.connectors = connectors
    }

    static func live() -> CaseClientSetup {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? BuildConfig.bundleID
        let socket = CaseBrokerPaths.socketURL(bundleID: bundleID).path
        return CaseClientSetup(
            helperURL: WhytapBundledHelper.bundledHelperURL,
            binDir: CaseCLIInstaller.defaultBinDir,
            flavorName: CaseCLIInstaller.currentFlavorName,
            connectors: [
                .claudeCode: ClaudeCodeCaseConnector(home: home, socketPath: socket),
                .codex: CodexCaseConnector(home: home),
                .cursor: CursorCaseConnector(home: home),
            ])
    }

    func detectInstalledClients() async -> [CaseKnownClient] {
        let connectors = connectors
        // Locators may ask a login shell; keep that off the main thread.
        return await Task.detached {
            CaseKnownClient.connectableClients.filter { client in
                connectors[client]?.isInstalled() ?? false
            }
        }.value
    }

    /// Which of `clients` are on this Mac, whatever the Connect catalog
    /// offers. The onboarding asks about Claude Code and Codex only.
    func installed(among clients: [CaseKnownClient]) async -> [CaseKnownClient] {
        let connectors = connectors
        return await Task.detached {
            clients.filter { connectors[$0]?.isInstalled() ?? false }
        }.value
    }

    /// Whether `client` is on this Mac, and its `whytap` MCP entry compared
    /// with the one Connect writes for this app's helper. Read only: nothing is
    /// written and no client setting changes.
    // WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
    func presence(of client: CaseKnownClient) async -> (installed: Bool, entry: WhytapEntryState) {
        guard let connector = connectors[client] else { return (false, .none) }
        let helperURL = helperURL
        return await Task.detached {
            guard connector.isInstalled() else { return (false, .none) }
            // Without a helper that runs, no entry is Whytap's working one:
            // an entry that names it (or a blank command) is just an entry.
            guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                return (true, connector.whytapEntry(helperPath: "\u{0}") == .none ? .none : .custom)
            }
            return (true, connector.whytapEntry(helperPath: helperURL.path))
        }.value
    }

    func connect(_ identity: CaseAppIdentity) async -> CaseClientSetupReport {
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return CaseClientSetupReport(problems: [Self.helperMissingMessage])
        }
        let client = CaseKnownClient(identity: identity)
        let connector = client.flatMap { connectors[$0] }
        let binDir = binDir
        let flavorName = flavorName
        return await Task.detached {
            var problems: [String] = []
            do {
                try CaseCLIInstaller.install(flavorName: flavorName, helperURL: helperURL, binDir: binDir)
            } catch let error as CaseCLIInstallerError {
                problems.append("whytap command: \(error.userMessage)")
            } catch {
                problems.append("whytap command: not installed")
            }
            if let connector {
                do {
                    try connector.install(helperPath: helperURL.path)
                } catch {
                    problems.append("\(connector.displayName): \(Self.message(error))")
                }
            }
            return CaseClientSetupReport(problems: problems)
        }.value
    }

    func disconnect(_ identity: CaseAppIdentity) async -> CaseClientSetupReport {
        guard let client = CaseKnownClient(identity: identity), let connector = connectors[client] else {
            return CaseClientSetupReport()
        }
        let helperPath = helperURL?.path
        return await Task.detached {
            do {
                try connector.uninstall(helperPath: helperPath)
                return CaseClientSetupReport()
            } catch {
                return CaseClientSetupReport(problems: ["\(connector.displayName): \(Self.message(error))"])
            }
        }.value
    }

    private static func message(_ error: Error) -> String {
        (error as? CaseClientConnectorError)?.userMessage ?? "setup failed"
    }
}

// MARK: Whytap's helper

/// The running app's bundled `whytap` helper (Case CLI and Whytap MCP server).
enum WhytapBundledHelper {
    static var bundledHelperURL: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        let helper = bundle.appendingPathComponent("Contents/Helpers/whytap")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }
}
