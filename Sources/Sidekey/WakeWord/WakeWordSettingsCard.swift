import AVFoundation
import SwiftUI

/// Settings -> Other -> Wake word: the opt-in switch and the phrases.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
struct WakeWordSettingsCard: View {
    @State private var enabled: Bool
    @State private var phrasesText: String
    @State private var rejected: [String] = []
    @State private var microphoneDenied = false

    private let preferences: WakeWordPreferences

    @MainActor
    init(preferences: WakeWordPreferences? = nil) {
        let resolved = preferences ?? .shared
        self.preferences = resolved
        _enabled = State(initialValue: resolved.isEnabled)
        _phrasesText = State(initialValue: resolved.phrasesText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Wake word")
            MacCard {
                MacRow(
                    title: "Start dictation by voice",
                    subtitle: "Say the phrase with a text field focused, wait for the island to start recording, then speak. Dictation ends when you stop. Whytap listens for the phrase on this Mac only and keeps no audio; the microphone indicator stays on while it listens."
                ) {
                    MacSwitch(isOn: enabledBinding, label: "Start dictation by voice")
                }

                if enabled {
                    MacRowSeparator()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Phrases")
                            .font(.system(size: 13))
                            .foregroundStyle(MacSettingsTheme.text)
                        MacField(placeholder: "why tap, why tab", text: $phrasesText)
                            .onSubmit(savePhrases)
                        Text(phrasesHint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
        }
        .onAppear {
            enabled = preferences.isEnabled
            phrasesText = preferences.phrasesText
            refreshMicrophoneStatus()
        }
        .onDisappear(perform: savePhrases)
    }

    private var phrasesHint: String {
        if microphoneDenied {
            return "Microphone access is off. Allow it in Settings -> Permissions, then switch this on again."
        }
        if !rejected.isEmpty {
            return "Not used: \(rejected.joined(separator: ", ")). The model is English: use Latin letters only."
        }
        return "Comma-separated, Latin letters. Write a phrase the way an English listener would hear it; add variants if it misses your pronunciation. Press Return to apply."
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { newValue in
                enabled = newValue
                guard newValue else {
                    preferences.isEnabled = false
                    return
                }
                // The switch is the explicit action that may ask for the
                // microphone; background listening itself never prompts.
                Task { @MainActor in
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                    }
                    refreshMicrophoneStatus()
                    preferences.isEnabled = true
                    NotificationCenter.default.post(name: WakeWordPreferences.didChangeNotification, object: nil)
                }
            }
        )
    }

    private func savePhrases() {
        rejected = WakeWordPreferences.rejectedEntries(in: phrasesText)
        preferences.phrasesText = phrasesText
        phrasesText = preferences.phrasesText
    }

    private func refreshMicrophoneStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneDenied = status == .denied || status == .restricted
    }
}
