import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen renders of the unlocked Case panel (variant C). The window sits at
/// -20 000 pt and is never ordered front: no visible or key windows.
@MainActor
final class IslandCaseVaultPanelLayoutTests: XCTestCase {
    private let serversID = UUID()
    private let terraID = UUID()

    func test_actual_case_height_exposes_several_keys_without_overflow() async throws {
        let height = IslandCaseVaultStyle.panelHeight
        XCTAssertEqual(IslandView.hoverPanelHeight(for: .caseVault, musicActive: false),
                       IslandDropModeControl.detachedPanelGap + height)
        for width in [CGFloat(310), CGFloat(390)] {
            let fixture = try await PanelFixture(payload: samplePayload(), width: width, height: height)
            defer { fixture.close() }
            fixture.viewModel.expandedProjectIDs.insert(serversID)
            fixture.settle()
            try fixture.saveImage("case-panel-\(Int(width))-320")
            XCTAssertFalse(fixture.isWindowVisible)
        }
    }

    func test_general_section_first_and_expanded() async throws {
        let fixture = try await PanelFixture(payload: samplePayload())
        defer { fixture.close() }
        let viewModel = fixture.viewModel

        let sections = viewModel.projectSections
        XCTAssertEqual(sections.map(\.name), ["General", "servers", "terra-hiring"],
                       "General first, then the other projects by name")
        XCTAssertEqual(sections.map(\.keyCount), [2, 2, 1])
        XCTAssertEqual(sections[0].secrets.map(\.displayName), ["OPENAI_API_KEY", "OPENROUTER_API_KEY"])

        XCTAssertTrue(IslandCaseVaultPanel.isExpanded(sections[0], expandedIDs: viewModel.expandedProjectIDs, isSearching: false),
                      "General is expanded by default")
        XCTAssertFalse(IslandCaseVaultPanel.isExpanded(sections[1], expandedIDs: viewModel.expandedProjectIDs, isSearching: false),
                       "Other projects start collapsed")
        XCTAssertEqual(IslandCaseAddKeyRow.title(projectName: "General"), "+ Key in General")

        try fixture.saveImage("case-panel-default")
        XCTAssertFalse(fixture.isWindowVisible)
    }

    func test_search_spans_every_project_and_expands_matches() async throws {
        let fixture = try await PanelFixture(payload: samplePayload())
        defer { fixture.close() }
        let viewModel = fixture.viewModel

        viewModel.query = "netcup"
        XCTAssertTrue(viewModel.isSearching)
        let sections = viewModel.projectSections
        XCTAssertEqual(sections.map(\.name), ["servers"])
        XCTAssertEqual(Set(sections[0].secrets.map(\.displayName)), ["NETCUP_IP", "NETCUP_PASSWORD"])
        XCTAssertEqual(sections[0].keyCount, 2)
        XCTAssertTrue(IslandCaseVaultPanel.isExpanded(sections[0], expandedIDs: viewModel.expandedProjectIDs, isSearching: true))
    }

    func test_project_search_renders_empty_and_populated_projects() async throws {
        for width in [CGFloat(310), CGFloat(390)] {
            let fixture = try await PanelFixture(payload: samplePayload(extraProjectName: "Новый проект"),
                                                 width: width, height: IslandCaseVaultStyle.panelHeight)
            defer { fixture.close() }
            for (query, name, expectedCount) in [("новый", "Новый проект", 0), ("servers", "servers", 2)] {
                fixture.viewModel.query = query
                fixture.settle()
                XCTAssertEqual(fixture.viewModel.projectSections.map(\.name), [name])
                XCTAssertEqual(fixture.viewModel.projectSections[0].secrets.count, expectedCount)
                try fixture.saveImage("case-project-search-\(expectedCount)-\(Int(width))")
            }
            XCTAssertFalse(fixture.isWindowVisible)
        }
    }

    func test_no_copy_all_control() throws {
        let identifiers = IslandCaseSecretRow.actions.map(\.accessibilityIdentifier)
            + IslandCaseProjectRow.actions(isGeneral: false).map(\.accessibilityIdentifier)
        XCTAssertFalse(identifiers.contains { $0.lowercased().contains("all") })

        let sources = try panelSources()
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(sources.contains("copyAll"))
        XCTAssertFalse(sources.localizedCaseInsensitiveContains("Copy all"))
        XCTAssertFalse(sources.localizedCaseInsensitiveContains("Скопировать все"))
    }

