import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Sidekey

/// Review images for the Toolbox Hotkey block and the selected-tile wash.
/// Invisible, never-key windows with temporary stores; layout evidence only.
// WHY: .project-docs/decisions/2026-11-22-toolbox-tool-hotkey.md
@MainActor
final class ToolboxHotkeyRenderTests: XCTestCase {
    func testOffscreenToolboxHotkeyStates() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_TOOLBOX_HOTKEY_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_TOOLBOX_HOTKEY_RENDER_DIR for Toolbox hotkey review images")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ToolboxHotkeyRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let hotkeys = HotkeyPreferences(defaults: defaults)
        let shot = HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey), keyTitle: "S")
        XCTAssertEqual(hotkeys.assignToolShortcut(.combo(shot), to: .screenshot), .saved)
        let hover = HoverLayoutStore(defaults: defaults)

        // Whole Toolbox at the minimum Settings content size (960 x 560 window).
        for (tool, name) in [(HoverTool.screenshot, "set"), (.dropMode, "none")] {
            for dark in [false, true] {
                let selection = SettingsWindowSelection(selectedTab: .toolbox)
                selection.focusedTool = tool
                let view = ToolboxSettingsView(hoverStore: hover, selection: selection,
                                               deps: ToolboxDeps(), hotkeys: hotkeys)
                    .background(MacSettingsTheme.bgContent)
                try render(view, size: NSSize(width: 740, height: 530), dark: dark,
                           to: directory.appendingPathComponent("toolbox-\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        // Every state of the block itself.
        let states = VStack(alignment: .leading, spacing: 12) {
            ToolboxHotkeyRow(title: "Hotkey", contents: [], isRecording: false, onRecord: {})
            ToolboxHotkeyRow(title: "Hotkey", contents: HotkeyShortcut.combo(shot).contents,
                             isRecording: false, onRecord: {}, onClear: {})
            ToolboxHotkeyRow(title: "Hotkey", contents: [], isRecording: true,
                             notice: .hint("Press a shortcut, then release all keys. Esc cancels."), onRecord: {})
            ToolboxHotkeyRow(title: "Hotkey", contents: HotkeyShortcut.combo(.optionQ).contents, isRecording: true,
                             notice: .warning("Shortcut ⌥ Q is already used by Agent close and Notify."),
                             onRecord: {})
            ToolboxHotkeyRow(title: "Hotkey", contents: HotkeyShortcut.combo(.optionD).contents, isRecording: false,
                             notice: .warning("Shortcut unavailable. Check Accessibility or record another shortcut."),
                             onRecord: {}, onClear: {})
            ToolboxHotkeyRow(title: "Extra hotkey", contents: [], isRecording: false, onRecord: {})
        }
        .padding(20)
        .frame(width: 380)
        for dark in [false, true] {
            try render(states.background(MacSettingsTheme.bgCard), size: NSSize(width: 380, height: 420), dark: dark,
                       to: directory.appendingPathComponent("hotkey-states-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
