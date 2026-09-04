import XCTest

final class ToolboxSettingsViewTests: XCTestCase {
    func test_toolboxShowsVisibleDescriptionForHoveredTools() throws {
        let source = try toolboxSettingsSource()

        XCTAssertTrue(source.contains("@State private var hoveredTool: HoverTool?"))
        XCTAssertTrue(source.contains("toolHoverDescription"))
        XCTAssertTrue(source.contains("toolDescription(for: tool)"))
        XCTAssertTrue(source.contains(".onHover { hovering in"))
        XCTAssertFalse(source.contains(".fill(Color.white.opacity(0.04))"))
    }

    func test_languagePickersMirrorSelectionLocallyBeforePersisting() throws {
        let source = try toolboxSettingsSource()

        XCTAssertTrue(source.contains("@State private var selectedInputLanguage: AppLanguage?"))
        XCTAssertTrue(source.contains("@State private var selectedOutputLanguage: AppLanguage?"))
        XCTAssertTrue(source.contains("_selectedInputLanguage = State(initialValue: deps.currentLanguage())"))
        XCTAssertTrue(source.contains("_selectedOutputLanguage = State(initialValue: deps.currentTargetLanguage())"))
        XCTAssertTrue(source.contains("selectedLanguage: selectedInputLanguage"))
        XCTAssertTrue(source.contains("selectedInputLanguage = language"))
        XCTAssertTrue(source.contains("deps.setLanguage(language)"))
        XCTAssertTrue(source.contains("selectedLanguage: selectedOutputLanguage"))
        XCTAssertTrue(source.contains("selectedOutputLanguage = language"))
        XCTAssertTrue(source.contains("deps.setTargetLanguage(language)"))
    }

    func test_toolDescriptionsUseSmartModeLanguageContext() throws {
        let source = try toolboxSettingsSource()

        XCTAssertTrue(source.contains("HoverToolRegistry.description("))
        XCTAssertTrue(source.contains("mode: dropMode"))
        XCTAssertTrue(source.contains("inputLanguage: selectedInputLanguage"))
        XCTAssertTrue(source.contains("outputLanguage: selectedOutputLanguage"))
    }

    func test_languageTilesShowSelectedLanguageBadgeOnButton() throws {
        let source = try toolboxSettingsSource()

        XCTAssertTrue(source.contains("badge: languageBadge(for: tool)"))
        XCTAssertTrue(source.contains("private func languageBadge(for tool: HoverTool) -> String?"))
        XCTAssertTrue(source.contains("IslandLanguageControl.languageCodeBadge(for: language)"))
        XCTAssertTrue(source.contains("let badge: String?"))
        XCTAssertTrue(source.contains("if let badge"))
    }

    func test_dropModeButtonIsNoOpWhenModeAlreadySelected() throws {
        // The button action must guard on the current mode before toggling.
        // Clicking the already-active mode button should be a no-op.
        let source = try toolboxSettingsSource()

        XCTAssertTrue(source.contains("guard deps.currentDropMode() != mode else { return }"),
            "dropModePane must guard on currentDropMode() != mode before toggling")
    }

    /// ROO-236: `.draggable(_:)` over a `Button` does not initiate a drag
    /// session on macOS 15 (Apple regression FB14518001). The catalog tiles
    /// carry `.draggable`, so the tile's tap must NOT be backed by a `Button`
    /// — otherwise catalog tools cannot be dragged onto hover slots on 15.x.
    func test_toolboxTileTapIsNotButtonBackedSoDraggableWorks() throws {
        let source = try toolboxSettingsSource()
        let tileBody = try toolboxTileViewBody(from: source)

        XCTAssertFalse(tileBody.contains("Button(action: onTap)"),
            "ToolboxTileView must not wrap its tap in a Button — .draggable over a Button does not initiate a drag on macOS 15 (ROO-236)")
        XCTAssertFalse(tileBody.contains("buttonStyle(.plain)"),
            "ToolboxTileView must not use buttonStyle(.plain) for the tile tap (ROO-236)")
        XCTAssertTrue(tileBody.contains(".onTapGesture"),
            "ToolboxTileView must route tap through .onTapGesture so it coexists with .draggable (ROO-236)")
        XCTAssertTrue(tileBody.contains(".contentShape(Rectangle())"),
            "ToolboxTileView must use .contentShape(Rectangle()) so the whole tile is tappable/draggable (ROO-236)")
    }

    /// Dropping the Button wrapper removes the implicit `.isButton` trait, so
    /// it must be re-added explicitly for VoiceOver (per accessibility-patterns).
    func test_toolboxTileKeepsButtonAccessibilityTrait() throws {
        let source = try toolboxSettingsSource()
        let tileBody = try toolboxTileViewBody(from: source)

        XCTAssertTrue(tileBody.contains(".accessibilityAddTraits(") && tileBody.contains(".isButton"),
            "ToolboxTileView must re-add the .isButton trait after dropping the Button wrapper (ROO-236)")
        XCTAssertTrue(tileBody.contains(".accessibilityLabel(title)"),
            "ToolboxTileView must keep its accessibility label")
    }

    /// Isolates the `ToolboxTileView` declaration so the Button-related
    /// assertions don't trip over unrelated `Button` usages elsewhere in the
    /// file (e.g. the drop-mode and clipboard panes).
    private func toolboxTileViewBody(from source: String) throws -> String {
        let range = try XCTUnwrap(source.range(of: "struct ToolboxTileView: View {"),
            "ToolboxTileView declaration not found")
        return String(source[range.lowerBound...])
    }

    private func toolboxSettingsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Settings")
            .appendingPathComponent("ToolboxSettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