    func test_general_header_has_no_delete() {
        XCTAssertEqual(IslandCaseProjectRow.actions(isGeneral: true).map(\.accessibilityIdentifier),
                       ["case.project.edit"])
        XCTAssertEqual(IslandCaseProjectRow.actions(isGeneral: false).map(\.accessibilityIdentifier),
                       ["case.project.edit", "case.project.delete"])
        XCTAssertEqual(IslandCaseProjectRow.actions(isGeneral: false).map(\.systemImage), ["pencil", "trash"])
    }

    func test_secret_row_has_edit_copy_delete_in_that_order() {
        XCTAssertEqual(IslandCaseSecretRow.actions.map(\.accessibilityIdentifier),
                       ["case.secret.edit", "case.secret.copy", "case.secret.delete"])
        XCTAssertEqual(IslandCaseSecretRow.actions.map(\.systemImage), ["pencil", "doc.on.doc", "trash"])
    }

    func test_project_delete_confirmation_names_project_and_key_count() {
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 8),
                       "Delete project servers and 8 keys?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 1),
                       "Delete project servers and 1 key?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 3),
                       "Delete project servers and 3 keys?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 0),
                       "Delete project servers and 0 keys?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 21),
                       "Delete project servers and 21 keys?")
    }

    func test_access_row_opens_the_access_screen() throws {
        XCTAssertTrue(IslandCaseVaultPanel.isAccessScreenAvailable)
        let sources = try panelSources()
        XCTAssertTrue(sources.contains("IslandCaseConnectedApps"))
        XCTAssertEqual(IslandCaseConnectedApps.brandAsset(for: CaseKnownClient.claudeCode.identity), "claude-code")
        XCTAssertEqual(IslandCaseConnectedApps.brandAsset(for: CaseKnownClient.codex.identity), "codex")
    }

    func test_client_hover_uses_provider_colors() {
        XCTAssertEqual(IslandCaseConnectedApps.highlight(for: CaseKnownClient.codex.identity), .blue)
        XCTAssertEqual(IslandCaseConnectedApps.highlight(for: CaseKnownClient.claudeCode.identity), .orange)
        XCTAssertEqual(IslandCaseConnectedApps.highlight(for: CaseKnownClient.cursor.identity), .neutral)
    }

    func test_renders_at_310pt_without_horizontal_overflow() async throws {
        let width: CGFloat = 310
        // Control: the measurement does report a row that cannot fit.
        XCTAssertGreaterThan(measuredWidth(HStack(spacing: 0) { Color.red.frame(width: 400, height: 10) }, width: width), width)

        let longProject = String(repeating: "p", count: CaseProject.maxNameCharacters)
        let longKey = "K" + String(repeating: "_LONG", count: 12) + "_NAME"
        let longDescription = String(repeating: "очень длинное описание ", count: 6)
        let general = CaseProjectSection(id: CaseProject.generalID, name: "General", description: "", keyCount: 120, secrets: [])
        let long = CaseProjectSection(id: UUID(), name: longProject, description: longDescription, keyCount: 999, secrets: [])
        let secretRow = CaseDisplayRow(id: UUID(), kind: .secret, displayName: longKey, description: longDescription, projectID: long.id)

        let candidates: [(String, AnyView)] = [
            ("general header", AnyView(IslandCaseProjectRow(section: general, isExpanded: true, isDropTargeted: false,
                                                            onToggle: {}, onEdit: {}, onDelete: {}))),
            ("long header", AnyView(IslandCaseProjectRow(section: long, isExpanded: false, isDropTargeted: true,
                                                         onToggle: {}, onEdit: {}, onDelete: {}))),
            ("secret row", AnyView(IslandCaseSecretRow(row: secretRow, onEdit: {}, onCopy: {}, onDelete: {}))),
            ("short value row", AnyView(IslandCaseSecretRow(
                row: CaseDisplayRow(id: UUID(), kind: .secret, displayName: longKey, description: longDescription,
                                    projectID: long.id, valueNotMasked: true),
                onEdit: {}, onCopy: {}, onDelete: {}))),
            ("add key row", AnyView(IslandCaseAddKeyRow(projectName: longProject, action: {}))),
            ("delete confirmation", AnyView(IslandCaseProjectDeleteConfirmation(name: longProject, keyCount: 999,
                                                                               onConfirm: {}, onCancel: {}))),
        ]
        for (name, view) in candidates {
            XCTAssertLessThanOrEqual(measuredWidth(view, width: width), width, "\(name) overflows \(width) pt")
        }

        let payload = samplePayload(extraProjectName: longProject, extraKeyName: longKey)
        let fixture = try await PanelFixture(payload: payload, width: width)
        defer { fixture.close() }
        fixture.viewModel.expandedProjectIDs.insert(serversID)
        fixture.settle()
        XCTAssertLessThanOrEqual(measuredWidth(IslandCaseVaultPanel(viewModel: fixture.viewModel), width: width), width)
        try fixture.saveImage("case-panel-310-long")
        XCTAssertFalse(fixture.isWindowVisible)
    }

    // MARK: - Adding a key: "+ Key" is the first row of a project

    func test_add_key_row_stands_above_the_keys_of_its_project() throws {
        let source = try panelSources()
        let expanded = try XCTUnwrap(source.range(of: "if isExpanded {"))
        let body = source[expanded.upperBound...]
        let addRow = try XCTUnwrap(body.range(of: "IslandCaseAddKeyRow(projectName: section.name)"))
        let keys = try XCTUnwrap(body.range(of: "ForEach(section.secrets)"))
        XCTAssertLessThan(addRow.lowerBound, keys.lowerBound, "+ Key comes before the project's keys")
        XCTAssertEqual(source.components(separatedBy: "IslandCaseAddKeyRow(projectName:").count - 1, 1,
                       "one + Key row per project")
    }

    func test_hundred_key_project_shows_add_key_and_the_saved_key_without_scrolling() async throws {
        let fixture = try await PanelFixture(payload: bigProjectPayload(keyCount: 120), width: 310,
                                             height: IslandCaseVaultStyle.panelHeight)
        defer { fixture.close() }
        let viewModel = fixture.viewModel
        viewModel.expandedProjectIDs = [serversID]
        fixture.settle()
        try fixture.saveImage("case-add-key-top-120")

        // A name that sorts last used to land a hundred rows below the form.
        try viewModel.submitName("ZZZ_LAST_KEY", projectID: serversID)
        XCTAssertNil(viewModel.lastAddedSecretID, "nothing is saved until the value is entered")
        try viewModel.submitValue("fixture-value")
        var section = try XCTUnwrap(viewModel.projectSections.first { $0.id == serversID })
        XCTAssertEqual(section.keyCount, 121)
        XCTAssertEqual(section.secrets.prefix(3).map(\.displayName), ["ZZZ_LAST_KEY", "KEY_000", "KEY_001"],
                       "the saved key is first, right under + Key; the rest stay by name")
        XCTAssertEqual(viewModel.lastAddedSecretID, section.secrets.first?.id)
        fixture.settle()
        try fixture.saveImage("case-add-key-saved-120")

        // The next saved key takes that place; the previous one returns to its place by name.
        try viewModel.submitName("MMM_MIDDLE_KEY", projectID: serversID)
        try viewModel.submitValue("fixture-value")
        section = try XCTUnwrap(viewModel.projectSections.first { $0.id == serversID })
        XCTAssertEqual(section.secrets.first?.displayName, "MMM_MIDDLE_KEY")
        XCTAssertEqual(section.secrets.last?.displayName, "ZZZ_LAST_KEY")
        XCTAssertEqual(section.secrets.dropFirst().map(\.displayName),
                       section.secrets.dropFirst().map(\.displayName)
                           .sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        // Other projects keep their order, and the names an agent sees are unchanged.
        XCTAssertEqual(viewModel.projectSections[0].secrets.map(\.displayName), ["OPENAI_API_KEY", "OPENROUTER_API_KEY"])
        XCTAssertFalse(fixture.isWindowVisible)
    }

    func test_saved_key_returns_to_its_place_by_name_after_case_locks() async throws {
        let fixture = try await PanelFixture(payload: bigProjectPayload(keyCount: 120))
        defer { fixture.close() }
        let viewModel = fixture.viewModel
        try viewModel.submitName("ZZZ_LAST_KEY", projectID: serversID)
        try viewModel.submitValue("fixture-value")
        XCTAssertNotNil(viewModel.lastAddedSecretID)

        viewModel.lock()
        XCTAssertNil(viewModel.lastAddedSecretID)
        try await viewModel.unlock()
        let section = try XCTUnwrap(viewModel.projectSections.first { $0.id == serversID })
        XCTAssertEqual(section.secrets.first?.displayName, "KEY_000")
        XCTAssertEqual(section.secrets.last?.displayName, "ZZZ_LAST_KEY")
    }

    func test_editing_and_moving_keys_work_after_an_add() async throws {
        let fixture = try await PanelFixture(payload: bigProjectPayload(keyCount: 120))
        defer { fixture.close() }
        let viewModel = fixture.viewModel
        try viewModel.submitName("ZZZ_LAST_KEY", projectID: serversID)
        try viewModel.submitValue("fixture-value")
        let saved = try XCTUnwrap(viewModel.lastAddedSecretID)

        try viewModel.renameSecret(saved, rawName: "ZZZ_RENAMED")
        try viewModel.setSecretDescription(saved, "note")
        XCTAssertEqual(viewModel.projectSections.first { $0.id == serversID }?.secrets.first?.displayName, "ZZZ_RENAMED")

        // Dragging it to another project keeps it in view there too.
        try viewModel.moveSecret(saved, toProject: terraID)
        XCTAssertEqual(viewModel.projectSections.first { $0.id == terraID }?.secrets.map(\.displayName),
                       ["ZZZ_RENAMED", "POSTGRES_PASSWORD"])
        XCTAssertEqual(viewModel.projectSections.first { $0.id == serversID }?.secrets.first?.displayName, "KEY_000")

        try viewModel.deleteSecret(saved)
        XCTAssertEqual(viewModel.projectSections.first { $0.id == terraID }?.secrets.map(\.displayName), ["POSTGRES_PASSWORD"])
    }

    func test_empty_project_offers_add_key_and_shows_its_first_key() async throws {
        let emptyID = UUID()
        var payload = samplePayload()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        payload.projects.append(CaseProject(id: emptyID, name: "empty", description: "", createdAt: date, updatedAt: date))
        let fixture = try await PanelFixture(payload: payload, width: 310, height: IslandCaseVaultStyle.panelHeight)
        defer { fixture.close() }
        let viewModel = fixture.viewModel
        viewModel.expandedProjectIDs = [emptyID]
        fixture.settle()
        XCTAssertEqual(viewModel.projectSections.first { $0.id == emptyID }?.secrets, [])
        try fixture.saveImage("case-add-key-empty-project")

        try viewModel.submitName("FIRST_KEY", projectID: emptyID)
        try viewModel.submitValue("fixture-value")
        fixture.settle()
        let section = try XCTUnwrap(viewModel.projectSections.first { $0.id == emptyID })
        XCTAssertEqual(section.secrets.map(\.displayName), ["FIRST_KEY"])
        XCTAssertEqual(viewModel.lastAddedSecretID, section.secrets.first?.id)
        try fixture.saveImage("case-add-key-empty-project-saved")
        XCTAssertFalse(fixture.isWindowVisible)
    }

    func test_cancelled_add_saves_nothing_and_keeps_the_order() async throws {
        let fixture = try await PanelFixture(payload: bigProjectPayload(keyCount: 120), width: 310,
                                             height: IslandCaseVaultStyle.panelHeight)
        defer { fixture.close() }
        let viewModel = fixture.viewModel
        viewModel.expandedProjectIDs.insert(serversID)
        fixture.settle()
        let before = viewModel.projectSections

        try viewModel.submitName("ZZZ_NEVER_SAVED", projectID: serversID)
        viewModel.cancelInput()
        fixture.settle()

        XCTAssertEqual(viewModel.inputMode, .name)
        XCTAssertNil(viewModel.lastAddedSecretID)
        XCTAssertEqual(viewModel.projectSections, before)
        XCTAssertThrowsError(try viewModel.submitValue("fixture-value"), "a cancelled name cannot take a value")
        XCTAssertThrowsError(try viewModel.submitName("", projectID: serversID), "an empty name is refused")
        XCTAssertNil(viewModel.lastAddedSecretID)
        XCTAssertEqual(viewModel.projectSections, before)
    }

    func test_add_during_search_leaves_search_and_shows_the_saved_key_first() async throws {
        var payload = bigProjectPayload(keyCount: 119)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stripe = secret("STRIPE_WEBHOOK", serversID, date)
        payload.secrets.append(stripe)
        payload.values.append(CaseSecretValue(secretID: stripe.id, value: "fixture"))
        let fixture = try await PanelFixture(payload: payload, width: 310, height: IslandCaseVaultStyle.panelHeight)
        defer { fixture.close() }
        let viewModel = fixture.viewModel

        // Key-only match: the project shows just the matching key, with + Key above it.
        viewModel.query = "stripe"
        fixture.settle()
        XCTAssertEqual(viewModel.projectSections.map(\.id), [serversID])
        XCTAssertEqual(viewModel.projectSections[0].secrets.map(\.displayName), ["STRIPE_WEBHOOK"])
        XCTAssertTrue(IslandCaseVaultPanel.isExpanded(viewModel.projectSections[0], expandedIDs: [], isSearching: true))
        try fixture.saveImage("case-add-key-search")

        // What + Key does in the panel: open the project, then leave search.
        viewModel.expandedProjectIDs = [serversID]
        viewModel.cancelInput()
        try viewModel.submitName("ZZZ_NOT_MATCHING_THE_QUERY", projectID: serversID)
        try viewModel.submitValue("fixture-value")
        fixture.settle()

        XCTAssertFalse(viewModel.isSearching)
        var section = try XCTUnwrap(viewModel.projectSections.first { $0.id == serversID })
        XCTAssertEqual(section.secrets.count, 121, "the full project is back, new key included")
        XCTAssertEqual(section.secrets.first?.displayName, "ZZZ_NOT_MATCHING_THE_QUERY")
        try fixture.saveImage("case-add-key-search-saved")

        // A value saved while a query is still typed also ends the search.
        viewModel.query = "stripe"
        try viewModel.submitName("YYY_ALSO_NOT_MATCHING", projectID: serversID)
        try viewModel.submitValue("fixture-value")
        XCTAssertFalse(viewModel.isSearching)
        section = try XCTUnwrap(viewModel.projectSections.first { $0.id == serversID })
        XCTAssertEqual(section.secrets.first?.displayName, "YYY_ALSO_NOT_MATCHING")

        // A later search still ranks by the query: matching keys first.
        viewModel.query = "stripe"
        XCTAssertEqual(viewModel.projectSections[0].secrets.map(\.displayName), ["STRIPE_WEBHOOK"])
        viewModel.query = "servers"
        XCTAssertEqual(viewModel.projectSections[0].secrets.first?.displayName, "YYY_ALSO_NOT_MATCHING",
                       "a project match lists every key, the saved one first")
    }

    func test_lock_forgets_the_last_added_key() async throws {
        let fixture = try await PanelFixture(payload: samplePayload())
        defer { fixture.close() }
        try fixture.viewModel.submitName("NEW_KEY")
        try fixture.viewModel.submitValue("fixture-value")
        XCTAssertNotNil(fixture.viewModel.lastAddedSecretID)
        fixture.viewModel.lock()
        XCTAssertNil(fixture.viewModel.lastAddedSecretID)
    }

    /// `servers` with `keyCount` keys named KEY_000…, plus General and terra-hiring.
    private func bigProjectPayload(keyCount: Int) -> CaseVaultPayload {
        var payload = samplePayload()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        payload.secrets.removeAll { $0.projectID == serversID }
        payload.secrets += (0..<keyCount).map { secret(String(format: "KEY_%03d", $0), serversID, date) }
        payload.values = payload.secrets.map { CaseSecretValue(secretID: $0.id, value: "fixture") }
        return payload
    }

    private func measuredWidth<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, .dark))
        return controller.sizeThatFits(in: CGSize(width: width, height: 2_000)).width
    }

    // MARK: - Fixtures

    private func samplePayload(extraProjectName: String? = nil, extraKeyName: String? = nil) -> CaseVaultPayload {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var projects = [
            CaseProject.general(now: date),
            CaseProject(id: terraID, name: "terra-hiring", description: "", createdAt: date, updatedAt: date),
            CaseProject(id: serversID, name: "servers", description: "Netcup и VPN", createdAt: date, updatedAt: date),
        ]
        var secrets = [
            secret("OPENAI_API_KEY", CaseProject.generalID, date, description: "Личный ключ"),
            secret("OPENROUTER_API_KEY", CaseProject.generalID, date),
            secret("NETCUP_IP", serversID, date),
            secret("NETCUP_PASSWORD", serversID, date),
            secret("POSTGRES_PASSWORD", terraID, date),
        ]
        if let extraProjectName {
            projects.append(CaseProject(id: UUID(), name: extraProjectName, description: "", createdAt: date, updatedAt: date))
        }
        if let extraKeyName {
            secrets.append(secret(extraKeyName, serversID, date,
                                  description: String(repeating: "очень длинное описание ", count: 6)))
        }
        return CaseVaultPayload(
            projects: projects,
            secrets: secrets,
            values: secrets.map { CaseSecretValue(secretID: $0.id, value: "fixture") },
            apps: [CaseKnownClient.claudeCode, .codex].map {
                CaseAppRegistration(id: UUID(), displayName: $0.displayName, identity: $0.identity,
                                    defaultMode: .approve, projectModes: [:], createdAt: date)
            }
        )
    }

    private func secret(_ name: String, _ projectID: UUID, _ date: Date, description: String = "") -> CaseSecret {
        CaseSecret(id: UUID(), name: name, projectID: projectID, description: description,
                   copyCount: 0, lastCopiedAt: nil, createdAt: date, updatedAt: date)
    }

    private func panelSources() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let directory = url.appendingPathComponent("Sources/Sidekey/DynamicIsland")
        return try ["IslandCaseVaultPanel.swift", "IslandCaseProjectRow.swift", "IslandCaseSecretRow.swift"]
            .map { name -> String in
                let file = directory.appendingPathComponent(name)
                return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            }
            .joined(separator: "\n")
    }
}

