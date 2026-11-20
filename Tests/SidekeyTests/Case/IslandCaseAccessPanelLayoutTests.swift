import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen renders of the Case access screen. The window sits at -20 000 pt
/// and is never ordered front: no visible or key windows.
@MainActor
final class IslandCaseAccessPanelLayoutTests: XCTestCase {
    private let serversID = UUID()
    private let terraID = UUID()

    func test_access_panel_renders_registrations_at_310pt_without_overflow() async throws {
        let width: CGFloat = 310
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let claudeID = UUID()
        let cursorID = UUID()
        var payload = CaseVaultPayload(projects: [
            CaseProject.general(now: date),
            CaseProject(id: serversID, name: "servers", description: "", createdAt: date, updatedAt: date),
            CaseProject(id: terraID, name: "terra-hiring", description: "", createdAt: date, updatedAt: date),
        ])
        payload.apps = [
            CaseAppRegistration(id: claudeID, displayName: "Claude Code", identity: CaseKnownClient.claudeCode.identity,
                                defaultMode: .approve, projectModes: [serversID: .bypass], createdAt: date),
            CaseAppRegistration(id: UUID(), displayName: "Codex", identity: CaseKnownClient.codex.identity,
                                defaultMode: .approve, projectModes: [:], createdAt: date),
            CaseAppRegistration(id: UUID(), displayName: "OpenCode", identity: .builtInOpenCode,
                                defaultMode: .bypass, projectModes: [:], createdAt: date),
            CaseAppRegistration(id: cursorID, displayName: "Cursor", identity: CaseKnownClient.cursor.identity,
                                defaultMode: .bypass, projectModes: [:], createdAt: date),
        ]
        payload.apps[0].allowedProjectIDs = [serversID]
        payload.timedApprovalMinutes = 25

        let service = CaseVaultService(store: AccessStubStore(payload: payload), keyProvider: AccessStubKeys())
        let viewModel = CaseViewModel(service: service, authenticator: AccessStubAuthenticator(),
                                      pasteboard: AccessStubPasteboard(),
                                      scheduleIdleLock: { _, _ in AccessStubCancellable() },
                                      clients: FakeClientSetup())
        try await viewModel.unlock()
        XCTAssertFalse(viewModel.registrations.contains { $0.identity == .builtInOpenCode },
                       "Legacy builtInOpenCode registration stays hidden from the access UI")

        let panel = IslandCaseAccessPanel(viewModel: viewModel, onBack: {}, appID: claudeID)
        XCTAssertLessThanOrEqual(measuredWidth(panel, width: width), width)

        // Hint only for the shared-terminal editor in Bypass.
        XCTAssertTrue(IslandCaseAccessPanel.showsSharedTerminalHint(app: payload.apps[3], known: .cursor))
        XCTAssertFalse(IslandCaseAccessPanel.showsSharedTerminalHint(app: payload.apps[0], known: .claudeCode))
        var cursorApprove = payload.apps[3]
        cursorApprove.defaultMode = .approve
        XCTAssertFalse(IslandCaseAccessPanel.showsSharedTerminalHint(app: cursorApprove, known: .cursor))
        cursorApprove.projectModes[serversID] = .bypass
        XCTAssertTrue(IslandCaseAccessPanel.showsSharedTerminalHint(app: cursorApprove, known: .cursor))
        let custom = CaseAppRegistration(id: UUID(), displayName: "Zed", identity: .executablePath("/Applications/Zed.app"),
                                         defaultMode: .bypass, projectModes: [:], createdAt: date)
        XCTAssertTrue(IslandCaseAccessPanel.showsSharedTerminalHint(app: custom, known: nil))

        try withBrandAssets {
            for width in [CGFloat(310), CGFloat(390)] {
                for (name, appID) in [("selected", claudeID as UUID?), ("all", payload.apps[1].id as UUID?), ("bypass", cursorID as UUID?), ("connect", nil)] {
                    try renderPanel(IslandCaseAccessPanel(viewModel: viewModel, onBack: {}, appID: appID),
                                    width: width, name: "case-access-\(name)-\(Int(width))")
                }
            }
        }
    }

