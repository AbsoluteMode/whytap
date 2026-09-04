import SwiftUI

/// Outer size tier for a keycap. Three discrete steps so a cap's whole
/// geometry (square envelope, glyph font, corner radius) moves together
/// instead of callers tweaking each knob independently:
/// - `.regular` — the canonical 22pt cap used by the Help window rows and
///   the floating Keybindings hint.
/// - `.compact` — the 16pt cap used by the response-panel-internal chips
///   and the helper under the orb.
/// - `.tiny` — the ~half-of-compact 9pt cap used by the Dynamic Island
///   Hover-slot hints (⌥1..⌥5) sitting above each tile — each glyph in its
///   own mini chip (`KeycapChrome.chip`). With the default `.automatic`
///   chrome a tiny cap renders as a bare glyph instead.
enum KeycapSize {
    case regular
    case compact
    case tiny
}

/// Whether a cap draws its rounded-chip background+border.
/// `.automatic` — the existing rule (every tier except `.tiny` draws chrome;
/// `.tiny` renders bare glyphs for the light overline hints).
/// `.chip` — force the chip chrome even at `.tiny` (the Hover-slot keycap-pair
/// hints: each glyph in its own mini keycap, per docs/hotkey.md).
enum KeycapChrome: Equatable {
    case automatic
    case chip
}

/// Compact keycap-style label for a single keyboard key. Internal
/// building block of `HotkeyHintView`, which is the public composition
/// point for hotkey hints across Pill UI surfaces (response panel
/// close row), the floating keybindings hint, and the Help window.
///
/// Visual: small rounded rectangle (7pt corner radius), thin border,
/// monospaced label. Background uses `.regularMaterial` so the cap reads
/// against any underlying frosted-glass pill or solid panel without
/// custom tinting.
///
/// Sized for inline use next to a 28×28 close affordance: padded
/// content is ~6pt horizontal / 3pt vertical, with a 12pt minimum
/// label width so single-glyph caps (⌥, ⌘, Q, H, /) render visually
/// uniform regardless of which character lives inside.
struct KeycapView: View {
    /// What the cap renders. `.text` for plain glyphs/letters, `.symbol`
    /// for SF Symbol caps (used by chevron arrow keys so the macOS-native
    /// two-stroke "uголок" replaces the Unicode arrow glyph).
    let content: KeycapContent

    /// Overrides the default VoiceOver label. Pass when the visible
    /// glyph isn't its own readable name (e.g. `label: "⌥"` paired
    /// with `accessibilityLabel: "Option key"`).
    /// For `.symbol(_, accessibilityLabel:)` content the cap's spoken
    /// name already carries the label — this override is the existing
    /// `KeycapView(label:, accessibilityLabel:)` API's path.
    let customAccessibilityLabel: String?

    /// Outer size tier. `.regular` (22pt) is the canonical envelope every
    /// existing callsite gets by default; `.compact` (16pt) drives the
    /// response-panel-internal chips and the helper under the orb;
    /// `.tiny` (9pt) drives the Hover-slot keycap-pair hints.
    let size: KeycapSize

    /// Whether to force the rounded-chip background+border at `.tiny`. The
    /// default `.automatic` keeps the existing rule (`.tiny` = bare glyph).
    /// `.chip` forces the chip chrome so the Hover-slot keycap-pair hints
    /// render `[⌥][1]` as two distinct mini caps.
    let chrome: KeycapChrome

    /// Canonical outer size for every cap — text and SF Symbol both
    /// render inside this fixed square. Without it, a chevron `Image`
    /// would draw at its natural ~9pt size while a text cap renders at
    /// 11pt + padding, making the chevron cap visibly smaller next to
    /// a letter cap in the same chip. Square geometry also means a
    /// row of `[⌥][/]` / `[⌥][Q]` / `[⌥][›]` / `[⌥][⌃]` reads with
    /// identical cap rhythm regardless of content type.
    static let canonicalSize: CGFloat = 22
    /// Compact outer size used by response-panel-internal chips and
    /// the helper under the orb. 16pt keeps the cap glyphs legible at
    /// 10pt while halving the chip's total vertical envelope so the
    /// surrounding `HotkeyHintView` lands at the same intrinsic
    /// `KeycapView.compactSize + 2 × compactChipVerticalPadding = 18pt`
    /// height that `KeybindingsHintView.compactChipIntrinsicHeight`
    /// uses for its panel envelope.
    static let compactSize: CGFloat = 16
    /// Tiny outer size — ~half the compact cap. Used by the Dynamic Island
    /// Hover-slot hints (⌥1..⌥5) sitting above each tile — a `[⌥][N]` pair
    /// of mini keycap chips (`.chip` chrome). At this envelope the pair
    /// reads as a light positional mark above the button.
    static let tinySize: CGFloat = 9

