import SwiftUI

/// Single source of truth for hotkey glyphs used across UI hint surfaces.
/// Centralising these so a future redesign (e.g. SF Symbols swap) only
/// touches one file, and so callers don't sprinkle string literals like
/// `"⌥"` / `"⌘"` that are easy to mis-type or confuse with similar
/// Unicode characters (modifier symbols ⌥ U+2325 vs ‰ U+2030, ⌘ U+2318
/// vs ⌐ U+2310).
enum HotkeyGlyph {
    /// Option / Alt modifier — U+2325 PLACE OF INTEREST SIGN.
    static let option = "\u{2325}"
    /// Command modifier — U+2318 PLACE OF INTEREST SIGN.
    static let command = "\u{2318}"
    /// Shift modifier — U+21E7 UPWARDS WHITE ARROW.
    static let shift = "\u{21E7}"
    /// Control modifier — U+2303 UP ARROWHEAD.
    static let control = "\u{2303}"

    /// SF Symbol names for chevron arrow keys (left / right / up / down).
    /// Chosen over the Unicode arrow glyphs (←, →, ↑, ↓ — U+2190..U+2193)
    /// because the latter render as fully-formed triangle-and-tail arrows
    /// in most fonts; the SF Symbols `chevron.*` family is the lighter
    /// two-stroke "uголок" that matches the macOS keycap aesthetic the
    /// rest of the hint surfaces follow.
    static let chevronLeftSymbol = "chevron.left"
    static let chevronRightSymbol = "chevron.right"
    static let chevronUpSymbol = "chevron.up"
    static let chevronDownSymbol = "chevron.down"

    /// `KeycapContent` factories for the four chevron arrows. Pre-baked
    /// with the spoken accessibility label so callers compose hint rows
    /// the same way they do with text glyphs.
    static let chevronLeft: KeycapContent = .symbol(chevronLeftSymbol, accessibilityLabel: "Left arrow key")
    static let chevronRight: KeycapContent = .symbol(chevronRightSymbol, accessibilityLabel: "Right arrow key")
    static let chevronUp: KeycapContent = .symbol(chevronUpSymbol, accessibilityLabel: "Up arrow key")
    static let chevronDown: KeycapContent = .symbol(chevronDownSymbol, accessibilityLabel: "Down arrow key")

    /// Maps a glyph back to its spoken name so VoiceOver announces
    /// "Option key" rather than the meaningless single-codepoint
    /// character name. Falls back to "<glyph> key" for unknown
    /// glyphs so plain letters still read naturally.
    static func spokenName(for glyph: String) -> String {
        switch glyph {
        case option: return "Option key"
        case command: return "Command key"
        case shift: return "Shift key"
        case control: return "Control key"
        case "/": return "Slash key"
        case "Space": return "Space bar"
        default: return "\(glyph) key"
        }
    }
}

/// What a single keycap chip renders: either plain text (a letter, digit,
/// or Unicode modifier glyph) or an SF Symbol (used for chevron arrows so
/// the macOS-native two-stroke "uголок" replaces the Unicode arrow's
/// triangle-and-tail). The SF Symbol case carries its own spoken-label
/// override so VoiceOver users hear e.g. "Left arrow key" instead of the
/// raw symbol name "chevron.left".
enum KeycapContent: Equatable {
    case text(String)
    case symbol(String, accessibilityLabel: String?)
    /// A modifier cap with a small qualifier baked in front of the
    /// modifier glyph INSIDE the same cap (e.g. `right ⌘`). This is the
    /// disambiguation case for hotkeys wired to a specific physical key
    /// side (Sidekey's Agent gesture uses Right Command only). Putting
    /// the qualifier inside the cap — instead of as its own keycap or
    /// as an inline label outside — reads as a property of the modifier
    /// glyph rather than something the user needs to press.
    case prefixedGlyph(prefix: String, glyph: String, accessibilityLabel: String?)

