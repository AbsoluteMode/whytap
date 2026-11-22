import Foundation

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
