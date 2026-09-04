import XCTest
@testable import Sidekey

/// RU localization of the SuperAssistant helper-tile gallery.
///
/// Founder-reported bug: on the RU onboarding the headline/subtitle were
/// Russian while the whole tile grid rendered in English, because cards
/// pulled strings straight from `HoverToolRegistry`. The registry stays
/// the single English source for the live hover panel and the Toolbox tab;
/// localization lives ONLY in the onboarding copy layer
/// (`OnboardingSuperAssistantCopy.toolTile(for:)`), with a fail-safe
/// fallback to the registry for anything unmapped.
final class OnboardingSuperAssistantCopyTests: XCTestCase {

    // MARK: - RU tiles

    func test_ruLocalizesEveryShowcasedTile() {
        let copy = OnboardingSuperAssistantCopyRU()
        for tool in OnboardingSuperAssistantScreen.showcase {
            XCTAssertNotNil(
                copy.toolTile(for: tool),
                "\(tool) is showcased on the RU screen but has no RU tile copy — it would silently render in English"
            )
        }
    }

    func test_ruTileTitlesAndDescriptions() {
        let copy = OnboardingSuperAssistantCopyRU()
        let expected: [HoverTool: (title: String, description: String)] = [
            .dropMode: ("Режим Drop", "Переключение между Fast- и Smart-транскрипцией"),
            .clipboard: ("История", "Единая история записей"),
            .vocab: ("Словарь", "Свой словарь и термины"),
            .caseVault: ("Сниппеты", "Хранение и вставка готовых фрагментов"),
            .filler: ("Фразы", "Быстрая вставка частых фраз"),
            .inputLang: ("Язык ввода", "Язык распознавания речи"),
            .outputLang: ("Язык вывода", "Язык перевода в Smart-режиме")
        ]
        XCTAssertEqual(
            Set(expected.keys), Set(OnboardingSuperAssistantScreen.showcase),
            "expectations must cover exactly the showcased tools"
        )
        for (tool, want) in expected {
            let tile = copy.toolTile(for: tool)
            XCTAssertEqual(tile?.title, want.title, "\(tool) RU title")
            XCTAssertEqual(tile?.description, want.description, "\(tool) RU description")
        }
    }

    // MARK: - EN keeps the registry as the single source

    func test_enResolvesToRegistryStringsVerbatim() {
        let copy = OnboardingSuperAssistantCopyEN()
        for tool in OnboardingSuperAssistantScreen.showcase {
            XCTAssertNil(
                copy.toolTile(for: tool),
                "EN must not duplicate registry copy for \(tool) — the registry IS the English copy"
            )
            let strings = OnboardingSuperAssistantScreen.tileStrings(for: tool, copy: copy)
            let info = HoverToolRegistry.info(for: tool)
            XCTAssertEqual(strings.title, info.title, "\(tool) EN title comes from the registry")
            XCTAssertEqual(strings.description, info.description, "\(tool) EN description comes from the registry")
        }
    }

    // MARK: - Fail-safe: unmapped tool falls back to registry (EN)

    func test_unmappedToolFallsBackToRegistryInRU() {
        let copy = OnboardingSuperAssistantCopyRU()
        for tool in [HoverTool.hotkeys, .notes, .meetingRecord, .quit, .settings] {
            XCTAssertNil(copy.toolTile(for: tool), "\(tool) is not showcased and must stay unmapped")
            let strings = OnboardingSuperAssistantScreen.tileStrings(for: tool, copy: copy)
            let info = HoverToolRegistry.info(for: tool)
            XCTAssertEqual(strings.title, info.title, "\(tool) falls back to the registry title")
            XCTAssertEqual(strings.description, info.description, "\(tool) falls back to the registry description")
        }
    }

    // MARK: - Screen renders through the resolver (regression guard)

    func test_helperCardRendersResolvedStringsNotRawRegistry() throws {
        let s = try screenSource()
        XCTAssertTrue(
            s.contains("tileStrings(for: tool, copy: copy)"),
            "cards must resolve title/description through the localized resolver"
        )
        XCTAssertFalse(s.contains("Text(info.title)"), "raw registry title must not be rendered directly")
        XCTAssertFalse(s.contains("Text(info.description)"), "raw registry description must not be rendered directly")
    }

    private func screenSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/Onboarding/OnboardingSuperAssistantScreen.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
