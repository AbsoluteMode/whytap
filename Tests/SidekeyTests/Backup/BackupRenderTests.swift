import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class BackupRenderTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    private var renderModels: [BackupViewModel] = []
    private var renderSession: URLSession?
    private var renderRoot: URL?

    override func tearDown() async throws {
        // NSHostingView can deliver its .task after the hidden window closes.
        // Stop rejects late deliveries; drain every retained request before
        // invalidating the session or resetting the shared protocol fixture.
        for model in renderModels { await model.stopAndWait() }
        renderModels.removeAll()
        renderSession?.invalidateAndCancel(); renderSession = nil
        StubURLProtocol.reset()
        if let renderRoot { try? FileManager.default.removeItem(at: renderRoot) }
        renderRoot = nil
    }

    private final class InMemoryTokenStore: TokenStore {
        var value: String?
        func save(_ token: String) throws { value = token }
        func read() throws -> String? { value }
        func delete() throws { value = nil }
    }

    private func makeIsolatedModel(temporaryRoot: URL, session: URLSession = GitHubBackupNetwork.session) -> BackupViewModel {
        let suiteName = "exodia.backup.render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let localRoot = temporaryRoot.appendingPathComponent("local", isDirectory: true)
        let settingsRoot = temporaryRoot.appendingPathComponent("settings", isDirectory: true)
        var environment = ArtifactBackupEnvironment()
        environment.locations = .isolated(root: temporaryRoot)
        environment.defaults = defaults
        environment.credentialStore = { _ in InMemoryTokenStore() }
        environment.caseVaultKeys = StubCaseVaultKeys()
        environment.pendingKeyStore = InMemoryTokenStore()
        environment.recoveryKeyStore = InMemoryTokenStore()
        let engine = ArtifactBackupEngine(environment: environment)
        let fixtureEngine = BackupEngineActions(
            create: { try await engine.createArchive(at: $0, key: $1) },
            inspect: { try await engine.inspectArchive(at: $0, key: $1) },
            stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) })
        let model = BackupViewModel(
            defaults: defaults,
            keyStore: InMemoryTokenStore(),
            githubTokenStore: InMemoryTokenStore(),
            local: BackupLocalStore(root: localRoot),
            settingsFiles: ConfigBackupFiles(root: settingsRoot),
            engine: fixtureEngine,
            changeProbe: { "" },
            idle: { true }, providerStore: { _ in InMemoryTokenStore() }, previousRestoreOutcome: { nil }, githubSession: session
        )
        renderModels.append(model)
        return model
    }

    func testBackupSettingsTabMetadataAndOrdering() {
        XCTAssertTrue(SettingsWindowTab.allCases.contains(.backup))
        XCTAssertEqual(SettingsWindowTab.backup.title, "Backup")
        XCTAssertEqual(SettingsWindowTab.backup.fallbackSystemImageName, "externaldrive.badge.timemachine")
        XCTAssertNil(SettingsWindowTab.backup.pdfResourceName)

        let all = SettingsWindowTab.allCases
        guard let backupIndex = all.firstIndex(of: .backup),
              let otherIndex = all.firstIndex(of: .other) else {
            XCTFail("Expected both .backup and .other in SettingsWindowTab.allCases")
            return
        }
        XCTAssertEqual(backupIndex + 1, otherIndex, "Backup tab must be inserted immediately before Other")
        XCTAssertEqual(all.last, .other)
    }

    func testOffscreenBackupSettingsFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_BACKUP_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_BACKUP_RENDER_DIR for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        renderRoot = root
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        renderSession = session
        let fixture = BackupGitHubFixture(json: { try! JSONSerialization.data(withJSONObject: $0) })
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let model = makeIsolatedModel(temporaryRoot: root, session: session)
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertTrue(model.canUseGitHubBackup)
        let disconnected = makeIsolatedModel(temporaryRoot: root.appendingPathComponent("disconnected"), session: session)
        try render(hosted(SettingsBackupView(model: disconnected)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-disconnected.png"))
        try render(hosted(SettingsIntegrationsView(model: disconnected)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("integrations-disconnected.png"))
        await model.backupEverything()
        model.hideRecoveryCode()
        XCTAssertEqual(model.syncState, .synced)
        await model.stopAndWait() // Freeze the fixture before offscreen view tasks arrive.
        for width in [560, 760] {
            try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: width, height: 380),
                       to: directory.appendingPathComponent("backup-synced-\(width).png"))
            try render(hosted(SettingsBackupView(model: model), scheme: .light), size: NSSize(width: width, height: 380),
                       to: directory.appendingPathComponent("backup-synced-light-\(width).png"), appearance: .aqua)
        }
        for scheme in [ColorScheme.dark, .light] {
            let label = scheme == .dark ? "dark" : "light"
            try render(hosted(interactionSamples, scheme: scheme), size: NSSize(width: 900, height: 300),
                       to: directory.appendingPathComponent("backup-control-states-\(label).png"),
                       appearance: scheme == .dark ? .darkAqua : .aqua)
        }
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-connected.png"))
        try render(hosted(SettingsIntegrationsView(model: model)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("integrations-connected.png"))
        model.recoveryCode = try ConfigBackupArchive.recoveryCode(for: Data(repeating: 0xAB, count: 32))
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-code.png"))
        model.hideRecoveryCode()
        try render(hosted(SettingsBackupView(model: model, showRestore: true)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-restore.png"))
        model.errorMessage = "GitHub is unavailable. Your local backup is kept."
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-error.png"))
        model.errorMessage = nil
        model.requireRecoveryCodePresentation()
        XCTAssertEqual(model.syncState, .recoveryCodeNeeded)
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-save-code.png"))
        model.setEnabled(false)
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-paused.png"))
        model.setEnabled(true)
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-pending.png"))
        model.isBusy = true
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-syncing.png"))
        model.isBusy = false; model.needsRestart = true
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-ready.png"))
    }

    private var interactionSamples: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<4) { kind in
                HStack(spacing: 14) {
                    ForEach(0..<5) { state in
                        VStack(spacing: 8) {
                            Text(["Normal", "Hover", "Pressed", "Focus", "Disabled"][state])
                                .font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                            Text(["Back up", "Restore backup", "GitHub ↗", "Show recovery code"][kind])
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(kind == 0 ? Color.white : kind == 3 ? MacSettingsTheme.accent : MacSettingsTheme.text)
                                .padding(.horizontal, 13).padding(.vertical, 5)
                                .background {
                                    MacButtonInteractionSurface(
                                        background: kind == 0 ? MacSettingsTheme.accentFill : kind == 1 ? MacSettingsTheme.controlBg : .clear,
                                        highlight: kind == 0 ? .black : MacSettingsTheme.text,
                                        outline: kind == 3 ? MacSettingsTheme.accent : nil,
                                        hovered: state == 1 || state == 4, pressed: state == 2 || state == 4,
                                        focused: state == 3 || state == 4, enabled: state != 4)
                                }
                                .opacity(state == 4 ? 0.42 : 1)
                        }
                    }
                }
            }
        }.padding(16)
    }

    private func hosted<V: View>(_ view: V, scheme: ColorScheme = .dark) -> some View {
        view
            .background(MacSettingsTheme.bgContent)
            .environment(\.colorScheme, scheme)
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL,
                                 appearance: NSAppearance.Name = .darkAqua) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
