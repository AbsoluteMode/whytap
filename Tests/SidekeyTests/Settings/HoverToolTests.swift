// Tests/SidekeyTests/Settings/HoverToolTests.swift
import XCTest
@testable import Sidekey

final class HoverToolTests: XCTestCase {

    func test_every_tool_has_registry_info() {
        for tool in HoverTool.allCases {
            let info = HoverToolRegistry.info(for: tool)
            XCTAssertFalse(info.title.isEmpty, "Tool \(tool) has empty title")
            XCTAssertFalse(info.sfSymbol.isEmpty, "Tool \(tool) has empty sfSymbol")
            XCTAssertFalse(info.description.isEmpty, "Tool \(tool) has empty description")
        }
    }

    func test_navigate_tools_have_expected_destinations() {
        if case .navigate(let dest) = HoverToolRegistry.info(for: .hotkeys).kind {
            if case .tab(let tab) = dest { XCTAssertEqual(tab, .hotkeys) }
            else { XCTFail("hotkeys should navigate to .tab(.hotkeys)") }
        } else { XCTFail("hotkeys should be .navigate") }

        if case .navigate(let dest) = HoverToolRegistry.info(for: .notes).kind {
            if case .tab(let tab) = dest { XCTAssertEqual(tab, .notes) }
            else { XCTFail("notes should navigate to .tab(.notes)") }
        } else { XCTFail("notes should be .navigate") }

        if case .navigate(let dest) = HoverToolRegistry.info(for: .quit).kind {
            if case .quitRow = dest { /* pass */ }
            else { XCTFail("quit should navigate to .quitRow") }
        } else { XCTFail("quit should be .navigate") }
    }

    func test_settings_is_action_kind() {
        if case .action = HoverToolRegistry.info(for: .settings).kind { /* pass */ }
        else { XCTFail("settings should be .action") }
    }

    func test_clipboard_tool_is_displayed_as_history_inline_panel() {
        let info = HoverToolRegistry.info(for: .clipboard)

        XCTAssertEqual(info.title, "History")
        XCTAssertEqual(info.description, "Open unified history")
        if case .inlinePanel = info.kind { /* pass */ }
        else { XCTFail("clipboard raw tool should now open the History inline panel") }
    }

    func test_rawValues_are_stable() {
        XCTAssertEqual(HoverTool.dropMode.rawValue, "dropMode")
        XCTAssertEqual(HoverTool.clipboard.rawValue, "clipboard")
        XCTAssertEqual(HoverTool.caseVault.rawValue, "caseVault")
        XCTAssertEqual(HoverTool.settings.rawValue, "settings")
    }

    func test_twelve_tools_total() {
        XCTAssertEqual(HoverTool.allCases.count, 12)
    }

    func test_output_language_description_mentions_smart_mode() {
        let description = HoverToolRegistry.info(for: .outputLang).description

        XCTAssertTrue(description.contains("Smart Mode"))
    }

    func test_drop_mode_description_mentions_output_language_when_smartTranslationIsActive() throws {
        let input = try XCTUnwrap(AppLanguage.find(code: "ru"))
        let output = try XCTUnwrap(AppLanguage.find(code: "en"))

        let description = HoverToolRegistry.description(
            for: .dropMode,
            mode: .smart,
            inputLanguage: input,
            outputLanguage: output
        )

        XCTAssertTrue(description.contains("Smart Mode"))
        XCTAssertTrue(description.contains("Output Language"))
        XCTAssertTrue(description.contains(output.displayName))
    }

    func test_drop_mode_description_omits_output_language_when_fastOrSameAsInput() throws {
        let input = try XCTUnwrap(AppLanguage.find(code: "en"))
        let output = try XCTUnwrap(AppLanguage.find(code: "en"))
        let base = HoverToolRegistry.info(for: .dropMode).description

        XCTAssertEqual(
            HoverToolRegistry.description(
                for: .dropMode,
                mode: .fast,
                inputLanguage: input,
                outputLanguage: try XCTUnwrap(AppLanguage.find(code: "ru"))
            ),
            base
        )
        XCTAssertEqual(
            HoverToolRegistry.description(
                for: .dropMode,
                mode: .smart,
                inputLanguage: input,
                outputLanguage: output
            ),
            base
        )
    }
}
