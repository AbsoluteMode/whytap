import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Sidekey

/// Settings -> Toolbox sets a tool's hotkey at once, through the same storage,
/// conflict rule and recorder as Settings -> Hotkeys.
// WHY: .project-docs/decisions/2026-11-22-toolbox-tool-hotkey.md
@MainActor
final class ToolboxHotkeyBlockTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        AppState.shared.hotkeyRecordingActive = false
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SidekeyTests.ToolboxHotkey.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static let optionN = HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey), keyTitle: "N")

    // MARK: - Storage shared with Hotkeys

    func test_a_hotkey_set_in_toolbox_is_saved_and_shown_in_hotkeys() {
        let defaults = makeDefaults()
        let preferences = HotkeyPreferences(defaults: defaults)

        XCTAssertEqual(preferences.assignToolShortcut(.combo(Self.optionN), to: .notifs), .saved)

        XCTAssertEqual(preferences.toolShortcuts[.notifs], .combo(Self.optionN))
        // The Hotkeys tab starts its draft from `configuration`.
        XCTAssertEqual(preferences.configuration.toolShortcuts[.notifs], .combo(Self.optionN))
        // And it survives a relaunch: a fresh store reads the same defaults.
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).toolShortcuts[.notifs], .combo(Self.optionN))
        // Help and every hint read the same configuration.
        XCTAssertTrue(preferences.configuration.assignments.contains {
            $0.actionTitle == "Notify" && $0.binding.key == .combo(Self.optionN)
        })
    }

    func test_changing_a_hotkey_replaces_only_that_tool() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.assignToolShortcut(.combo(.optionD), to: .brightness)
        preferences.assignToolShortcut(.combo(Self.optionN), to: .notifs)

        XCTAssertEqual(preferences.assignToolShortcut(.combo(.optionFive), to: .notifs), .saved)

        XCTAssertEqual(preferences.toolShortcuts, [.brightness: .combo(.optionD), .notifs: .combo(.optionFive)])
        XCTAssertEqual(preferences.agentCloseShortcut, HotkeyConfiguration.defaults.agentCloseShortcut)
    }

    func test_a_conflicting_hotkey_is_reported_and_nothing_changes() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.assignToolShortcut(.combo(.optionD), to: .brightness)
        preferences.assignToolShortcut(.combo(Self.optionN), to: .vocab)

        let result = preferences.assignToolShortcut(.combo(.optionD), to: .vocab)

        guard case .conflict(let conflicts) = result else { return XCTFail("expected a conflict, got \(result)") }
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(Set(conflicts[0].actionTitles),
                       [HoverToolRegistry.info(for: .brightness).title, HoverToolRegistry.info(for: .vocab).title])
        XCTAssertTrue(conflicts[0].message.hasPrefix("Shortcut ⌥ D is already used by"), conflicts[0].message)
        XCTAssertEqual(preferences.toolShortcuts[.vocab], .combo(Self.optionN), "the old shortcut stays")
        XCTAssertEqual(preferences.toolShortcuts[.brightness], .combo(.optionD))
    }

    func test_a_core_shortcut_conflict_is_reported() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        // ⌥Q closes the Agent answer by default.
        guard case .conflict(let conflicts) = preferences.assignToolShortcut(.combo(.optionQ), to: .notifs) else {
            return XCTFail("expected a conflict")
        }
        XCTAssertTrue(conflicts[0].actionTitles.contains("Agent close"))
        XCTAssertNil(preferences.toolShortcuts[.notifs])
    }

    func test_removing_a_hotkey_clears_it_everywhere() {
        let defaults = makeDefaults()
        let preferences = HotkeyPreferences(defaults: defaults)
        preferences.assignToolShortcut(.combo(Self.optionN), to: .notifs)

        XCTAssertEqual(preferences.assignToolShortcut(nil, to: .notifs), .saved)

        XCTAssertNil(preferences.toolShortcuts[.notifs])
        XCTAssertNil(HotkeyPreferences(defaults: defaults).toolShortcuts[.notifs])
        XCTAssertEqual(preferences.assignToolShortcut(nil, to: .notifs), .unchanged)
    }

    func test_hold_space_is_drop_only_and_the_same_key_is_unchanged() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        XCTAssertEqual(preferences.assignToolShortcut(.holdSpace, to: .notifs), .rejectedHoldSpace)
        XCTAssertNil(preferences.toolShortcuts[.notifs])
        preferences.assignToolShortcut(.combo(Self.optionN), to: .notifs)
        XCTAssertEqual(preferences.assignToolShortcut(.combo(Self.optionN), to: .notifs), .unchanged)
    }

    // MARK: - Shared recorder

    private func key(_ type: NSEvent.EventType, _ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    private func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: UInt16(kVK_Option))!
    }

    private func press(optionWith code: Int, _ chars: String, into session: HotkeyRecordingSession<HoverTool>) {
        session.handle(flags(.option))
        session.handle(key(.keyDown, code, chars, .option))
        session.handle(key(.keyUp, code, chars, .option))
        session.handle(flags([]))
    }

    func test_recording_commits_on_release_and_consumes_keys() {
        let session = HotkeyRecordingSession<HoverTool>()
        var committed: [(HotkeyShortcut, HoverTool)] = []
        session.start(.notifs, current: nil, monitorsEvents: false) { committed.append(($0, $1)) }
        XCTAssertTrue(AppState.shared.hotkeyRecordingActive, "global hotkeys pause while recording")
        XCTAssertTrue(session.isRecording(.notifs))

        XCTAssertNil(session.handle(flags(.option)), "recording consumes the event")
        XCTAssertNil(session.handle(key(.keyDown, kVK_ANSI_N, "n", .option)))
        XCTAssertEqual(session.contents.count, 2, "⌥ and N are shown while held")
        XCTAssertTrue(committed.isEmpty)
        session.handle(key(.keyUp, kVK_ANSI_N, "n", .option))
        session.handle(flags([]))

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.0, .combo(Self.optionN))
        XCTAssertEqual(committed.first?.1, .notifs)
    }

    func test_escape_cancels_without_assigning() {
        let session = HotkeyRecordingSession<HoverTool>()
        var committed = 0
        session.start(.notifs, current: .combo(.optionD), monitorsEvents: false) { _, _ in committed += 1 }
        XCTAssertEqual(session.contents, HotkeyShortcut.combo(.optionD).contents, "seeded with the current shortcut")

        XCTAssertNil(session.handle(key(.keyDown, kVK_Escape, "\u{1b}")))

        XCTAssertNil(session.target)
        XCTAssertTrue(session.contents.isEmpty)
        XCTAssertFalse(AppState.shared.hotkeyRecordingActive)
        XCTAssertEqual(committed, 0)
        let other = key(.keyDown, kVK_ANSI_A, "a")
        XCTAssertTrue(session.handle(other) === other, "events pass through once stopped")
    }

    /// The Toolbox flow end to end: a conflict keeps recording open and saves
    /// nothing; the next free shortcut saves and stops.
    func test_toolbox_flow_conflict_then_free_shortcut() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.assignToolShortcut(.combo(.optionD), to: .brightness)
        let session = HotkeyRecordingSession<HoverTool>()
        var lastConflicts: [HotkeyConflict] = []
        session.start(.notifs, current: nil, monitorsEvents: false) { shortcut, tool in
            switch preferences.assignToolShortcut(shortcut, to: tool) {
            case .saved, .unchanged: session.stop()
            case .conflict(let found): lastConflicts = found
            case .rejectedHoldSpace: break
            }
        }

        press(optionWith: kVK_ANSI_D, "d", into: session)
        XCTAssertFalse(lastConflicts.isEmpty)
        XCTAssertTrue(session.isRecording(.notifs), "a conflict leaves recording open")
        XCTAssertNil(preferences.toolShortcuts[.notifs])

        press(optionWith: kVK_ANSI_N, "n", into: session)
        XCTAssertEqual(preferences.toolShortcuts[.notifs], .combo(Self.optionN))
        XCTAssertNil(session.target)
    }

    // MARK: - Installed monitor handler (builder finding 1)

    func test_installed_handler_swallows_what_the_session_consumes() {
        let session = HotkeyRecordingSession<HoverTool>()
        let handler = session.monitorHandler()
        session.start(.notifs, current: nil, monitorsEvents: false) { _, _ in }

        XCTAssertNil(handler(flags(.option)), "a recorded modifier never reaches the app")
        XCTAssertNil(handler(key(.keyDown, kVK_ANSI_N, "n", .option)))
        let escape = key(.keyDown, kVK_Escape, "\u{1b}")
        XCTAssertNil(handler(escape), "Escape cancels and is swallowed, not returned")
        XCTAssertNil(session.target)

        let after = key(.keyDown, kVK_ANSI_A, "a")
        XCTAssertTrue(handler(after) === after, "a stopped session passes events through")
    }

    func test_handler_of_a_released_session_passes_events_through() {
        var session: HotkeyRecordingSession<HoverTool>? = HotkeyRecordingSession<HoverTool>()
        let handler = session!.monitorHandler()
        session!.start(.notifs, current: nil, monitorsEvents: false) { _, _ in }
        session!.stop()
        session = nil
        let event = key(.keyDown, kVK_Escape, "\u{1b}")
        XCTAssertTrue(handler(event) === event)
    }

    func test_both_settings_views_install_the_same_handler() throws {
        let sessionSource = try source("Sources/Sidekey/Hotkeys/HotkeyRecordingSession.swift")
        XCTAssertTrue(sessionSource.contains("handler: monitorHandler())"))
        XCTAssertFalse(sessionSource.contains("self?.handle(event) ?? event"))
        XCTAssertTrue(try source("Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift").contains("recording.start(target"))
        XCTAssertTrue(try source("Sources/Sidekey/Settings/ToolboxHotkeyBlock.swift").contains("recording.start(tool"))
    }

    // MARK: - Conflict lifetime in Toolbox (builder finding 2)

    private func conflictedController() -> (ToolboxHotkeyController, (NSEvent) -> NSEvent?) {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.assignToolShortcut(.combo(.optionD), to: .brightness)
        let controller = ToolboxHotkeyController(tool: .notifs, preferences: preferences)
        controller.startRecording(monitorsEvents: false)
        let handler = controller.recording.monitorHandler()
        for event in [flags(.option), key(.keyDown, kVK_ANSI_D, "d", .option),
                      key(.keyUp, kVK_ANSI_D, "d", .option), flags([])] {
            _ = handler(event)
        }
        XCTAssertFalse(controller.conflicts.isEmpty)
        guard case .warning? = controller.notice else {
            XCTFail("a conflict shows a warning while recording")
            return (controller, handler)
        }
        return (controller, handler)
    }

    func test_escape_after_a_conflict_clears_the_warning() {
        let (controller, handler) = conflictedController()
        XCTAssertNil(handler(key(.keyDown, kVK_Escape, "\u{1b}")))
        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(controller.conflicts.isEmpty)
        XCTAssertNil(controller.notice, "no stale conflict after Escape")
        XCTAssertNil(controller.shortcut)
    }

    func test_cancel_after_a_conflict_clears_the_warning() {
        let (controller, _) = conflictedController()
        controller.cancel()
        XCTAssertTrue(controller.conflicts.isEmpty)
        XCTAssertNil(controller.notice)
    }

    func test_starting_over_after_a_conflict_clears_the_warning() {
        let (controller, _) = conflictedController()
        controller.startRecording(monitorsEvents: false)
        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.conflicts.isEmpty)
        XCTAssertEqual(controller.notice, .hint("Press a shortcut, then release all keys. Esc cancels."))
    }

    func test_a_free_shortcut_after_a_conflict_saves_and_clears_the_warning() {
        let (controller, handler) = conflictedController()
        for event in [flags(.option), key(.keyDown, kVK_ANSI_N, "n", .option),
                      key(.keyUp, kVK_ANSI_N, "n", .option), flags([])] {
            _ = handler(event)
        }
        XCTAssertEqual(controller.shortcut, .combo(Self.optionN))
        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(controller.conflicts.isEmpty)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(controller.contents, HotkeyShortcut.combo(Self.optionN).contents)
        controller.remove()
        XCTAssertNil(controller.shortcut)
    }

    // MARK: - Layout contracts

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func test_hotkey_block_is_pinned_above_the_tool_panel() throws {
        let toolbox = try source("Sources/Sidekey/Settings/ToolboxSettingsView.swift")
        let header = try XCTUnwrap(toolbox.range(of: "toolHeader(for: tool)\n"))
        let block = try XCTUnwrap(toolbox.range(of: "ToolboxHotkeyBlock(tool: tool, preferences: hotkeys)"))
        let viewport = try XCTUnwrap(toolbox.range(of: "ToolboxToolViewport {\n                        rightPaneContent"))
        XCTAssertLessThan(header.lowerBound, block.lowerBound)
        XCTAssertLessThan(block.lowerBound, viewport.lowerBound, "the Hotkey block never scrolls away")
    }

    func test_hotkeys_tab_and_toolbox_share_the_recorder() throws {
        let hotkeys = try source("Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift")
        XCTAssertTrue(hotkeys.contains("HotkeyRecordingSession<RecordingTarget>()"))
        XCTAssertFalse(hotkeys.contains("NSEvent.addLocalMonitorForEvents"), "one recorder implementation")
        let block = try source("Sources/Sidekey/Settings/ToolboxHotkeyBlock.swift")
        XCTAssertTrue(block.contains("HotkeyRecordingSession<HoverTool>()"))
        XCTAssertTrue(block.contains("preferences.assignToolShortcut("))
        XCTAssertFalse(block.contains("toolShortcuts[tool] ="), "no private copy of the storage")
    }

    func test_selected_tile_is_a_wash_and_click_never_draws_a_focus_rectangle() throws {
        let toolbox = try source("Sources/Sidekey/Settings/ToolboxSettingsView.swift")
        XCTAssertTrue(toolbox.contains(".focusable(interactions: .activate)"),
                      "keyboard navigation reaches tiles; a click does not focus them")
        XCTAssertTrue(toolbox.contains(".contentShape(.focusEffect, ToolboxTileFocusShape("))
        XCTAssertFalse(toolbox.contains("? MacSettingsTheme.accent\n                                          : MacSettingsTheme.sepStrong"),
                       "no accent outline on the selected circle")
        XCTAssertTrue(toolbox.contains("MacSettingsTheme.accent.opacity(Self.selectedWashOpacity)"))
    }

    func test_focus_shape_is_the_circle_at_the_top_of_the_tile() {
        let path = ToolboxTileFocusShape(diameter: 56).path(in: CGRect(x: 0, y: 0, width: 70, height: 88))
        XCTAssertEqual(path.boundingRect, CGRect(x: 7, y: 0, width: 56, height: 56))
    }
}
