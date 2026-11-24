import SwiftUI

extension FeatureHotkey {
    /// Puts `shortcut` on this action in `configuration`. Space as a hold-only
    /// key is Drop's alone; elsewhere it is refused (false) and nothing changes.
    @discardableResult
    func assign(_ shortcut: HotkeyShortcut, in configuration: inout HotkeyConfiguration) -> Bool {
        if shortcut == .holdSpace, self != .dropVoice { return false }
        switch self {
        case .dropVoice: configuration.setDropShortcut(shortcut)
        case .agentText: configuration.agentTextShortcut = shortcut
        case .agentVoice: configuration.agentVoiceShortcut = shortcut
        case .agentClose: configuration.agentCloseShortcut = shortcut
        case .googleText: configuration.googleSearchTextShortcut = shortcut
        case .googleVoice: configuration.googleSearchVoiceShortcut = shortcut
        case .meetingRecord: configuration.meetingRecordShortcut = shortcut
        case .tool(let tool): configuration.toolShortcuts[tool] = shortcut
        }
        return true
    }

    /// Hold or Toggle, for the voice shortcuts.
    func setGesture(_ gesture: HotkeyGesture, in configuration: inout HotkeyConfiguration) {
        switch self {
        case .dropVoice:
            configuration.dropVoiceGesture = HotkeyConfiguration.normalizedDropGesture(
                shortcut: configuration.dropVoiceShortcut, gesture: gesture)
        case .agentVoice: configuration.agentVoiceGesture = gesture
        case .googleVoice: configuration.googleSearchVoiceGesture = gesture
        case .agentText, .agentClose, .googleText, .meetingRecord, .tool: break
        }
    }

    /// Whether Hold and Toggle can both be chosen now. Space is hold-only for
    /// Drop: a tap of it is typing a space.
    func allowsGestureSwitch(in configuration: HotkeyConfiguration) -> Bool {
        switch self {
        case .dropVoice: return configuration.dropVoiceShortcut != .holdSpace
        case .agentVoice, .googleVoice: return true
        case .agentText, .agentClose, .googleText, .meetingRecord, .tool: return false
        }
    }
}

/// A feature's shortcut changed on the feature's own screen: the same
/// recorder as Settings -> Hotkeys and Toolbox, saved at once. A shortcut
/// another action already uses is not saved and recording stays open.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
final class FeatureShortcutEditor: ObservableObject {
    let hotkey: FeatureHotkey
    private let preferences: HotkeyPreferences
    @Published private(set) var conflicts: [HotkeyConflict] = []
    @Published private(set) var problem: String?
    @Published private(set) var isRecording = false
    @Published private(set) var recordedContents: [KeycapContent] = []
    private let recording = HotkeyRecordingSession<FeatureHotkey>()

    init(hotkey: FeatureHotkey, preferences: HotkeyPreferences) {
        self.hotkey = hotkey
        self.preferences = preferences
    }

    var configuration: HotkeyConfiguration { preferences.configuration }
    var gesture: HotkeyGesture { hotkey.gesture(in: configuration) }
    var canSwitchGesture: Bool { hotkey.allowsGestureSwitch(in: configuration) }
    var contents: [KeycapContent] { hotkey.shortcut(in: configuration)?.contents ?? [] }

    /// What the row says under its controls while something needs saying.
    var notice: String? {
        if let conflict = conflicts.first { return conflict.message }
        return problem
    }

    func startRecording(monitorsEvents: Bool = true) {
        conflicts = []
        problem = nil
        isRecording = true
        recording.start(hotkey, current: hotkey.shortcut(in: configuration), monitorsEvents: monitorsEvents,
                        onStop: { [weak self] in self?.isRecording = false }) { [weak self] shortcut, _ in
            self?.record(shortcut)
        }
    }

    /// A committed shortcut from the recorder (tests call it directly).
    func record(_ shortcut: HotkeyShortcut) {
        var candidate = configuration
        guard hotkey.assign(shortcut, in: &candidate) else { return }
        if save(candidate) { recording.stop() }
    }

    func cancel() {
        recording.stop()
        isRecording = false
        conflicts = []
    }

    func setGesture(_ gesture: HotkeyGesture) {
        guard canSwitchGesture, gesture != self.gesture else { return }
        var candidate = configuration
        hotkey.setGesture(gesture, in: &candidate)
        save(candidate)
    }

    @discardableResult
    private func save(_ candidate: HotkeyConfiguration) -> Bool {
        let found = candidate.conflicts
        guard found.isEmpty else {
            conflicts = found
            return false
        }
        do {
            try preferences.apply(candidate)
            conflicts = []
            problem = nil
            objectWillChange.send()
            return true
        } catch {
            problem = "Couldn’t save this shortcut. Record another one."
            return false
        }
    }
}

/// One shortcut on a feature's screen: what it does, its keys, Hold or
/// Toggle where that is a choice, and Change.
@MainActor
struct FeatureShortcutRow: View {
    @ObservedObject var editor: FeatureShortcutEditor
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.hotkey.label)
                        .font(.system(size: 13))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if editor.isRecording {
                    Text("Press the new shortcut… Esc cancels")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(MacSettingsTheme.accent, lineWidth: 1.5)
                        }
                        .fixedSize()
                        .accessibilityLabel("Recording a shortcut for \(editor.hotkey.label). Press the new shortcut, or Escape to cancel.")
                    MacButton(title: "Cancel") { editor.cancel() }.fixedSize()
                } else {
                    FeatureShortcutKeys(contents: editor.contents)
                    if editor.hotkey.isVoice {
                        MacSegmented(
                            items: [.init(value: HotkeyGesture.hold, label: HotkeyGesture.hold.voiceTitle),
                                    .init(value: HotkeyGesture.tap, label: HotkeyGesture.tap.voiceTitle)],
                            selection: Binding(get: { editor.gesture }, set: { editor.setGesture($0) }),
                            disabledValues: editor.canSwitchGesture ? [] : [.tap]
                        )
                        .frame(width: 164)
                        .accessibilityLabel("How \(editor.hotkey.label) is used")
                    }
                    MacButton(title: editor.contents.isEmpty ? "Record" : "Change") { editor.startRecording() }
                        .fixedSize()
                        .accessibilityLabel("Change the shortcut for \(editor.hotkey.label)")
                }
            }
            if let notice = editor.notice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The keys of a shortcut as caps, or "Not set".
struct FeatureShortcutKeys: View {
    let contents: [KeycapContent]

    var body: some View {
        if contents.isEmpty {
            Text("Not set")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text3)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                    KeycapView(content: content)
                        .frame(minWidth: 30, minHeight: 28)
                        .padding(.horizontal, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 1)
                        }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