    /// VoiceOver pronunciation for this content. Text falls through to
    /// `HotkeyGlyph.spokenName(for:)` so single-letter labels still read
    /// as "X key" / modifier glyphs read as "Option key" etc. SF Symbol
    /// content reads its explicit `accessibilityLabel`, falling back to
    /// "<symbol-name> key" if the caller omitted one. Prefixed glyph
    /// reads its explicit label (e.g. "Right Command key") so VoiceOver
    /// users hear the disambiguation explicitly.
    var spokenName: String {
        switch self {
        case .text(let value):
            return HotkeyGlyph.spokenName(for: value)
        case .symbol(let name, let label):
            return label ?? "\(name) key"
        case .prefixedGlyph(let prefix, let glyph, let label):
            return label ?? "\(prefix) \(HotkeyGlyph.spokenName(for: glyph))"
        }
    }
}

/// Visual chrome for a `HotkeyHintView`.
/// - `.container` — the standard `.ultraThinMaterial` capsule with dark wash
///   + thin white stroke around the caps. Every existing surface uses this.
/// - `.bare` — no surrounding capsule/pill/material at all; the caps render
///   as bare glyphs. An API option for glyph-only overline labels where even
///   per-cap chips would be too heavy; no production callsites today (the
///   Hover-slot hints moved on to `.keycaps`).
/// - `.keycaps` — no outer capsule (like `.bare`), but every cap draws its
///   own mini keycap chip. Used by the Dynamic Island Hover-slot hints
///   (⌥1..⌥5) sitting directly above each tile: `[⌥][1]` reads as two tiny
///   keys rather than loose glyphs, and by the agent useful-actions rolling
///   hint (compact tier, framed label) which wants per-cap chips without the
///   outer pill. Routing these through `HotkeyHintView` (rather than dropping
///   to `KeycapView` at the callsite) keeps the single entry point
///   `docs/hotkey.md` mandates.
enum HotkeyHintStyle {
    case container
    case bare
    case keycaps
}

/// Standardised hotkey hint: an optional small text label followed by
/// one or more `KeycapView` chips rendering the key glyphs/letters.
/// By default the whole hint sits inside an `.ultraThinMaterial` capsule
/// with a subtle dark wash + thin white stroke — the **outer chip** is part
/// of the standard, baked in here so every callsite renders identically
/// without re-wrapping. The `.bare` / `.keycaps` styles strip that container —
/// the Dynamic Island Hover-slot hints use `.keycaps` (per-cap mini chips).
///
/// Single source of truth across the app's UI surfaces — response panel
/// close row, Help window rows, floating keybindings hint, Hover-slot hints.
/// Spacing, font, and chip style live here; callers only pick the strings.
///
/// Layout: `[chip: label + keycap + keycap ...]` horizontally with
/// consistent 6pt inter-element spacing. The chip pads its contents
/// 10pt horizontal / 4pt vertical inside the capsule. The component
/// publishes a combined accessibility element so screen reader users
/// hear "<label>, Option key, Q key" in one swipe — preserved in the
/// container-less styles too.
struct HotkeyHintView: View {
    /// Optional small descriptor sitting to the left of the keycaps
    /// (e.g. "Quit", "Help"). Pass `nil` when the calling context
    /// already carries the descriptor (e.g. the Help window's row
    /// title column).
    let label: String?
    /// One keycap per element. The order is rendered left-to-right
    /// exactly as supplied. Each element may be plain text (letter,
    /// digit, or Unicode modifier glyph) or an SF Symbol (used by the
    /// chevron arrow caps for selection hint chips).
    let contents: [KeycapContent]
    /// Visual chrome. `.container` (default) wraps the caps in the standard
    /// `.ultraThinMaterial` capsule; `.bare` / `.keycaps` strip it (the
    /// Hover-slot hints above the tiles use `.keycaps`).
    let style: HotkeyHintStyle
    /// Cap size tier passed down to each `KeycapView`. `.regular` is the
    /// canonical envelope; `.compact` is the post-shrink "match the helper
    /// under the orb" chip (Quit ⌥ Q close-row, UsefulLinks selection chip);
    /// `.tiny` is the ~half-size used by the Hover-slot keycap-pair hints.
    /// The size also tightens the chip padding and label font.
    let size: KeycapSize
    /// `true` wraps the text `label` in its own keycap-style miniframe
    /// (frosted rounded rect + hairline stroke, matched to `KeycapView`'s
    /// envelope) so the descriptor word reads as a chip in its own right
    /// rather than loose text leaning on the keycaps. Used by the actions
    /// rolling hint, where "Insert" / "Open" / … should each sit framed
    /// beside their key glyphs. Default `false` leaves every other surface's
    /// label as plain inline text.
    let framedLabel: Bool

