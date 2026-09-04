import SwiftUI

/// Compact monospaced text hint, centered in the idle pill, communicating the
/// activation shortcut to the user. Replaces the previous dotted-line idle
/// indicator that was visually conflated with the recording state. Styled to
/// match the ElevenLabs reference: subdued white at 55% opacity, 10pt medium
/// monospaced, with light kerning.
struct ShortcutHint: View {
    /// Modifier+key text shown in idle state. Renders as a single chip if the
    /// caller wants the legacy look, but `keys` array gives the chip-per-key
    /// look used in idle state (e.g. ["R⌥", "/"]).
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.55))
            .tracking(0.3)
            .lineLimit(1)
            .allowsHitTesting(false)
    }
}

/// Renders a row of monospaced "key chips" — used to communicate the activation
/// shortcut as visually separate keys (e.g. `R⌥` and `/`).
///
/// The drop row's chips are not highlighted in real time. Carbon
/// `RegisterEventHotKey` (used by `CarbonHotkeyMonitor`) delivers a single
/// "hot-key fired" event, not per-key flag changes, so the press-state
/// animation that the CGEventTap-based monitor used to drive is no longer
/// available. The row stays as a static hint.
struct ShortcutChips: View {
    @ObservedObject var state: AppState = .shared
    @ObservedObject var hotkeys: HotkeyPreferences = .shared

    var body: some View {
        let configuration = hotkeys.configuration
        let agentTextHeld = isHeld(configuration.agentTextShortcut)
        let agentVoiceHeld = isHeld(configuration.agentVoiceShortcut)
        VStack(alignment: .leading, spacing: 0) {
            ShortcutChipRow(
                keys: chipKeys(for: configuration.agentVoiceShortcut, isHighlighted: agentVoiceHeld),
                label: "\(configuration.agentVoiceGesture.voiceTitle.lowercased()) ← agent voice",
                rowHighlighted: agentVoiceHeld
            )
            ShortcutChipRow(
                keys: chipKeys(for: configuration.agentTextShortcut, isHighlighted: agentTextHeld),
                label: "tap ← agent text",
                rowHighlighted: agentTextHeld
            )
            ShortcutChipRow(
                keys: configuration.dropVoiceShortcut.shortcutChipTitles.map {
                    ShortcutChipKey(title: $0, isHighlighted: false)
                },
                label: "\(configuration.normalizedDropGesture.voiceTitle.lowercased()) ← drop voice",
                rowHighlighted: false
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.10), value: state.rightCommandHeld)
        .animation(.easeOut(duration: 0.10), value: state.rightOptionHeld)
    }

    private func chipKeys(for shortcut: HotkeyShortcut, isHighlighted: Bool) -> [ShortcutChipKey] {
        shortcut.shortcutChipTitles.map {
            ShortcutChipKey(title: $0, isHighlighted: isHighlighted)
        }
    }

    private func isHeld(_ shortcut: HotkeyShortcut) -> Bool {
        guard let key = shortcut.modifierKey else { return false }
        switch key {
        case .rightCommand:
            return state.rightCommandHeld
        case .rightOption:
            return state.rightOptionHeld
        }
    }
}

private struct ShortcutChipKey: Hashable {
    let title: String
    let isHighlighted: Bool
}

private struct ShortcutChipRow: View {
    let keys: [ShortcutChipKey]
    let label: String
    let rowHighlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.title) { key in
                Text(key.title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(key.isHighlighted ? .white : .white.opacity(0.78))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(keyColor(for: key))
                    )
            }
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(rowHighlighted ? .white.opacity(0.85) : .white.opacity(0.62))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyColor(for key: ShortcutChipKey) -> Color {
        if rowHighlighted {
            return Color.green.opacity(0.58)
        }
        return key.isHighlighted ? Color.indigo.opacity(0.62) : Color.white.opacity(0.08)
    }
}
