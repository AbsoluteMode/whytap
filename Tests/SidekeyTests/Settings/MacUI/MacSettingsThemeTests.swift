import XCTest
import SwiftUI
import AppKit
@testable import Sidekey

@MainActor
final class MacSettingsThemeTests: XCTestCase {
    func test_hexCSS_parses_accent_blue() throws {
        let ns = NSColor(Color(hexCSS: "#007aff")).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(ns.redComponent), 0.0, accuracy: 0.01)
        XCTAssertEqual(Double(ns.greenComponent), 0.478, accuracy: 0.01)
        XCTAssertEqual(Double(ns.blueComponent), 1.0, accuracy: 0.01)
    }

    func test_hexCSS_parses_shorthand_and_ignores_hash() throws {
        let a = NSColor(Color(hexCSS: "#fff")).usingColorSpace(.sRGB)!
        let b = NSColor(Color(hexCSS: "ffffff")).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(a.redComponent), 1.0, accuracy: 0.01)
        XCTAssertEqual(Double(b.blueComponent), 1.0, accuracy: 0.01)
    }

    func test_accent_token_matches_mockup() throws {
        let ns = NSColor(MacSettingsTheme.accent).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(ns.greenComponent), 0.478, accuracy: 0.01)
    }
}
