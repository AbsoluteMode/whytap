import Darwin
import XCTest
@testable import Sidekey

/// In-memory process table: pid -> info. Peer/helper checks are scripted.
private final class FakeProcessInspector: CaseProcessInspecting {
    var table: [pid_t: CaseProcessInfo] = [:]
    private(set) var lookups: [pid_t] = []

    func add(_ pid: pid_t, parent: pid_t, _ path: String, team: String? = nil, id: String? = nil) {
        table[pid] = CaseProcessInfo(
            pid: pid, parentPID: parent, executablePath: path, teamID: team, signingIdentifier: id)
    }

    func info(pid: pid_t) -> CaseProcessInfo? {
        lookups.append(pid)
        return table[pid]
    }

    func peer(of socket: Int32) -> (pid: pid_t, auditToken: audit_token_t)? { nil }
    func isTrustedHelper(auditToken: audit_token_t, helperURL: URL) -> Bool { false }
}

final class CaseCallerResolverTests: XCTestCase {
    private let helper = "/Applications/Whytap.app/Contents/Helpers/whytap"
    private let claudeBinary = "/Users/maxim/Library/Application Support/Claude/claude-code/2.1.0/claude.app/Contents/MacOS/claude"

    private func registration(_ name: String, _ identity: CaseAppIdentity) -> CaseAppRegistration {
        CaseAppRegistration(
            id: UUID(), displayName: name, identity: identity,
            defaultMode: .approve, projectModes: [:], createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    private var claudeCodeRegistration: CaseAppRegistration {
        registration("Claude Code", .developerID(teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code"))
    }

    /// The real chain seen on this Mac for a command run from the Claude desktop app.
    private func claudeDesktopChain(_ fake: FakeProcessInspector, cliPID: pid_t = 900) {
        fake.add(cliPID, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 600, claudeBinary, team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
        fake.add(600, parent: 500, "/Applications/Claude.app/Contents/Helpers/disclaimer",
                 team: "Q6L2SF6YDW", id: "com.anthropic.claude-disclaimer")
        fake.add(500, parent: 1, "/Applications/Claude.app/Contents/MacOS/Claude",
                 team: "Q6L2SF6YDW", id: "com.anthropic.claudefordesktop")
    }

    // MARK: Brief scenarios

    func test_claude_code_ancestor_matches_developer_id_registration() {
        let fake = FakeProcessInspector()
        claudeDesktopChain(fake)
        let reg = claudeCodeRegistration
        let resolver = CaseCallerResolver(inspector: fake, registrations: [reg])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .registered(reg))
    }

    func test_unregistered_known_ai_is_reported() {
        // Codex: native binary signed by OpenAI, launched by node codex.js, from Terminal.
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 600, "/opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex",
                 team: "2DC432GLL2", id: "codex")
        fake.add(600, parent: 550, "/opt/homebrew/bin/node")
        fake.add(550, parent: 500, "/bin/zsh")
        fake.add(500, parent: 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                 id: "com.apple.Terminal")
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .knownUnregisteredAI(name: "Codex"))
    }

    func test_unregistered_claude_code_is_reported_by_name() {
        let fake = FakeProcessInspector()
        claudeDesktopChain(fake)
        let resolver = CaseCallerResolver(inspector: fake, registrations: [])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .knownUnregisteredAI(name: "Claude Code"))
    }

    func test_terminal_only_chain_is_human() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 600, "/usr/bin/login", id: "com.apple.login")
        fake.add(600, parent: 1, "/Applications/iTerm.app/Contents/MacOS/iTerm2",
                 team: "H7V7XYVQ7D", id: "com.googlecode.iterm2")
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    func test_terminal_app_name_for_the_touch_id_reason() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 600, "/usr/bin/login", id: "com.apple.login")
        fake.add(600, parent: 1, "/Applications/iTerm.app/Contents/MacOS/iTerm2",
                 team: "H7V7XYVQ7D", id: "com.googlecode.iterm2")
        let resolver = CaseCallerResolver(inspector: fake, registrations: [])
        XCTAssertEqual(resolver.terminalAppName(peerPID: 900), "iTerm2", "nearest app ancestor, not the shell")

        // sshd / launchd job / cron: the walk reaches pid 1 without a terminal app.
        let headless = FakeProcessInspector()
        headless.add(900, parent: 800, helper)
        headless.add(800, parent: 700, "/bin/zsh")
        headless.add(700, parent: 1, "/usr/sbin/sshd")
        XCTAssertNil(CaseCallerResolver(inspector: headless, registrations: [])
            .terminalAppName(peerPID: 900))

        // A broken chain is unknown too.
        let broken = FakeProcessInspector()
        broken.add(900, parent: 800, helper)
        XCTAssertNil(CaseCallerResolver(inspector: broken, registrations: [])
            .terminalAppName(peerPID: 900))
    }

    func test_path_registration_matches_ancestor() {
        // npm OpenCode is ad-hoc signed (identifier a.out, no team): path only.
        let opencode = "/Users/maxim/.npm-global/lib/node_modules/opencode-ai/node_modules/opencode-darwin-arm64/bin/opencode"
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 600, opencode, id: "a.out")
        fake.add(600, parent: 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let reg = registration("OpenCode", .executablePath(opencode))
        let resolver = CaseCallerResolver(inspector: fake, registrations: [reg])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .registered(reg))
    }

    func test_bundle_path_registration_matches_nested_helper_executable() {
        // Cursor's terminal runs under a helper deep inside its bundle.
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 600,
                 "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        fake.add(600, parent: 1, "/Applications/Cursor.app/Contents/MacOS/Cursor")
        let reg = registration("Cursor", .executablePath("/Applications/Cursor.app/"))
        let resolver = CaseCallerResolver(inspector: fake, registrations: [reg])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .registered(reg))
    }

    func test_path_prefix_requires_component_boundary() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 1, "/Applications/Cursor.app.evil/Contents/MacOS/Cursor")
        let reg = registration("Cursor", .executablePath("/Applications/Cursor.app"))
        let resolver = CaseCallerResolver(inspector: fake, registrations: [reg])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    func test_empty_path_registration_never_matches() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 1, "/bin/zsh")
        let regs = [registration("Empty", .executablePath("")), registration("Root", .executablePath("/"))]
        let resolver = CaseCallerResolver(inspector: fake, registrations: regs)
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    /// The earlier in-app agent no longer runs: a stored registration for it
    /// never matches, even for a process that looks like its old OpenCode.
    func test_builtin_opencode_registration_never_matches() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/sh")
        fake.add(700, parent: 600, "/Users/maxim/Library/Application Support/whytap/bin/opencode", id: "a.out")
        fake.add(600, parent: 1, "/Applications/Whytap.app/Contents/MacOS/Sidekey")
        let reg = registration("Whytap agent", .builtInOpenCode)
        let resolver = CaseCallerResolver(inspector: fake, registrations: [reg])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    // MARK: Spoofing and nesting

    func test_ad_hoc_binary_claiming_claude_identifier_is_not_claude() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 1, "/tmp/claude", team: nil, id: "com.anthropic.claude-code")
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    func test_other_team_with_claude_identifier_is_not_claude() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 1, "/tmp/claude", team: "AAAAAAAAAA", id: "com.anthropic.claude-code")
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    func test_nearest_ancestor_wins_unregistered_codex_inside_registered_claude() {
        // Codex started from a Claude Code shell: Codex is the one asking.
        let fake = FakeProcessInspector()
        fake.add(900, parent: 850, helper)
        fake.add(850, parent: 840, "/bin/zsh")
        fake.add(840, parent: 830, "/opt/codex/codex", team: "2DC432GLL2", id: "codex")
        fake.add(830, parent: 800, "/opt/homebrew/bin/node")
        claudeDesktopChain(fake, cliPID: 899)
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .knownUnregisteredAI(name: "Codex"))
    }

    func test_nearest_ancestor_wins_registered_inside_unregistered() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 850, helper)
        fake.add(850, parent: 840, "/bin/zsh")
        fake.add(840, parent: 830, claudeBinary, team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
        fake.add(830, parent: 820, "/bin/zsh")
        fake.add(820, parent: 1, "/opt/codex/codex", team: "2DC432GLL2", id: "codex")
        let reg = claudeCodeRegistration
        let resolver = CaseCallerResolver(inspector: fake, registrations: [reg])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .registered(reg))
    }

    func test_peer_itself_is_not_treated_as_the_calling_app() {
        // Registering the Whytap bundle path must not make the CLI vouch for itself.
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 1, "/bin/zsh")
        let reg = registration("Whytap", .executablePath("/Applications/Whytap.app"))
        let resolver = CaseCallerResolver(inspector: fake, registrations: [reg])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    // MARK: Broken chains

    func test_vanished_peer_is_human() {
        let fake = FakeProcessInspector()
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    func test_chain_broken_by_vanished_parent_is_human() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        // 800 exited; its old parent is unknowable.
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    func test_launchd_and_kernel_are_never_inspected() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 1, "/bin/zsh")
        fake.add(1, parent: 0, "/sbin/launchd", team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
        XCTAssertFalse(fake.lookups.contains(1))
    }

    func test_parent_cycle_terminates() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 800, helper)
        fake.add(800, parent: 700, "/bin/zsh")
        fake.add(700, parent: 800, "/bin/zsh")
        let resolver = CaseCallerResolver(inspector: fake, registrations: [claudeCodeRegistration])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
        XCTAssertLessThanOrEqual(fake.lookups.count, 4)
    }

    func test_self_parent_terminates() {
        let fake = FakeProcessInspector()
        fake.add(900, parent: 900, helper)
        let resolver = CaseCallerResolver(inspector: fake, registrations: [])
        XCTAssertEqual(resolver.resolve(peerPID: 900), .human)
    }

    func test_ancestor_at_32_hops_is_found_and_beyond_is_not() {
        func chain(depth: Int) -> FakeProcessInspector {
            // peer 1000, ancestors 1001...; the Claude binary sits at `depth` hops.
            let fake = FakeProcessInspector()
            fake.add(1000, parent: 1001, helper)
            for hop in 1..<depth {
                fake.add(pid_t(1000 + hop), parent: pid_t(1001 + hop), "/bin/zsh")
            }
            fake.add(pid_t(1000 + depth), parent: 1, claudeBinary, team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
            return fake
        }
        let reg = claudeCodeRegistration
        XCTAssertEqual(
            CaseCallerResolver(inspector: chain(depth: 32), registrations: [reg]).resolve(peerPID: 1000),
            .registered(reg))
        let deep = chain(depth: 33)
        XCTAssertEqual(
            CaseCallerResolver(inspector: deep, registrations: [reg]).resolve(peerPID: 1000),
            .human)
        XCTAssertLessThanOrEqual(deep.lookups.count, 33)
    }

    func test_invalid_peer_pid_is_human() {
        let fake = FakeProcessInspector()
        let resolver = CaseCallerResolver(inspector: fake, registrations: [])
        XCTAssertEqual(resolver.resolve(peerPID: 0), .human)
        XCTAssertEqual(resolver.resolve(peerPID: -5), .human)
        XCTAssertTrue(fake.lookups.isEmpty)
    }

    func test_known_ai_list_matches_verified_identities() {
        XCTAssertEqual(CaseCallerResolver.knownAIApps.map(\.name), ["Claude Code", "Codex"])
        XCTAssertEqual(CaseCallerResolver.knownAIApps.map(\.teamID), ["Q6L2SF6YDW", "2DC432GLL2"])
        XCTAssertEqual(CaseCallerResolver.knownAIApps.map(\.identifier), ["com.anthropic.claude-code", "codex"])
    }
}

