import Carbon.HIToolbox
import Combine
import XCTest
import WhytapCaseKit
@testable import Sidekey

/// Every Whytap hotkey through the application controls, as Claude Code,
/// Codex and the island's Agent reach them: `hotkeys_get` and `hotkey_set`
/// with `hotkey`. Temporary defaults only; no monitor is installed.
private extension AppControlResponse {
    var error: (code: String, message: String)? {
        guard !ok, let code = data.object?["code"]?.string else { return nil }
        return (code, data.object?["message"]?.string ?? "")
    }
}

@MainActor
final class AppControlHotkeysTests: XCTestCase {
    private var preferences: HotkeyPreferences!
    private var toolbox: AppControlToolbox!

    override func setUp() async throws {
        let suite = "app-control-hotkeys-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = HotkeyPreferences(defaults: defaults)
        let layout = HoverLayoutStore(defaults: defaults)
        self.preferences = preferences
        toolbox = AppControlToolbox(layout: { layout }, hotkeys: { preferences })
        let saved = AppControlToolbox.keyboardCharacter
        AppControlToolbox.keyboardCharacter = { _ in nil }
        addTeardownBlock { await MainActor.run { AppControlToolbox.keyboardCharacter = saved } }
    }

    private var grave: HotkeyShortcut {
        .combo(HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_Grave), modifiers: 0, keyTitle: "`"))
    }
    private func combo(_ keys: String) -> HotkeyShortcut { .combo(WhytapLink.linkCombo(from: keys)!) }

    private func set(_ arguments: [String: AppControlValue]) -> AppControlResponse {
        toolbox.handle("hotkey_set", arguments)
    }

    private func rows() throws -> [String: [String: AppControlValue]] {
        let response = toolbox.handle("hotkeys_get", [:])
        XCTAssertTrue(response.ok)
        let list = try XCTUnwrap(response.data.object?["hotkeys"]?.array)
        return Dictionary(uniqueKeysWithValues: list.compactMap(\.object).map { ($0["id"]!.string!, $0) })
    }

    private func keys(_ text: String) -> HotkeyShortcut { AppControlHotkeys.shortcut(from: text)! }

    /// The owner's request on build with #545 (2026-11-28): "change Drop in
    /// Whytap to `". Drop on hold Space → hold ` → Toggle on ` → hold Space,
    /// each saved through the Settings path and seen by the Drop monitor's
    /// observers at once; every reply says what is bound and how to undo it.
    func test_owner_sets_drop_to_backquote_then_toggle_then_back_to_hold_space() throws {
        var shortcuts: [HotkeyShortcut] = [], gestures: [HotkeyGesture] = []
        let a = AppDelegate.observeDropShortcut(preferences) { shortcuts.append($0) }
        let b = AppDelegate.observeDropGesture(preferences) { gestures.append($0) }
        defer { a.cancel(); b.cancel() }

        let toGrave = set(["hotkey": .string("dropVoice"), "keys": .string("`"), "mode": .string("hold"),
                           "expected": .string("space")])
        XCTAssertTrue(toGrave.ok, "\(toGrave)")
        let reply = try XCTUnwrap(toGrave.data.object)
        XCTAssertEqual(preferences.dropVoiceShortcut, grave)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertEqual(shortcuts.last, grave)
        XCTAssertEqual(reply["bound"], .string("Drop voice is Hold `."))
        XCTAssertEqual(reply["previous"], .object(["keys": .string("space"), "display": .string("Space"), "mode": .string("hold")]))
        XCTAssertEqual(reply["undo"], .object(["hotkey": .string("dropVoice"), "keys": .string("space"),
                                               "mode": .string("hold"), "expected": .string("`")]))
        XCTAssertEqual(reply["takenEverywhere"], .string("A quick press of ` still types “`”; holding it about 0.3 s in a text field starts dictation and erases the typed “`”."))
        XCTAssertEqual(try rows()["dropVoice"]?["keys"], .string("`"))

        let toggle = set(["hotkey": .string("dropVoice"), "mode": .string("toggle"), "expected": .string("`")])
        XCTAssertTrue(toggle.ok, "\(toggle)")
        XCTAssertEqual(preferences.dropVoiceGesture, .tap)
        XCTAssertEqual(gestures.last, .tap)
        XCTAssertEqual(toggle.data.object?["bound"], .string("Drop voice is Toggle `."))
        XCTAssertEqual(toggle.data.object?["takenEverywhere"],
                       .string("` is now taken by Whytap in every app: it no longer types “`” there."))

        // The undo of the first reply, sent as is, would now be stale: expected is `.
        let back = set(["hotkey": .string("dropVoice"), "keys": .string("space"), "mode": .string("hold"), "expected": .string("`")])
        XCTAssertTrue(back.ok, "\(back)")
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertEqual(shortcuts.last, .holdSpace)
        XCTAssertEqual(back.data.object?["previous"]?.object?["mode"], .string("toggle"))
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .string("space"), "expected": .string("space")])
            .data.object?["changed"], .bool(false))
    }

    /// The hold Drop on a bare key really keeps typing: the monitor passes a
    /// quick press through and, on a hold in a text field, erases it and arms.
    func test_hold_drop_on_backquote_types_on_a_quick_press_and_dictates_on_a_hold() {
        var armed = 0, posted: [CGKeyCode] = []
        let monitor = SpaceHoldMonitor(
            triggerKeyCode: CGKeyCode(kVK_ANSI_Grave), requiredModifiers: [],
            onHotkey: { armed += 1 }, onHotkeyReleased: {}, onCancel: {},
            makeTap: { _ in OpaquePointer(bitPattern: 0x1) }, enableTap: { _ in },
            scheduleThreshold: { _ in }, cancelThreshold: {},
            frontmostApp: { (pid_t(1234), "com.example.app") }, isEditable: { _, _ in true },
            postEvent: { code, down in if down { posted.append(code) } },
            runOnDetectorQueue: { $0() }, runEditableCheckOffTapThread: { $0() }, dispatchCallback: { $0() },
            log: { _, _ in })
        let grave = CGKeyCode(kVK_ANSI_Grave)
        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: grave, isRepeat: false, flags: []), .passThrough)
        XCTAssertEqual(monitor.handleTapEvent(type: .keyUp, keyCode: grave, isRepeat: false, flags: []), .passThrough)
        XCTAssertEqual(armed, 0, "a quick press types ` and does not dictate")

        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: grave, isRepeat: false, flags: []), .passThrough)
        monitor.fireThreshold()
        XCTAssertEqual(armed, 1, "a hold in a text field starts dictation")
        XCTAssertEqual(posted, [CGKeyCode(kVK_Delete)], "the typed ` is erased")
    }

    /// Anything the Settings recorder records is accepted on any row: a bare
    /// letter, a Command+Shift combination, Tab, an arrow; each says what it
    /// takes from other apps.
    func test_bare_letter_and_command_shift_combo_are_accepted_with_a_warning() throws {
        let letter = set(["hotkey": .string("meetingRecord"), "keys": .string("k"), "expected": .string("option+m")])
        XCTAssertTrue(letter.ok, "\(letter)")
        XCTAssertEqual(preferences.meetingRecordShortcut, keys("k"))
        XCTAssertEqual(letter.data.object?["takenEverywhere"],
                       .string("K is now taken by Whytap in every app: it no longer types “k” there."))
        XCTAssertEqual(letter.data.object?["undo"]?.object?["keys"], .string("option+m"))

        let command = set(["hotkey": .string("dropVoice"), "keys": .string("command+shift+d"), "mode": .string("toggle"),
                           "expected": .string("space")])
        XCTAssertTrue(command.ok, "\(command)")
        XCTAssertEqual(preferences.dropVoiceShortcut, keys("shift+command+d"))
        XCTAssertEqual(try rows()["dropVoice"]?["keys"], .string("shift+command+d"))
        XCTAssertEqual(command.data.object?["takenEverywhere"],
                       .string("⇧⌘D is now taken by Whytap in every app: apps or macOS that use ⇧⌘D no longer get it."))

        // A tool takes any recorded key through the hotkey form, Quit included,
        // as Settings → Hotkeys → Tools does.
        XCTAssertTrue(set(["hotkey": .string("tool.screenshot"), "keys": .string("command+shift+5"), "expected": .null]).ok)
        XCTAssertTrue(set(["hotkey": .string("tool.quit"), "keys": .string("control+option+command+q"), "expected": .null]).ok)
        XCTAssertEqual(preferences.toolShortcuts[.quit], keys("control+option+command+q"))
        // Agent close is scoped to the visible answer; the warning says so.
        let close = set(["hotkey": .string("agentClose"), "keys": .string("tab"), "expected": .string("option+q")])
        XCTAssertEqual(close.data.object?["takenEverywhere"],
                       .string("Tab is now taken by Whytap while an Agent answer is on screen: it no longer works as Tab there."))
        // An ⌃⌥ combination types nothing and takes nothing obvious.
        XCTAssertNil(set(["hotkey": .string("googleText"), "keys": .string("control+option+g"), "expected": .string("right_option")])
            .data.object?["takenEverywhere"])
        XCTAssertEqual(set(["hotkey": .string("agentClose"), "keys": .string("escape"), "expected": .string("tab")]).error?.code,
                       "invalid_hotkey")
        XCTAssertEqual(set(["hotkey": .string("agentClose"), "keys": .string("option"), "expected": .string("tab")]).error?.code,
                       "invalid_hotkey")
    }

    func test_switch_hold_and_toggle_on_a_combo_keeps_the_keys() throws {
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "keys": .string("option+d"), "expected": .string("space")]).ok)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "mode": .string("toggle"), "expected": .string("option+d")]).ok)
        XCTAssertEqual(preferences.dropVoiceShortcut, combo("option+d"))
        XCTAssertEqual(preferences.dropVoiceGesture, .tap)
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "mode": .string("hold"), "expected": .string("d+option")]).ok == false,
                      "a misspelt expected value is a stale value, not a match")
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "mode": .string("hold"), "expected": .string("option d")]).ok)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)

        var gestures: [HotkeyGesture] = []
        let sink = preferences.$googleSearchVoiceGesture.dropFirst().sink { gestures.append($0) }
        defer { sink.cancel() }
        XCTAssertTrue(set(["hotkey": .string("googleVoice"), "keys": .string("control+option+g"), "mode": .string("toggle"),
                           "expected": .string("right_option")]).ok)
        XCTAssertEqual(gestures, [.tap])
    }

    func test_space_stays_drops_alone_and_hold_only() throws {
        let before = preferences.configuration
        let toggle = set(["hotkey": .string("dropVoice"), "mode": .string("toggle"), "expected": .string("space")])
        XCTAssertEqual(toggle.error?.code, "invalid_mode")
        XCTAssertTrue(toggle.error?.message.contains("hold-only") == true)
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .string("space"), "mode": .string("toggle"),
                            "expected": .string("space")]).error?.code, "invalid_mode")
        XCTAssertEqual(set(["hotkey": .string("meetingRecord"), "keys": .string("space"), "expected": .string("option+m")]).error?.code,
                       "hotkey_not_allowed")
        XCTAssertEqual(set(["hotkey": .string("tool.translate"), "keys": .string("space"), "expected": .null]).error?.code,
                       "hotkey_not_allowed")
        XCTAssertEqual(set(["hotkey": .string("agentClose"), "mode": .string("hold"), "expected": .string("option+q")]).error?.code,
                       "invalid_mode")
        XCTAssertEqual(preferences.configuration, before)
        // Space with a modifier is an ordinary combination, as in the recorder.
        XCTAssertTrue(set(["hotkey": .string("meetingRecord"), "keys": .string("control+space"), "expected": .string("option+m")]).ok)
    }

    /// One physical key = one action. Nothing moves; the answer names the
    /// owner and free keys.
    func test_conflicts_are_refused_and_change_nothing() throws {
        let before = preferences.configuration
        let response = set(["hotkey": .string("dropVoice"), "keys": .string("option+m"), "expected": .string("space")])
        XCTAssertEqual(response.error?.code, "hotkey_conflict")
        let message = try XCTUnwrap(response.error?.message)
        XCTAssertTrue(message.contains("⌥M is already used by Meeting record"), message)
        XCTAssertTrue(message.contains("Nearest free keys: option+shift+m"), message)

        let split = set(["hotkey": .string("agentVoice"), "mode": .string("toggle"), "expected": .string("right_command")])
        XCTAssertEqual(split.error?.code, "hotkey_conflict")
        XCTAssertTrue(split.error?.message.contains("Agent text") == true, "\(split)")
        // Bare ← is Links insert's.
        let arrow = set(["hotkey": .string("dropVoice"), "keys": .string("left"), "expected": .string("space")])
        XCTAssertEqual(arrow.error?.code, "hotkey_conflict")
        XCTAssertTrue(arrow.error?.message.contains("Useful links insert") == true, "\(arrow)")
        XCTAssertEqual(preferences.configuration, before)
    }

    func test_modifier_only_drop_and_reset_to_default() throws {
        let response = set(["hotkey": .string("dropVoice"), "keys": .string("Right Option"), "expected": .string("space")])
        XCTAssertEqual(response.error?.code, "hotkey_conflict")
        XCTAssertTrue(response.error?.message.contains("Google") == true, "\(response)")
        XCTAssertTrue(set(["hotkey": .string("googleText"), "keys": .string("option+g"), "expected": .string("right_option")]).ok)
        XCTAssertTrue(set(["hotkey": .string("googleVoice"), "keys": .string("control+option+g"),
                           "expected": .string("right_option")]).ok)
        let drop = set(["hotkey": .string("dropVoice"), "keys": .string("right_option"), "expected": .string("space")])
        XCTAssertTrue(drop.ok, "\(drop)")
        XCTAssertEqual(preferences.dropVoiceShortcut, .modifier(.rightOption))
        XCTAssertEqual(try rows()["dropVoice"]?["display"], .string("R⌥"))

        let reset = set(["hotkey": .string("dropVoice"), "reset": .bool(true), "expected": .string("right_option")])
        XCTAssertTrue(reset.ok, "\(reset)")
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "reset": .bool(true), "keys": .string("f5"),
                            "expected": .string("space")]).error?.code, "invalid_arguments")
    }

    func test_clearing_only_tools_and_unknown_or_fixed_hotkeys() throws {
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .null, "expected": .string("space")]).error?.code, "not_clearable")
        XCTAssertTrue(set(["hotkey": .string("tool.translate"), "keys": .string("option+t"), "expected": .null]).ok)
        let clear = set(["hotkey": .string("tool.translate"), "keys": .null, "expected": .string("option+t")])
        XCTAssertTrue(clear.ok, "\(clear)")
        XCTAssertNil(preferences.toolShortcuts[.translate])
        XCTAssertEqual(clear.data.object?["bound"], .string("Translate has no hotkey."))
        XCTAssertEqual(clear.data.object?["undo"]?.object?["keys"], .string("option+t"))
        XCTAssertEqual(set(["hotkey": .string("help"), "keys": .string("option+j"), "expected": .string("option+h")]).error?.code,
                       "hotkey_not_allowed")
        XCTAssertEqual(set(["hotkey": .string("dictation"), "keys": .string("f5"), "expected": .null]).error?.code, "unknown_hotkey")
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .string("f5"), "extra": .bool(true),
                            "expected": .string("space")]).error?.code, "invalid_arguments")
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
    }

    func test_wrong_expected_value_changes_nothing() throws {
        let before = preferences.configuration
        let response = set(["hotkey": .string("dropVoice"), "keys": .string("f5"), "expected": .string("`")])
        XCTAssertEqual(response.error?.code, "conflict")
        XCTAssertEqual(preferences.configuration, before)
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "keys": .string("F5"), "expected": .string("space")]).ok)
        XCTAssertEqual(try rows()["dropVoice"]?["keys"], .string("f5"))
    }

    /// Every key spelling the read returns is accepted back as expected.
    func test_keys_round_trip_for_every_recordable_key() {
        for text in ["`", "option+m", "shift+command+d", "f20", "tab", "left", "page down", "forward delete",
                     "control+space", "\\", "right_command", "right_option", "space"] {
            let shortcut = AppControlHotkeys.shortcut(from: text)
            XCTAssertNotNil(shortcut, text)
            XCTAssertEqual(AppControlHotkeys.shortcut(from: AppControlHotkeys.keys(shortcut).string ?? ""), shortcut, text)
        }
        XCTAssertNil(AppControlHotkeys.shortcut(from: "return"))
        XCTAssertNil(AppControlHotkeys.shortcut(from: "command"))
        XCTAssertNil(AppControlHotkeys.shortcut(from: "option+option+m"))
    }

    func test_read_lists_every_hotkey_with_modes_and_defaults() throws {
        let all = try rows()
        for id in AppControlHotkeys.Row.allCases.map(\.rawValue) + HoverTool.allCases.map({ "tool." + $0.rawValue }) + ["help", "answerEscape"] {
            XCTAssertNotNil(all[id], id)
        }
        XCTAssertEqual(all["agentText"]?["keys"], .string("right_command"))
        XCTAssertEqual(all["agentText"]?["mode"], .string("tap"))
        XCTAssertEqual(all["agentVoice"]?["mode"], .string("hold"))
        XCTAssertEqual(all["dropVoice"]?["modes"], .array([.string("hold")]))
        XCTAssertEqual(all["meetingRecord"]?["display"], .string("⌥M"))
        XCTAssertEqual(all["linkInsert"]?["keys"], .string("left"))
        XCTAssertEqual(all["help"]?["canChange"], .bool(false))
        XCTAssertEqual(all["tool.quit"]?["canChange"], .bool(true))
        XCTAssertEqual(all["tool.screenshot"]?["clearable"], .bool(true))
        XCTAssertEqual(all["dropVoice"]?["clearable"], .bool(false))
        let listing = toolbox.handle("hotkeys_get", [:])
        XCTAssertTrue(listing.data.object?["keysAccepted"]?.string?.contains("` (backquote alone)") == true)
        XCTAssertEqual(toolbox.handle("hotkeys_get", ["x": .bool(true)]).error?.code, "invalid_arguments")
    }
}