    /// Inter-element spacing between the label and each keycap.
    /// Matches the response panel close row's `HStack(spacing: 6)`
    /// so the visual rhythm stays identical across surfaces.
    private static let elementSpacing: CGFloat = 6
    /// Compact-mode inter-element spacing — half the default so the
    /// label sits visually adjacent to the (smaller) keycap.
    private static let compactElementSpacing: CGFloat = 4
    /// Tiny-mode inter-element spacing — the tiny `[⌥][1]` caps sit almost
    /// flush so the pair reads as one positional mark; at 2pt the `.keycaps`
    /// mini chips still read as two separate keys.
    private static let tinyElementSpacing: CGFloat = 2
    /// Inset between the chip's capsule edge and its contents. Picked
    /// from the floating Keybindings hint's previous self-styling so
    /// the migration is visually 1:1 in that surface.
    private static let chipHorizontalPadding: CGFloat = 10
    private static let chipVerticalPadding: CGFloat = 4
    /// Compact-mode padding — the chip rides closer to its keycap
    /// envelope so the total height drops to `KeycapView.compactSize`
    /// + 2pt, which is the visual envelope `KeybindingsHintView` pins
    /// its panel to (`panelHeight = compactChipIntrinsicHeight`) so the
    /// helper under the orb matches the agent panel's compact chips.
    /// Exposed `internal` so `KeybindingsHintView` derives its panel
    /// envelope from this single source of truth.
    static let compactChipHorizontalPadding: CGFloat = 6
    static let compactChipVerticalPadding: CGFloat = 1

    /// Designated initialiser — accepts a heterogeneous list of caps
    /// so callsites can mix text glyphs and SF Symbol chevrons in a
    /// single hint row, and picks the chrome style + cap size tier.
    init(
        label: String? = nil,
        contents: [KeycapContent],
        style: HotkeyHintStyle = .container,
        size: KeycapSize = .regular,
        framedLabel: Bool = false
    ) {
        self.label = label
        self.contents = contents
        self.style = style
        self.size = size
        self.framedLabel = framedLabel
    }

    /// Back-compat convenience: the boolean `compact:` flag maps onto the
    /// size tier (`true` → `.compact`) while keeping the standard container
    /// chrome, so existing callsites render identically.
    init(label: String? = nil, contents: [KeycapContent], compact: Bool) {
        self.init(
            label: label,
            contents: contents,
            style: .container,
            size: compact ? .compact : .regular
        )
    }

    /// Back-compat convenience: existing callsites that pass plain
    /// string glyphs ("⌥", "Q", "H", "/") keep compiling. The strings
    /// are wrapped in `KeycapContent.text(...)` internally so the
    /// designated init can stay one heterogeneous path.
    init(
        label: String? = nil,
        keys: [String],
        style: HotkeyHintStyle = .container,
        size: KeycapSize = .regular,
        framedLabel: Bool = false
    ) {
        self.init(label: label, contents: keys.map(KeycapContent.text), style: style, size: size, framedLabel: framedLabel)
    }

    /// Back-compat convenience for `keys:` callsites passing the boolean flag.
    init(label: String? = nil, keys: [String], compact: Bool) {
        self.init(
            label: label,
            contents: keys.map(KeycapContent.text),
            style: .container,
            size: compact ? .compact : .regular
        )
    }

    /// Whether the surrounding capsule/material container is drawn. `false`
    /// for the `.bare` and `.keycaps` styles. Exposed `internal` so unit tests
    /// can pin the "no pill in bare/keycaps mode" contract without introspecting
    /// the rendered tree.
    var showsContainer: Bool { style == .container }

    /// Cap chrome derived from the hint style: `.keycaps` forces per-cap chips,
    /// the other styles keep the size-tier default. Exposed `internal` for tests.
    var capChrome: KeycapChrome {
        style == .keycaps ? .chip : .automatic
    }