    /// Corner radius — matches the OS keycap rendering on macOS shortcut
    /// surfaces (e.g. Spotlight / Menu Bar shortcut chips).
    private static let cornerRadius: CGFloat = 7
    /// Compact-mode corner radius — proportionally smaller so the cap
    /// reads as a tighter version of the canonical chip.
    private static let compactCornerRadius: CGFloat = 5
    /// Tiny corner radius — the radius of the Hover-slot hint's mini chips
    /// (`.chip` chrome at `.tiny`); kept tiny so the 9pt cap still reads as
    /// a rounded key. `.automatic` tiny caps draw no background at all.
    private static let tinyCornerRadius: CGFloat = 3
    /// Inline font size. 11pt sits comfortably alongside the 11pt
    /// `xmark` glyph in the response panel close row.
    private static let fontSize: CGFloat = 11
    /// Compact-mode font size — 10pt is the floor where modifier
    /// glyphs (⌥ ⌘) still render with their full keyboard glyph
    /// metadata; below that the macOS renderer collapses to a generic
    /// letterform that loses the modifier affordance.
    private static let compactFontSize: CGFloat = 10
    /// Tiny-mode font size — ~half of compact. At 7pt the modifier glyph
    /// still resolves its keyboard glyph (the renderer keeps the affordance
    /// down to small sizes), so it stays legible both as a bare `.automatic`
    /// glyph and inside the mini chip of the `.keycaps` Hover-slot hints.
    private static let tinyFontSize: CGFloat = 7

    /// Designated initialiser — caller picks `.text` or `.symbol`, the outer
    /// size tier, and optionally forces the chip chrome at `.tiny`.
    init(
        content: KeycapContent,
        accessibilityLabel: String? = nil,
        size: KeycapSize = .regular,
        chrome: KeycapChrome = .automatic
    ) {
        self.content = content
        self.customAccessibilityLabel = accessibilityLabel
        self.size = size
        self.chrome = chrome
    }

    /// Back-compat convenience: the boolean `compact:` flag maps onto the
    /// size enum (`true` → `.compact`, `false` → `.regular`) so existing
    /// callsites keep their envelope without naming the new tier.
    init(
        content: KeycapContent,
        accessibilityLabel: String? = nil,
        compact: Bool
    ) {
        self.init(
            content: content,
            accessibilityLabel: accessibilityLabel,
            size: compact ? .compact : .regular
        )
    }

    /// Back-compat convenience for the original `KeycapView(label:)` API.
    /// String label wraps as `.text(...)` so the designated init stays
    /// the single rendering path.
    init(label: String, accessibilityLabel: String? = nil, size: KeycapSize = .regular) {
        self.init(
            content: .text(label),
            accessibilityLabel: accessibilityLabel,
            size: size
        )
    }

    /// Back-compat convenience for `KeycapView(label:compact:)` callsites.
    init(label: String, accessibilityLabel: String? = nil, compact: Bool) {
        self.init(
            content: .text(label),
            accessibilityLabel: accessibilityLabel,
            size: compact ? .compact : .regular
        )
    }

    /// Visible text label, exposed for tests that pin the old API surface.
    /// `nil` for SF Symbol caps where there is no text to expose.
    var label: String? {
        if case .text(let value) = content { return value }
        return nil
    }

    /// VoiceOver label that this view will announce. Exposed for unit
    /// tests so the spelling can be asserted without spinning up an
    /// accessibility inspector.
    var resolvedAccessibilityLabel: String {
        if let customAccessibilityLabel {
            return customAccessibilityLabel
        }
        return content.spokenName
    }

    /// Glyph point size for the active tier.
    private var activeFontSize: CGFloat {
        switch size {
        case .regular: return Self.fontSize
        case .compact: return Self.compactFontSize
        case .tiny: return Self.tinyFontSize
        }
    }

