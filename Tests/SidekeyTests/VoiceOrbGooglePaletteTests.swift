import XCTest
@testable import Sidekey

final class VoiceOrbGooglePaletteTests: XCTestCase {
    func testGoogleVoiceModeUsesGooglePalette() {
        let flavor = VoiceOrbView.paletteFlavor(for: .googleVoice, isDarkBackground: true)
        XCTAssertEqual(flavor, .google)
    }

    func testGoogleVoiceModeIsActiveOrb() {
        XCTAssertEqual(VoiceOrbView.composition(for: .googleVoice), .activeOrb)
    }
}