    /// Back-compat projection of the old boolean `compact` surface — `true`
    /// when the cap tier is `.compact`. Existing tests / callers that read
    /// `hint.compact` keep working after the migration to the `size` enum.
    var compact: Bool { size == .compact }

    /// Exposed `internal` so `HotkeyHintViewTests` can pin the back-compat
    /// projection from `[String]` to `[KeycapContent.text]` without having
    /// to introspect the view's body.
    var keys: [String] {
        contents.compactMap { content in
            if case .text(let value) = content { return value }
            return nil
        }
    }

    /// Inter-element spacing for the active size tier.
    private var elementSpacing: CGFloat {
        switch size {
        case .regular: return Self.elementSpacing
        case .compact: return Self.compactElementSpacing
        case .tiny: return Self.tinyElementSpacing
        }
    }

    /// Label font point size, proportional to the cap tier.
    private var labelFontSize: CGFloat {
        switch size {
        case .regular: return 11
        case .compact: return 10
        case .tiny: return 7
        }
    }

    /// Horizontal inset between container edge and caps. Collapses to 0 in
    /// the container-less styles (`.bare` / `.keycaps`) so the caps sit
    /// tight with no outer-chip padding.
    private var horizontalPadding: CGFloat {
        guard showsContainer else { return 0 }
        return size == .regular ? Self.chipHorizontalPadding : Self.compactChipHorizontalPadding
    }

    /// Vertical inset between container edge and caps. Collapses to 0 in
    /// the container-less styles.
    private var verticalPadding: CGFloat {
        guard showsContainer else { return 0 }
        return size == .regular ? Self.chipVerticalPadding : Self.compactChipVerticalPadding
    }

    /// Capsule fill — the frosted material for the contained style, fully
    /// transparent for the container-less styles. Unified through
    /// `AnyShapeStyle` so the `.background` modifier stays one view-identity
    /// across styles.
    private var containerFill: AnyShapeStyle {
        showsContainer ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear)
    }

    /// Dark wash over the material — transparent for the container-less styles.
    private var containerWash: Color {
        showsContainer ? Color.black.opacity(0.25) : Color.clear
    }

    /// Hairline border — transparent for the container-less styles.
    private var containerStroke: Color {
        showsContainer ? Color.white.opacity(0.15) : Color.clear
    }

    var body: some View {
        HStack(spacing: elementSpacing) {
            if let label {
                let labelText = Text(label)
                    // Label point size tracks the cap tier so the descriptor
                    // never visually dwarfs a smaller keycap.
                    .font(.system(size: labelFontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                if framedLabel {
                    // Same frosted miniframe as `KeycapView`, sized to the
                    // keycap envelope so the word sits flush beside its caps.
                    let corner: CGFloat = compact ? 5 : 7
                    labelText
                        .padding(.horizontal, compact ? 6 : 8)
                        .frame(height: compact ? KeycapView.compactSize : KeycapView.canonicalSize)
                        .background {
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .fill(.regularMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                                )
                        }
                } else {
                    labelText
                }
            }
            ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                KeycapView(content: content, size: size, chrome: capChrome)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            // `.ultraThinMaterial` blurs the wallpaper behind the chip
            // (NSVisualEffectView under the hood); the black overlay
            // tints it dark so the chip reads as one rounded affordance
            // against any background. Identical to the floating
            // Keybindings hint's previous treatment, now shared. For the
            // container-less styles (`.bare`, `.keycaps`) all three layers
            // go transparent so the caps render with no surrounding pill.
            Capsule(style: .continuous)
                .fill(containerFill)
                .overlay(Capsule(style: .continuous).fill(containerWash))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(containerStroke, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedAccessibilityLabel)
    }

    /// VoiceOver announcement for the whole hint — `"<label>, <key1>, <key2>"`
    /// so screen reader users hear the hotkey in one swipe instead of
    /// stepping through each cap. Exposed `internal` so unit tests can
    /// pin the spelling.
    var combinedAccessibilityLabel: String {
        var parts: [String] = []
        if let label, !label.isEmpty {
            parts.append(label)
        }
        parts.append(contentsOf: contents.map(\.spokenName))
        return parts.joined(separator: ", ")
    }
}
