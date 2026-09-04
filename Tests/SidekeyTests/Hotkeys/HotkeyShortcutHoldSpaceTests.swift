import Carbon.HIToolbox
import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class HotkeyShortcutHoldSpaceTests: XCTestCase {
    // MARK: - Keycap rendering

    func testHoldSpaceRendersSingleSpaceTextKeycap() {
        XCTAssertEqual(HotkeyShortcut.holdSpace.contents, [.text("Space")])
    }

    func testHoldSpaceKeycapSpeaksAsSpaceBarForVoiceOver() {
        XCTAssertEqual(HotkeyShortcut.holdSpace.contents.first?.spokenName, "Space bar")
    }

    func testHoldSpaceTitleAndChipTitles() {
        XCTAssertEqual(HotkeyShortcut.holdSpace.title, "Space")
        XCTAssertEqual(HotkeyShortcut.holdSpace.shortcutChipTitles, ["Space"])
    }

    func testHoldSpaceCompactTokenIsSpace() {
        XCTAssertEqual(HotkeyShortcut.holdSpace.compactToken, "Space")
    }

    // MARK: - Not a combo / not a modifier

    func testHoldSpaceIsNeitherComboNorModifier() {
        XCTAssertNil(HotkeyShortcut.holdSpace.combo)
        XCTAssertNil(HotkeyShortcut.holdSpace.modifierKey)
    }

    func testHoldSpaceBindingKeyIsDistinctFromComboAndModifier() {
        let binding = HotkeyShortcut.holdSpace.bindingKey
        XCTAssertNotEqual(binding, .combo(.optionSpace))
        XCTAssertNotEqual(binding, .modifier(.rightCommand))
        XCTAssertNotEqual(binding, .modifier(.rightOption))
        // Two holdSpace bindings must compare equal so conflict-grouping
        // treats them as the same key.
        XCTAssertEqual(HotkeyShortcut.holdSpace.bindingKey, HotkeyShortcut.holdSpace.bindingKey)
    }

    // MARK: - RawRepresentable round-trip

    func testHoldSpaceRawRepresentableRoundTrip() {
        let raw = HotkeyShortcut.holdSpace.rawValue
        XCTAssertEqual(HotkeyShortcut(rawValue: raw), .holdSpace)
    }

    func testHoldSpaceRawValueDoesNotCollideWithComboOrModifier() {
        let raw = HotkeyShortcut.holdSpace.rawValue
        XCTAssertNil(HotkeyModifierKey(rawValue: raw))
        XCTAssertNil(HotkeyTapCombo(rawValue: raw))
    }

    // MARK: - Codable round-trip

    func testHoldSpaceCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyShortcut.holdSpace)
        let decoded = try JSONDecoder().decode(HotkeyShortcut.self, from: data)
        XCTAssertEqual(decoded, .holdSpace)
    }

    // MARK: - Existing serialization must not break

    func testExistingComboRawRepresentableRoundTripStillWorks() {
        let combo = HotkeyShortcut.combo(.optionSlash)
        XCTAssertEqual(HotkeyShortcut(rawValue: combo.rawValue), combo)
    }

    func testExistingModifierRawRepresentableRoundTripStillWorks() {
        let modifier = HotkeyShortcut.modifier(.rightCommand)
        XCTAssertEqual(HotkeyShortcut(rawValue: modifier.rawValue), modifier)
    }

    func testExistingComboCodableRoundTripStillWorks() throws {
        let combo = HotkeyShortcut.combo(.optionSlash)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(HotkeyShortcut.self, from: data)
        XCTAssertEqual(decoded, combo)
    }

    func testExistingModifierCodableRoundTripStillWorks() throws {
        let modifier = HotkeyShortcut.modifier(.rightCommand)
        let data = try JSONEncoder().encode(modifier)
        let decoded = try JSONDecoder().decode(HotkeyShortcut.self, from: data)
        XCTAssertEqual(decoded, modifier)
    }

    // MARK: - holdSpace resolves to no tap-combo without recursion/crash

    func testHoldSpaceConfigurationHasNoTapComboWithoutCrash() {
        var configuration = HotkeyConfiguration.defaults
        configuration.dropVoiceShortcut = .holdSpace
        XCTAssertNil(configuration.dropVoiceTapComboIfPresent)
    }
}
