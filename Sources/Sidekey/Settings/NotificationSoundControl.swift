import SwiftUI

/// A speaker icon beside a source's switch: crossed out and dimmed while the
/// source is silent (the default), plain and bright once a sound is chosen.
/// Clicking it opens a native menu of sounds; picking one plays a preview.
/// Maxim asked on 2026-11-20 to drop the separate "Notification sound" row.
struct NotificationSoundControl: View {
    @ObservedObject var settings: NotificationSoundSettings
    let sourceID: String
    let sourceName: String
    var preview: (NotificationSound) -> Void = { NotificationSoundPlayer.shared.play($0, preview: true) }
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    private var current: NotificationSound { settings.sound(for: sourceID) }

    var body: some View {
        Menu {
            ForEach(NotificationSound.allCases, id: \.self) { sound in
                // lilBro-exempt: an item of a menu; the menu is the control and reports itself
                Button {
                    settings.setSound(sound, for: sourceID)
                    preview(sound)
                } label: {
                    if sound == current {
                        Label(sound.title, systemImage: "checkmark")
                    } else {
                        Text(sound.title)
                    }
                }
            }
        } label: {
            Image(systemName: Self.symbolName(for: current))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(current == .none ? MacSettingsTheme.text3 : MacSettingsTheme.text)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.42)
        }
        .lilBroControl("Sound")
        .menuStyle(.button)
        .buttonStyle(MacButtonInteractionStyle(focused: focused))
        .menuIndicator(.hidden)
        .fixedSize()
        .focused($focused)
        .accessibilityLabel("Notification sound for \(sourceName)")
        .accessibilityValue(current.title)
        .help(current == .none ? "Sound off. Click to choose a sound." : "Sound: \(current.title). Click to change.")
    }

    static func symbolName(for sound: NotificationSound) -> String {
        sound == .none ? "speaker.slash" : "speaker.wave.2"
    }
}