    private func renderPanel<V: View>(_ panel: V, width: CGFloat, name: String) throws {
        let height = IslandCaseVaultStyle.panelHeight
        XCTAssertLessThanOrEqual(measuredWidth(panel, width: width), width)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(panel.frame(width: width, height: height)
            .background(Color(white: 0.08)).environment(\.colorScheme, .dark)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["EXODIA_CASE_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }

    func test_picker_ready_and_empty_states_fit_the_native_viewport() throws {
        try withBrandAssets {
            for width in [CGFloat(310), CGFloat(390)] {
                for (name, clients, loading, connected) in [
                    ("all", CaseKnownClient.connectableClients, false, false),
                    ("cursor", [.cursor], false, false),
                    ("claude-code", [.claudeCode], false, false),
                    ("empty", [], false, false),
                    ("connected", [], false, true),
                    ("loading", [], true, false),
                ] {
                    try renderPanel(IslandCaseClientPicker(clients: clients, isLoading: loading,
                                                          hasConnectedClients: connected, onChoose: { _ in })
                        .padding(10), width: width, name: "case-picker-\(name)-\(Int(width))")
                }
            }
        }
    }

    func test_empty_picker_copy_and_connected_strip_omit_retired_whytap_agent() throws {
        XCTAssertEqual(IslandCaseClientPicker.emptyMessage, "Install Claude Code or Cursor, then open Connect again.")
        XCTAssertFalse(IslandCaseClientPicker.emptyMessage.contains("OpenCode"))
        XCTAssertFalse(IslandCaseClientPicker.emptyMessage.contains("Whytap Agent"))

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let retired = CaseAppRegistration(id: UUID(), displayName: "Whytap Agent", identity: .builtInOpenCode,
                                          defaultMode: .bypass, projectModes: [:], createdAt: date)
        let claude = CaseAppRegistration(id: UUID(), displayName: "Claude Code", identity: CaseKnownClient.claudeCode.identity,
                                         defaultMode: .approve, projectModes: [:], createdAt: date)
        let cursor = CaseAppRegistration(id: UUID(), displayName: "Cursor", identity: CaseKnownClient.cursor.identity,
                                         defaultMode: .approve, projectModes: [:], createdAt: date)
        XCTAssertEqual(IslandCaseConnectedApps.visibleRegistrations([retired, claude]), [claude])
        XCTAssertEqual(IslandCaseConnectedApps.visibleRegistrations([retired]), [])
        XCTAssertNil(IslandCaseConnectedApps.brandAsset(for: .builtInOpenCode))

        try withBrandAssets {
            let withRetired = IslandCaseConnectedApps(registrations: [retired, claude], onOpenAccess: { _ in }, onConnect: {}).fixedSize()
            let withoutRetired = IslandCaseConnectedApps(registrations: [claude], onOpenAccess: { _ in }, onConnect: {}).fixedSize()
            let twoApps = IslandCaseConnectedApps(registrations: [claude, cursor], onOpenAccess: { _ in }, onConnect: {}).fixedSize()
            XCTAssertEqual(measuredWidth(withRetired, width: 500), measuredWidth(withoutRetired, width: 500))
            XCTAssertLessThan(measuredWidth(withRetired, width: 500), measuredWidth(twoApps, width: 500))
            try renderPanel(IslandCaseConnectedApps(registrations: [retired, claude], onOpenAccess: { _ in }, onConnect: {})
                .padding(10), width: 310, name: "case-connected-retired-hidden-310")
        }
    }

    func test_project_search_matches_metadata_terms_and_preserves_order() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let projects = [
            CaseProject.general(now: date),
            CaseProject(id: serversID, name: "Серверы Café", description: "Production Europe", createdAt: date, updatedAt: date),
            CaseProject(id: terraID, name: "terra-hiring", description: "Тестовый стенд", createdAt: date, updatedAt: date),
        ]
        XCTAssertEqual(CaseAccessProjectPicker.filteredProjects(projects, query: " \n "), projects)
        XCTAssertEqual(CaseAccessProjectPicker.filteredProjects(projects, query: "CAFE серверы").map(\.id), [serversID])
        XCTAssertEqual(CaseAccessProjectPicker.filteredProjects(projects, query: "europe prod").map(\.id), [serversID])
        XCTAssertEqual(CaseAccessProjectPicker.filteredProjects(projects, query: "ТЕСТОВЫЙ").map(\.id), [terraID])
        XCTAssertEqual(CaseAccessProjectPicker.filteredProjects(projects, query: "general").map(\.id), [CaseProject.generalID])
        XCTAssertTrue(CaseAccessProjectPicker.filteredProjects(projects, query: "missing").isEmpty)
        XCTAssertTrue(CaseAccessProjectPicker.filteredProjects(projects, query: "cafe hiring").isEmpty)
    }

    func test_project_search_results_and_empty_state_fit_the_native_viewport() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let projects = [
            CaseProject.general(now: date),
            CaseProject(id: serversID, name: "Очень длинное название проекта — production Europe", description: "Серверы", createdAt: date, updatedAt: date),
            CaseProject(id: terraID, name: "terra-hiring", description: "", createdAt: date, updatedAt: date),
        ]
        for width in [CGFloat(310), CGFloat(390)] {
            for (name, query, enabled) in [("all", "", true), ("match", "серверы", true),
                                            ("empty", "missing", true), ("disabled", "серверы", false)] {
                try renderPanel(ScrollView {
                    CaseAccessProjectPicker(projects: projects, query: .constant(query),
                                            selection: .constant([serversID, terraID]))
                        .disabled(!enabled).padding(20)
                }, width: width, name: "case-scope-search-\(name)-\(Int(width))")
            }
        }
    }

    func test_native_search_edit_keeps_the_full_project_selection() async throws {
        _ = NSApplication.shared
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let projects = [
            CaseProject(id: serversID, name: "servers", description: "", createdAt: date, updatedAt: date),
            CaseProject(id: terraID, name: "terra-hiring", description: "", createdAt: date, updatedAt: date),
        ]
        var query = ""
        var selection: Set<UUID> = [serversID, terraID]
        var scopeWrites = 0
        let picker = CaseAccessProjectPicker(projects: projects,
                                             query: Binding(get: { query }, set: { query = $0 }),
                                             selection: Binding(get: { selection }, set: {
                                                 selection = $0
                                                 scopeWrites += 1
                                             }))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 310, height: 320),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: picker)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(host).first)
        for text in ["servers", "missing", ""] {
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(query, text)
            XCTAssertEqual(selection, [serversID, terraID], "Hidden projects must stay selected")
        }
        XCTAssertEqual(scopeWrites, 0, "Search must not edit access rights")
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }

    func test_client_highlights_render_in_provider_colors() throws {
        try withBrandAssets {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let clients: [CaseKnownClient] = [.cursor, .codex, .claudeCode]
            let row = HStack(spacing: 30) {
                ForEach(clients, id: \.self) { client in
                    let app = CaseAppRegistration(id: UUID(), displayName: client.displayName, identity: client.identity,
                                                  defaultMode: .approve, projectModes: [:], createdAt: date)
                    VStack(spacing: 8) {
                        CaseConnectedAppIcon(app: app, isHighlighted: true, isFocused: true)
                        Text(client.displayName).font(.system(size: 10)).foregroundStyle(.white)
                    }
                }
            }
            .padding(20)
            try renderPanel(row, width: 310, name: "case-provider-highlights")
        }
    }

    func test_interaction_feedback_states_render_without_geometry_changes() throws {
        let states = [("normal", false, false, false, true), ("hover", true, false, false, true),
                      ("pressed", true, true, false, true), ("focus", false, false, true, true),
                      ("disabled", true, true, true, false)]
        let panel = VStack(spacing: 8) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Text(state.0).font(.system(size: 12)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 35)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                    .overlay(CaseAccessInteractionOverlay(hovering: state.1, pressed: state.2,
                                                          focused: state.3, enabled: state.4))
                    .opacity(state.4 ? 1 : 0.4)
            }
        }.padding(12)
        try renderPanel(panel, width: 310, name: "case-interaction-states-310")
    }

    private func withBrandAssets(_ body: () throws -> Void) throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        ProviderBrandIconAsset.setResourceDirectoryForTesting(root.appendingPathComponent("Resources/UsefulLinkIcons"))
        defer {
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
            ProviderBrandIconAsset.clearCacheForTesting()
        }
        // Every Connect row draws a bundled brand mark, never the generic fallback.
        let assets = CaseKnownClient.connectableClients.compactMap { IslandCaseConnectedApps.brandAsset(for: $0.identity) }
        XCTAssertEqual(assets, ["claude-code", "cursor"])
        for asset in assets {
            let image = try XCTUnwrap(ProviderBrandIconAsset.image(named: asset, pointSize: 22))
            XCTAssertEqual(image.size, NSSize(width: 22, height: 22))
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let inkPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter {
                    (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1
                }.count
            }
            XCTAssertGreaterThan(inkPixels, bitmap.pixelsWide * bitmap.pixelsHigh / 10,
                                 "\(asset) must contain visible artwork, not an empty PDF mask")
        }
        try body()
    }

    func test_error_messages_are_user_facing() {
        XCTAssertEqual(IslandCaseAccessPanel.message(for: CaseViewModelError.authenticationFailed),
                       "Touch ID not confirmed — nothing changed")
        XCTAssertEqual(IslandCaseAccessPanel.message(for: CaseViewModelError.invalidMinutes), "Use 1 to 240 minutes")
    }

    private func measuredWidth<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, .dark))
        return controller.sizeThatFits(in: CGSize(width: width, height: 2_000)).width
    }
}

private final class AccessStubStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    init(payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload { payload }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws { self.payload = payload }
    func reset() throws {}
}

private final class AccessStubKeys: CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}

private struct AccessStubAuthenticator: CaseAuthenticating {
    func authenticate(reason: String) async throws {}
}

private final class AccessStubPasteboard: CasePasteboardWriting {
    func writeString(_ value: String) {}
}

private final class AccessStubCancellable: CaseIdleLockCancellable {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}
