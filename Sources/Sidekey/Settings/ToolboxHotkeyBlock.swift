import SwiftUI

/// Hotkey block at the top of a selected Toolbox tool: Set, or the current
/// shortcut with Change and Remove. It saves at once through
/// `HotkeyPreferences.assignToolShortcut` (the Hotkeys Save path) and records
/// with the shared `HotkeyRecordingSession`, so Settings -> Hotkeys shows the
/// same value immediately.
// WHY: .project-docs/decisions/2026-11-22-toolbox-tool-hotkey.md
@MainActor
struct ToolboxHotkeyBlock: View {
    let tool: HoverTool
    @ObservedObject var preferences: HotkeyPreferences
    @StateObject private var recording = HotkeyRecordingSession<HoverTool>()
    @State private var conflicts: [HotkeyConflict] = []

    init(tool: HoverTool, preferences: HotkeyPreferences = .shared) {
        self.tool = tool
        self.preferences = preferences
    }

    var body: some View {
        let shortcut = preferences.toolShortcuts[tool]
        let isRecording = recording.isRecording(tool)
        ToolboxHotkeyRow(
            title: Self.title(for: tool),
            contents: isRecording ? recording.contents : (shortcut?.contents ?? []),
            isRecording: isRecording,
            notice: notice(shortcut: shortcut, isRecording: isRecording),
            onRecord: startRecording,
            onCancel: stopRecording,
            onClear: shortcut == nil ? nil : {
                stopRecording()
                preferences.assignToolShortcut(nil, to: tool)
            }
        )
        .onDisappear(perform: stopRecording)
    }

    static func title(for tool: HoverTool) -> String {
        // Meeting record keeps its own main shortcut in Hotkeys.
        tool == .meetingRecord ? "Extra hotkey" : "Hotkey"
    }

    private func notice(shortcut: HotkeyShortcut?, isRecording: Bool) -> ToolboxHotkeyRow.Notice? {
        if let conflict = conflicts.first { return .warning(conflict.message) }
        if isRecording { return .hint("Press a shortcut, then release all keys. Esc cancels.") }
        if tool.isComingSoon, shortcut != nil {
            return .hint("\(CalendarAvailability.badge): a shortcut saved here stays inactive.")
        }
        if shortcut != nil, preferences.unavailableToolShortcuts.contains(tool) {
            return .warning("Shortcut unavailable. Check Accessibility or record another shortcut.")
        }
        if let shortcut, let caption = HotkeysSettingsView.bareKeyCaption(for: shortcut) {
            return .hint(caption)
        }
        return nil
    }

    private func startRecording() {
        conflicts = []
        recording.start(tool, current: preferences.toolShortcuts[tool]) { shortcut, tool in
            switch preferences.assignToolShortcut(shortcut, to: tool) {
            case .saved, .unchanged:
                conflicts = []
                recording.stop()
            case .conflict(let found):
                // Nothing saved; recording stays open for another shortcut.
                conflicts = found
            case .rejectedHoldSpace:
                break
            }
        }
    }

    private func stopRecording() {
        recording.stop()
        conflicts = []
    }
}

/// Presentation of the Hotkey block; state lives in `ToolboxHotkeyBlock`.
@MainActor
struct ToolboxHotkeyRow: View {
    enum Notice: Equatable {
        case hint(String)
        case warning(String)
    }

    let title: String
    let contents: [KeycapContent]
    let isRecording: Bool
    var notice: Notice?
    let onRecord: () -> Void
    var onCancel: () -> Void = {}
    var onClear: (() -> Void)?

    private var hasConflict: Bool {
        if case .warning = notice, isRecording { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(MacSettingsTheme.text2)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                Spacer(minLength: 8)
                controls
            }
            if let notice {
                switch notice {
                case .hint(let text):
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                case .warning(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MacSettingsTheme.hover.opacity(0.45))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) for this tool")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            if contents.isEmpty && !isRecording {
                MacButton(title: "Set", style: .tinted, action: onRecord)
                    .help("Press a shortcut, then release all keys. Escape cancels.")
                    .accessibilityLabel("Set \(title.lowercased())")
            } else {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, content in
                    ShortcutKeySlot(content: content, isRecording: isRecording,
                                    hasConflict: hasConflict, onTap: onRecord)
                }
                if isRecording {
                    MacButton(title: "Cancel", style: .ghost, action: onCancel)
                } else {
                    MacButton(title: "Change", style: .default, action: onRecord)
                        .help("Record another shortcut")
                        .accessibilityLabel("Change \(title.lowercased())")
                }
                if let onClear, !isRecording {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MacSettingsTheme.text2)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                    .accessibilityLabel("Remove \(title.lowercased())")
                }
            }
        }
    }

    private var slots: [KeycapContent?] {
        contents.isEmpty ? [nil] : contents.map(Optional.some)
    }
}
