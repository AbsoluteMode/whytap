import Foundation

enum IslandPassiveShortcutStyle: Equatable {
    case keycaps
    case inlineText
}

enum IslandPassiveTextWeight: Equatable {
    case medium
}

/// Passive-state hint shown in the Dynamic Island's right band when the
/// cursor is outside the pill.
struct IslandPassiveHint: Equatable {
    let title: String
    let actionLabel: String?
    let keyContents: [KeycapContent]
    let shortcutStyle: IslandPassiveShortcutStyle
    let keyScale: CGFloat

    init(
        title: String,
        actionLabel: String?,
        keyContents: [KeycapContent],
        shortcutStyle: IslandPassiveShortcutStyle = .keycaps,
        keyScale: CGFloat = 1.0
    ) {
        self.title = title
        self.actionLabel = actionLabel
        self.keyContents = keyContents
        self.shortcutStyle = shortcutStyle
        self.keyScale = keyScale
    }

    func keycapLayoutSize(baseSize: CGFloat) -> CGFloat {
        max(0, baseSize * keyScale)
    }

    func keycapLayoutHeight(baseSize: CGFloat) -> CGFloat {
        guard shortcutStyle == .keycaps else { return 0 }
        return keycapLayoutSize(baseSize: baseSize)
    }

    func keycapLayoutWidth(for content: KeycapContent, baseSize: CGFloat) -> CGFloat? {
        guard shortcutStyle == .keycaps else { return nil }
        switch content {
        case .prefixedGlyph:
            return nil
        case .symbol:
            return keycapLayoutSize(baseSize: baseSize)
        case .text(let value):
            // A single-glyph cap (⌥, /, H) renders inside the canonical
            // square. A multi-character label like "Space" overflows that
            // square and would clip, so widen the layout slot to fit the
            // glyph count while keeping the square height. `nil` lets the
            // cap size itself horizontally (KeycapView already widens via
            // `.fixedSize(horizontal:)`), so wide labels are never pinned
            // to the square width.
            return value.count > 1 ? nil : keycapLayoutSize(baseSize: baseSize)
        }
    }
}

enum IslandPassiveHints {
    /// Maxim asked for the passive hints to rotate every five seconds.
    static let cycleIntervalSeconds: Double = 5.0
    static let titleFontSize: CGFloat = 8.8
    static let secondaryTextFontSize: CGFloat = 8.5
    static let secondaryTextWeight: IslandPassiveTextWeight = .medium
    static let secondaryTextOpacity: Double = 0.56
    static let inlineShortcutFontSize = secondaryTextFontSize
    static let inlineShortcutTextWeight = secondaryTextWeight
    static let inlineShortcutTextOpacity = secondaryTextOpacity
    static let verticalOffset: CGFloat = -2

    /// Default-configuration hint sequence. Back-compat entry point for the
    /// renderer's width-claimer and the unit suite; production rendering goes
    /// through `hints(for:)` so a rebound shortcut flows into the Island.
    static var hints: [IslandPassiveHint] {
        hints(for: .defaults)
    }

    /// The passive-hint sequence for a given hotkey configuration. The Drop
    /// hint's keycaps and action verb are derived from the live config
    /// (`dropVoiceShortcut` / `dropVoiceGesture`) so the Dynamic Island stays
    /// the single source of truth alongside Help / onboarding / the floating
    /// chip — post-cutover this renders "Drop hold Space" instead of the old
    /// hardcoded `⌥ /`.
    static func hints(for configuration: HotkeyConfiguration) -> [IslandPassiveHint] {
        return [
            IslandPassiveHint(
                title: "Agent Voice",
                actionLabel: "hold",
                keyContents: [
                    .prefixedGlyph(
                        prefix: "right",
                        glyph: HotkeyGlyph.command,
                        accessibilityLabel: "Right Command key"
                    )
                ],
                shortcutStyle: .inlineText
            ),
            IslandPassiveHint(
                title: "Drop",
                actionLabel: configuration.normalizedDropGesture.voiceTitle.lowercased(),
                keyContents: configuration.dropVoiceShortcut.contents,
                shortcutStyle: .inlineText
            ),
            IslandPassiveHint(
                title: "Agent Text",
                actionLabel: "tap",
                keyContents: [
                    .prefixedGlyph(
                        prefix: "right",
                        glyph: HotkeyGlyph.command,
                        accessibilityLabel: "Right Command key"
                    )
                ],
                shortcutStyle: .inlineText
            ),
        ]
    }

    static func activeHintIndex(at time: Double, count: Int, interval: Double) -> Int {
        guard count > 0, interval > 0 else { return 0 }
        let totalCycle = interval * Double(count)
        let modulated = time.truncatingRemainder(dividingBy: totalCycle)
        let normalised = modulated < 0 ? modulated + totalCycle : modulated
        return min(count - 1, Int(normalised / interval))
    }
}
