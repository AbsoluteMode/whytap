import XCTest
@testable import Sidekey

@MainActor
final class APIAndModelsViewTests: XCTestCase {
    private let files = [
        "APIAndModelsView.swift", "ModelMenu.swift", "KeyChipPopover.swift",
        "AddKeySheet.swift", "AssignModelsSheet.swift", "ProviderMenu.swift", "ModelPicker.swift", "ProviderKeyTiles.swift",
    ]

    func test_tab_uses_mac_components_and_verbatim_strings() throws {
        let s = try allSource()
        for token in ["MacCard", "MacRow", "MacGroupTitle", "MacBanner", "ProviderBrandIcon", "SecureField", "MacSwitch"] {
            XCTAssertTrue(s.contains(token), token)
        }
        for text in [
            "\"API keys\"", "\"Models\"", "\"Add key\"", "\"Replace key\"", "\"Remove\"", "\"Check now\"",
            "checked when picked", "\"Use\"", "\"Not now\"",
            "\"Show\"", "Not verified", "Removed by provider", "Key problem", "Not supported yet",
            "No features use this key.", "will have no model.", "http://localhost:8000/v1",
        ] {
            XCTAssertTrue(s.contains(text), text)
        }
    }

    func test_key_value_is_never_read_or_shown_in_a_plain_field() throws {
        let s = try allSource()
        XCTAssertFalse(s.contains("keys.read("))
        XCTAssertFalse(s.contains("lookup("))
        XCTAssertFalse(s.contains("TextField(\"API key"))
        XCTAssertFalse(s.contains("TextField(\"Key"))
    }

    func test_tab_has_a_single_model_menu_and_no_account_dropdown() throws {
        let view = try source("APIAndModelsView.swift")
        // One per-feature menu (Advanced), one shared menu (Speech/LLM rows)
        // and Subtitles' engine menu, all on the same model picker.
        XCTAssertEqual(view.components(separatedBy: "SharedModelMenu(").count - 1, 1)
        XCTAssertEqual(view.components(separatedBy: "SubtitlesModelMenu(").count - 1, 1)
        XCTAssertEqual(view.components(separatedBy: "ModelMenu(").count - 1, 3)
        XCTAssertTrue(view.contains("ScrollViewReader"))
        XCTAssertTrue(view.contains("focusedFeature"))
    }

    func test_provider_icons_come_from_one_helper() throws {
        let s = try allSource()
        XCTAssertEqual(s.components(separatedBy: "ProviderBrandIcon(").count - 1, 2,
                       "one asset call and one system-image fallback, both inside the helper")
        XCTAssertTrue(s.contains("ProviderKindIcon"))
    }

    /// A failed check or a runtime refusal can be checked again from the row
    /// (final review I1, I2).
    func test_not_supported_row_offers_check_now() throws {
        let view = try source("APIAndModelsView.swift")
        let start = try XCTUnwrap(view.range(of: "case .notSupported(let reason):"))
        let tail = view[start.upperBound...].prefix(260)
        XCTAssertTrue(tail.contains("title: \"Check now\""), String(tail))
        XCTAssertTrue(tail.contains("viewModel.checkNow(row.feature)"), String(tail))
    }

    private func source(_ file: String) throws -> String {
        let url = try projectRoot().appendingPathComponent("Sources/Sidekey/Settings/APIAndModels/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func allSource() throws -> String {
        try files.map(source).joined(separator: "\n")
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "APIAndModelsViewTests", code: 1)
    }
}