/// Real syscalls against the test process itself. Signatures are not asserted:
/// the test runner's signing differs between Xcode and command-line toolchains.
final class CaseSystemProcessInspectorTests: XCTestCase {
    func test_inspects_current_process_and_parent() throws {
        let inspector = CaseSystemProcessInspector()
        let me = try XCTUnwrap(inspector.info(pid: getpid()))
        XCTAssertEqual(me.pid, getpid())
        XCTAssertEqual(me.parentPID, getppid())
        XCTAssertTrue(me.executablePath.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: me.executablePath))

        let parent = try XCTUnwrap(inspector.info(pid: getppid()))
        XCTAssertEqual(parent.pid, getppid())
        XCTAssertFalse(parent.executablePath.isEmpty)
    }

    func test_missing_process_returns_nil() {
        XCTAssertNil(CaseSystemProcessInspector().info(pid: 0))
        XCTAssertNil(CaseSystemProcessInspector().info(pid: -1))
    }

    func test_socket_peer_is_current_process() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let peer = try XCTUnwrap(CaseSystemProcessInspector().peer(of: fds[0]))
        XCTAssertEqual(peer.pid, getpid())
    }

    func test_peer_of_invalid_socket_is_nil() {
        XCTAssertNil(CaseSystemProcessInspector().peer(of: -1))
        let pipeFDs = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { pipeFDs.deallocate() }
        XCTAssertEqual(pipe(pipeFDs), 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }
        XCTAssertNil(CaseSystemProcessInspector().peer(of: pipeFDs[0]))
    }

    func test_helper_check_rejects_a_different_file_and_missing_file() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let inspector = CaseSystemProcessInspector()
        let peer = try XCTUnwrap(inspector.peer(of: fds[0]))
        XCTAssertFalse(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: URL(fileURLWithPath: "/bin/ls")))
        XCTAssertFalse(inspector.isTrustedHelper(
            auditToken: peer.auditToken, helperURL: URL(fileURLWithPath: "/nonexistent/Contents/Helpers/whytap")))
    }

    func test_helper_check_accepts_the_peers_own_executable() throws {
        // The test runner is at least linker-signed (ad-hoc), so its own file's
        // cdhash must equal the running code's: the same check the broker makes
        // against Contents/Helpers/whytap.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let inspector = CaseSystemProcessInspector()
        let peer = try XCTUnwrap(inspector.peer(of: fds[0]))
        let me = try XCTUnwrap(inspector.info(pid: getpid()))
        XCTAssertTrue(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: URL(fileURLWithPath: me.executablePath)))
    }
}
