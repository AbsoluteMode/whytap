import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One shortcut recording at a time, shared by Settings -> Hotkeys and the
/// Hotkey block of Settings -> Toolbox: the same recorder, Escape-to-cancel
/// and `AppState.hotkeyRecordingActive` gate, so both places record alike.
// WHY: .project-docs/decisions/2026-11-22-toolbox-tool-hotkey.md
@MainActor
final class HotkeyRecordingSession<Target: Equatable>: ObservableObject {
    @Published private(set) var target: Target?
    @Published private(set) var contents: [KeycapContent] = []

    private var recorder = HotkeyShortcutRecorder()
    private var eventMonitor: Any?
    private var onRecord: ((HotkeyShortcut, Target) -> Void)?

    /// Starts recording for `target`, seeded with its current shortcut.
    /// `onRecord` receives each committed shortcut; recording stays open until
    /// the caller stops it, so a rejected shortcut can simply be re-pressed.
    /// Tests pass `monitorsEvents: false` and feed `handle(_:)` directly.
    func start(_ target: Target, current: HotkeyShortcut?, monitorsEvents: Bool = true,
               onRecord: @escaping (HotkeyShortcut, Target) -> Void) {
        stop()
        recorder = HotkeyShortcutRecorder(shortcut: current)
        contents = current?.contents ?? []
        self.target = target
        self.onRecord = onRecord
        AppState.shared.hotkeyRecordingActive = true
        guard monitorsEvents else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        let wasRecording = target != nil
        target = nil
        onRecord = nil
        contents = []
        if wasRecording { AppState.shared.hotkeyRecordingActive = false }
    }

    /// Consumes every key event while recording. Escape cancels.
    @discardableResult
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let target else { return event }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            stop()
            return nil
        }
        guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return nil }
        if let shortcut = recorder.record(event) {
            onRecord?(shortcut, target)
        }
        // `onRecord` may have stopped the session.
        if self.target != nil { contents = recorder.contents }
        return nil
    }

    func isRecording(_ candidate: Target) -> Bool { target == candidate }
}

/// Result of assigning a tool shortcut outside the Hotkeys draft.
enum ToolShortcutAssignment: Equatable {
    case saved
    case unchanged
    /// Hold-Space is Drop's alone; the recorder may still emit it.
    case rejectedHoldSpace
    case conflict([HotkeyConflict])
}

extension HotkeyConfiguration {
    /// The configuration with only `tool`'s shortcut changed (nil removes it).
    func settingToolShortcut(_ shortcut: HotkeyShortcut?, for tool: HoverTool) -> HotkeyConfiguration {
        var result = self
        result.toolShortcuts[tool] = shortcut
        return result
    }
}

extension HotkeyPreferences {
    /// Saves one tool's shortcut at once through `apply`, the Hotkeys Save
    /// path, so registration, persistence and conflict rules stay one. A
    /// conflicting shortcut changes nothing and returns the conflicts it
    /// would create.
    @discardableResult
    func assignToolShortcut(_ shortcut: HotkeyShortcut?, to tool: HoverTool) -> ToolShortcutAssignment {
        if shortcut == .holdSpace { return .rejectedHoldSpace }
        let current = configuration
        guard current.toolShortcuts[tool] != shortcut else { return .unchanged }
        let candidate = current.settingToolShortcut(shortcut, for: tool)
        let title = HoverToolRegistry.info(for: tool).title
        let conflicts = candidate.conflicts
        if !conflicts.isEmpty {
            let own = conflicts.filter { $0.actionTitles.contains(title) }
            return .conflict(own.isEmpty ? conflicts : own)
        }
        do {
            try apply(candidate)
            return .saved
        } catch HotkeyConfigurationError.conflictingBindings(let conflicts) {
            return .conflict(conflicts)
        } catch {
            return .conflict([])
        }
    }
}