    /// Word labels ("Space", "Tab", "Delete", "Home", F-keys…) render two
    /// points smaller than single-character caps so the longer text doesn't
    /// visually dominate the cap next to letter/glyph siblings. A single
    /// character (letter, digit, modifier glyph) keeps the canonical size.
    private func textFontSize(for value: String) -> CGFloat {
        value.count > 1 ? max(activeFontSize - 2, 1) : activeFontSize
    }

    /// Outer square edge for the active tier.
    private var activeSize: CGFloat {
        switch size {
        case .regular: return Self.canonicalSize
        case .compact: return Self.compactSize
        case .tiny: return Self.tinySize
        }
    }

    /// Cap corner radius for the active tier.
    private var activeCorner: CGFloat {
        switch size {
        case .regular: return Self.cornerRadius
        case .compact: return Self.compactCornerRadius
        case .tiny: return Self.tinyCornerRadius
        }
    }

    /// `.tiny` caps render as bare glyphs by default; `.chip` chrome forces the
    /// rounded cap even at `.tiny` (Hover-slot keycap-pair hints). The larger
    /// tiers always draw the keycap chrome.
    private var drawsCapChrome: Bool {
        chrome == .chip || size != .tiny
    }

    /// Exposed `internal` so unit tests pin the chrome rule without
    /// introspecting the rendered tree.
    var showsCapChrome: Bool { drawsCapChrome }

    /// Prefix qualifier font for the `.prefixedGlyph` cap, proportional to tier.
    private var prefixFontSize: CGFloat {
        switch size {
        case .regular: return 9
        case .compact: return 8
        case .tiny: return 6
        }
    }

    var body: some View {
        ZStack {
            // Cap background + border (frosted glass capsule under any
            // glyph). Drawn behind the content so the frame controls the
            // visible cap size — content positioning inside is purely
            // about centring the glyph in the square. Suppressed via
            // opacity (not removed) for chrome-less caps (`.tiny` with
            // `.automatic` chrome) so view identity stays stable across
            // tiers and chrome modes.
            RoundedRectangle(cornerRadius: activeCorner, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: activeCorner, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
                .opacity(drawsCapChrome ? 1 : 0)

            // Glyph content. Text glyphs use the monospaced design at
            // `fontSize` so single-letter caps sit visually identical
            // regardless of which character is inside. SF Symbol caps
            // render at the same font size — the canonical square frame
            // (Self.canonicalSize) takes care of the outer envelope so
            // a small chevron glyph and a wider letter glyph still
            // sit in the same cap footprint.
            switch content {
            case .text(let value):
                Text(value)
                    .font(.system(size: textFontSize(for: value), weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            case .symbol(let name, _):
                Image(systemName: name)
                    // Medium weight matches the text caps' visual mass so
                    // a chevron cap doesn't read as a thinner sibling next
                    // to a letter cap in the same hint chip.
                    .font(.system(size: activeFontSize, weight: .medium))
                    .foregroundColor(.primary)
            case .prefixedGlyph(let prefix, let glyph, _):
                // Compact two-element row inside ONE cap — the qualifier
                // (e.g. "right") sits in front of the modifier glyph at a
                // smaller weight so the user reads "right ⌘" as one
                // affordance, not a key combo to press. Horizontal padding
                // is included via the outer `.frame(minWidth:...)` below
                // so this hint stays inside the cap's rounded rect.
                HStack(spacing: 3) {
                    Text(prefix)
                        .font(.system(size: prefixFontSize, weight: .medium))
                        .foregroundColor(.primary.opacity(0.85))
                    Text(glyph)
                        .font(.system(size: activeFontSize, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 5)
            }
        }
        // Square 22×22 (or 16×16 in compact mode) for `.text` and `.symbol`
        // caps; `.prefixedGlyph` widens beyond that to fit the inline
        // qualifier + glyph pair while keeping the same vertical envelope
        // so it sits visually flush with neighbouring single-glyph caps.
        .frame(
            minWidth: activeSize,
            idealHeight: activeSize,
            maxHeight: activeSize
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement()
        .accessibilityLabel(resolvedAccessibilityLabel)
    }
}
