import Foundation

/// The runtime captures a tool, never a position in the hover layout.
struct ToolHotkeyBinding: Equatable {
    let tool: HoverTool
    let shortcut: HotkeyShortcut
    let hotKeyID: UInt32

    static func resolve(_ shortcuts: [HoverTool: HotkeyShortcut]) -> [Self] {
        HoverTool.allCases.enumerated().compactMap { offset, tool in
            // A "Soon" tool keeps its saved shortcut but never captures the key.
            // WHY: .project-docs/decisions/2026-11-21-calendar-soon.md
            guard let shortcut = shortcuts[tool], shortcut != .holdSpace, !tool.isComingSoon else { return nil }
            return Self(tool: tool, shortcut: shortcut,
                        hotKeyID: CarbonHotkeyMonitor.toolHotKeyIDBase + UInt32(offset))
        }
    }
}
