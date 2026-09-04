import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class KeycapViewTests: XCTestCase {
    func testInitStoresLabel() {
        let view = KeycapView(label: "Q")

        // `label` is now optional because symbol-content caps have no
        // text label — back-compat init still routes "Q" through the
        // `.text(...)` content case which projects back to "Q".
        XCTAssertEqual(view.label, Optional("Q"))
        // Text content path: the public `content` projection round-trips
        // through `.text(...)` so future migrations to the heterogeneous
        // `KeycapContent` API don't silently drop the old String input.
        XCTAssertEqual(view.content, .text("Q"))
    }

    func testInitWithSymbolContent() {
        // SF Symbol caps are the path the Useful Links selection chip
        // uses for the chevron arrow keys (⌥ ←/→/↑/↓ hints). The
        // designated `KeycapContent`-based init carries the symbol
        // name plus an explicit VoiceOver label.
        let view = KeycapView(
            content: .symbol("chevron.left", accessibilityLabel: "Left arrow key")
        )

        // `.text`-only `label` projection stays nil for symbol caps —
        // no plain text to surface.
        XCTAssertNil(view.label)
        XCTAssertEqual(view.resolvedAccessibilityLabel, "Left arrow key")
    }

    func testSymbolContentFallsBackToSymbolNameKeyForVoiceOverWhenLabelOmitted() {
        // Defensive: caller omitted the spoken label. The cap reads
        // "<symbol-name> key" instead of going silent on screen
        // readers. Production callsites should always pass an
        // explicit label (see HotkeyGlyph.chevronLeft etc.).
        let view = KeycapView(content: .symbol("chevron.right", accessibilityLabel: nil))

        XCTAssertEqual(view.resolvedAccessibilityLabel, "chevron.right key")
    }

    func testAccessibilityLabelDefaultsToKeyKey() {
        // Bare-letter labels read as "<letter> key" so VoiceOver
        // announces e.g. "Q key" instead of just "Q" — the latter
        // is heard as the meaningless single-letter sound out of
        // context.
        let view = KeycapView(label: "Q")

        XCTAssertEqual(view.resolvedAccessibilityLabel, "Q key")
    }

    func testAccessibilityLabelFallbackForMultiCharLabel() {
        // The default `"<label> key"` fallback still works for
        // multi-character labels — but production hotkey hints
        // always route through `HotkeyHintView` + `HotkeyGlyph.spokenName`,
        // which spells modifier glyphs (⌥, ⌘) to "Option key" /
        // "Command key" via the `accessibilityLabel:` override.
        // The bare `KeycapView(label:)` path stays as a building
        // block default — exercised here so future regressions in
        // the fallback formatter surface immediately.
        XCTAssertEqual(KeycapView(label: "Esc").resolvedAccessibilityLabel, "Esc key")
        XCTAssertEqual(KeycapView(label: "Tab").resolvedAccessibilityLabel, "Tab key")
    }

    func testCustomAccessibilityLabelOverridesDefault() {
        // Production glyph caps (⌥, ⌘) pair the visible glyph with
        // an explicit spoken name so VoiceOver reads "Option key"
        // instead of the meaningless single-codepoint character
        // name. This is the path `HotkeyHintView` uses internally.
        let view = KeycapView(label: "⌥", accessibilityLabel: "Option key")

        XCTAssertEqual(view.resolvedAccessibilityLabel, "Option key")
    }

    func testRendersInsideHostingControllerWithoutCrashing() {
        // Smoke: making the view real in an NSHostingController must
        // not throw or assert. Anchors the SwiftUI body against
        // regression in monospaced font / material / overlay
        // resolution. This is a smoke test only — the visual layout
        // is verified by Maxim in the panel.
        let hosting = NSHostingController(rootView: KeycapView(label: "⌥"))

        XCTAssertNotNil(hosting.view)
    }

    func testCanonicalSizeIsTheSameSquareForTextAndSymbolCaps() {
        // Every cap (`[⌥]`, `[Q]`, `[H]`, `[/]`, `[‹]`, `[›]`, `[⌃]`,
        // `[⌄]`) renders as a fixed square so a row of mixed caps in a
        // single hint chip reads with identical cap rhythm regardless
        // of content type. Pin the constant so a future tweak trips
        // here before reaching production visual review.
        XCTAssertEqual(KeycapView.canonicalSize, 22)
    }

    func testSymbolCapRendersAtTheSameOuterSquareAsTextCap() {
        // The chevron arrow caps used by the useful_links selection
        // chip render as SF Symbol Images; without an explicit square
        // frame the Image would size to its natural ~9pt geometry and
        // look visibly smaller than a neighbouring letter cap. Both
        // smoke renders must succeed and use the same `canonicalSize`
        // — the size constant is the single source of truth for the
        // visual envelope.
        let textCap = NSHostingController(rootView: KeycapView(label: "Q"))
        let symbolCap = NSHostingController(
            rootView: KeycapView(content: .symbol("chevron.left", accessibilityLabel: "Left"))
        )

        XCTAssertNotNil(textCap.view)
        XCTAssertNotNil(symbolCap.view)
        // KeycapView's canonical square is the visible cap envelope —
        // every cap variant funnels through the same frame.
        XCTAssertEqual(KeycapView.canonicalSize, 22)
    }

    // MARK: - Tiny size tier (Hover-slot keycap-pair hints)
    //
    // The Dynamic Island hover-slot hints render about half the size of the
    // compact chip and with no outer capsule. The cap drops to a `.tiny` size
    // tier so the `[⌥][1]` pair of mini chips (`.chip` chrome, see below)
    // reads as a light positional mark above the tile.

    func testTinySizeIsRoughlyHalfOfCompact() {
        // The tiny envelope is ~half the compact cap so the user's "in two
        // halves smaller" reads literally. Pin the constant so a future tweak
        // trips here before reaching visual review.
        XCTAssertEqual(KeycapView.tinySize, 9)
        // Sanity: strictly smaller than compact (16) and roughly half of it.
        XCTAssertLessThan(KeycapView.tinySize, KeycapView.compactSize)
    }

    func testTinyKeycapRendersInsideHostingControllerWithoutCrashing() {
        // Smoke: the new tiny tier lays out for text, symbol, and prefixed
        // glyph content without throwing.
        let textCap = NSHostingController(rootView: KeycapView(label: "1", size: .tiny))
        let glyphCap = NSHostingController(
            rootView: KeycapView(label: HotkeyGlyph.option, accessibilityLabel: "Option key", size: .tiny)
        )
        let symbolCap = NSHostingController(
            rootView: KeycapView(content: .symbol("chevron.left", accessibilityLabel: "Left"), size: .tiny)
        )

        XCTAssertNotNil(textCap.view)
        XCTAssertNotNil(glyphCap.view)
        XCTAssertNotNil(symbolCap.view)
    }

    func testTinyCapPreservesAccessibilityLabel() {
        // Shrinking the cap must not drop VoiceOver: the spoken label still
        // resolves from the content / override exactly as the larger tiers do.
        let view = KeycapView(label: HotkeyGlyph.option, accessibilityLabel: "Option key", size: .tiny)
        XCTAssertEqual(view.resolvedAccessibilityLabel, "Option key")
    }

    func testCompactInitMapsToCompactSizeTier() {
        // Back-compat: the boolean `compact:` init is a thin shim over the
        // size enum so existing callsites keep their envelope.
        XCTAssertEqual(KeycapView(label: "Q", compact: true).size, .compact)
        XCTAssertEqual(KeycapView(label: "Q").size, .regular)
    }

    // MARK: - KeycapChrome (Hover-slot keycap-pair hints)

    func testTinyCapHidesChromeByDefault() {
        // `.tiny` renders as a bare glyph by default (light overline above the
        // tile). The chrome rule stays suppressed unless the caller forces
        // `.chip` explicitly.
        let cap = KeycapView(content: .text("1"), size: .tiny)
        XCTAssertFalse(cap.showsCapChrome)
    }

    func testTinyCapDrawsChromeWhenForced() {
        // The Hover-slot keycap-pair variant forces `.chip` chrome even at
        // `.tiny` so each glyph renders inside its own mini rounded cap.
        let cap = KeycapView(content: .text("1"), size: .tiny, chrome: .chip)
        XCTAssertTrue(cap.showsCapChrome)
    }

    func testRegularCapKeepsChromeRegardlessOfChromeMode() {
        // Regular caps always draw chrome — `.chip` is a no-op here.
        XCTAssertTrue(KeycapView(content: .text("Q"), size: .regular).showsCapChrome)
        XCTAssertTrue(KeycapView(content: .text("Q"), size: .regular, chrome: .chip).showsCapChrome)
    }
}