@MainActor
private final class PanelFixture {
    let viewModel: CaseViewModel
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private let service: CaseVaultService

    init(payload: CaseVaultPayload, width: CGFloat = 310, height: CGFloat = 480) async throws {
        _ = NSApplication.shared
        var sourceRoot = URL(fileURLWithPath: #filePath)
        while sourceRoot.path != "/", !FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Package.swift").path) {
            sourceRoot.deleteLastPathComponent()
        }
        ProviderBrandIconAsset.setResourceDirectoryForTesting(sourceRoot.appendingPathComponent("Resources/UsefulLinkIcons"))
        service = CaseVaultService(store: LayoutStubStore(payload: payload), keyProvider: LayoutStubKeys())
        viewModel = CaseViewModel(
            service: service,
            authenticator: LayoutStubAuthenticator(),
            pasteboard: LayoutStubPasteboard(),
            scheduleIdleLock: { _, _ in LayoutStubCancellable() }
        )
        try await viewModel.unlock()

        window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let modelForRendering = viewModel
        host = NSHostingView(rootView: AnyView(
            IslandCaseVaultPanel(viewModel: modelForRendering)
                .frame(width: width, height: height)
                .background(Color(white: 0.08))
                .environment(\.colorScheme, .dark)
        ))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        settle()
    }

    var isWindowVisible: Bool { window.isVisible || window.isKeyWindow }

    func settle(_ seconds: TimeInterval = 0.15) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        host.layoutSubtreeIfNeeded()
    }

    func saveImage(_ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_CASE_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() {
        window.contentView = nil
        window.close()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        ProviderBrandIconAsset.clearCacheForTesting()
    }
}

private final class LayoutStubStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    init(payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload { payload }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws { self.payload = payload }
    func reset() throws {}
}

private final class LayoutStubKeys: CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}

private struct LayoutStubAuthenticator: CaseAuthenticating {
    func authenticate(reason: String) async throws {}
}

private final class LayoutStubPasteboard: CasePasteboardWriting {
    func writeString(_ value: String) {}
}

private final class LayoutStubCancellable: CaseIdleLockCancellable {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}
