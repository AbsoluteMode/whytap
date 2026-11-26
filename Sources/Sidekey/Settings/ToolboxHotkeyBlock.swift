import Combine
import SwiftUI

/// Hotkey block at the top of a selected Toolbox tool: Set, or the current
/// shortcut with Change and Remove. It saves at once through
/// `HotkeyPreferences.assignToolShortcut` (the Hotkeys Save path) and records
/// with the shared `HotkeyRecordingSession`, so Settings -> Hotkeys shows the
/// same value immediately.
// WHY: .project-docs/decisions/2026-11-22-toolbox-tool-hotkey.md
@MainActor
struct ToolboxHotkeyBlock: View {
    @ObservedObject var preferences: HotkeyPreferences
    @StateObject private var controller: ToolboxHotkeyController

    init(tool: HoverTool, preferences: HotkeyPreferences = .shared) {
        self.preferences = preferences
        _controller = StateObject(wrappedValue: ToolboxHotkeyController(tool: tool, preferences: preferences))
    }

    var body: some View {
        ToolboxHotkeyRow(
            title: ToolboxHotkeyController.title(for: controller.tool),
            contents: controller.contents,
            isRecording: controller.isRecording,
            notice: controller.notice,
            onRecord: { controller.startRecording() },
            onCancel: { controller.cancel() },
            onClear: controller.shortcut == nil ? nil : { controller.remove() }
        )
        .onDisappear { controller.cancel() }
        // The tool's shortcut again: Lil Bro leads to its row in Hotkeys.
        .lilBroItems()
    }
}

/// State of one tool's Hotkey block, kept out of the view so Escape, Cancel,
/// start-over and saving are testable without a window.
@MainActor
final class ToolboxHotkeyController: ObservableObject {
    let tool: HoverTool
    let preferences: HotkeyPreferences
    let recording = HotkeyRecordingSession<HoverTool>()
    /// Conflicts of the last rejected shortcut. They belong to the open
    /// recording: every way it ends (Escape, Cancel, a saved shortcut,
    /// leaving the pane) clears them through the session's `onStop`.
    @Published private(set) var conflicts: [HotkeyConflict] = []
    private var forward: AnyCancellable?

    init(tool: HoverTool, preferences: HotkeyPreferences) {
        self.tool = tool
        self.preferences = preferences
        forward = recording.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    static func title(for tool: HoverTool) -> String {
        // Meeting record keeps its own main shortcut in Hotkeys.
        tool == .meetingRecord ? "Extra hotkey" : "Hotkey"
    }

    var shortcut: HotkeyShortcut? { preferences.toolShortcuts[tool] }
    var isRecording: Bool { recording.isRecording(tool) }
    var contents: [KeycapContent] { isRecording ? recording.contents : (shortcut?.contents ?? []) }

    var notice: ToolboxHotkeyRow.Notice? {
        if isRecording, let conflict = conflicts.first { return .warning(conflict.message) }
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

    /// Set and Change. Starting over drops the previous attempt's conflict.
    func startRecording(monitorsEvents: Bool = true) {
        conflicts = []
        recording.start(tool, current: shortcut, monitorsEvents: monitorsEvents,
                        onStop: { [weak self] in self?.conflicts = [] }) { [weak self] shortcut, tool in
            guard let self else { return }
            switch self.preferences.assignToolShortcut(shortcut, to: tool) {
            case .saved, .unchanged:
                self.recording.stop()
            case .conflict(let found):
                // Nothing saved; recording stays open for another shortcut.
                self.conflicts = found
            case .rejectedHoldSpace:
                break
            }
        }
    }

    func cancel() {
        recording.stop()
        conflicts = []
    }

    func remove() {
        cancel()
        preferences.assignToolShortcut(nil, to: tool)
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
                    .lilBroControl("Remove shortcut")
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
