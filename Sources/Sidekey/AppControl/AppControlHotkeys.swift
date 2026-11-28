import Carbon.HIToolbox
import Foundation
import WhytapCaseKit

/// Every Whytap hotkey for the application controls: Drop, the Agent, Google
/// search, meeting recording, the answer's link keys, Agent close and every
/// island tool. A change accepts exactly what the Settings recorder accepts
/// for that row and makes the change Settings → Features makes
/// (`FeatureHotkey.assign`, `setGesture`), saved through
/// `HotkeyPreferences.apply`, the Hotkeys Save path: one conflict check,
/// persistence, and the monitors re-register because they observe those
/// published preferences. There is no rule here that Settings does not have;
/// a mistaken request is made cheap instead: the reply says what is bound now,
/// what it replaced (`undo`) and what the key no longer does elsewhere.
// WHY: .project-docs/decisions/2026-11-28-agent-all-hotkeys.md
@MainActor
struct AppControlHotkeys {
    let hotkeys: () -> HotkeyPreferences

    /// The Settings → Hotkeys rows above Tools, in their order there.
    enum Row: String, CaseIterable {
        case dropVoice, agentText, agentVoice, googleText, googleVoice, meetingRecord
        case linkInsert, linkOpen, linkNext, linkPrevious, agentClose

        var feature: FeatureHotkey {
            switch self {
            case .dropVoice: return .dropVoice
            case .agentText: return .agentText
            case .agentVoice: return .agentVoice
            case .googleText: return .googleText
            case .googleVoice: return .googleVoice
            case .meetingRecord: return .meetingRecord
            case .linkInsert: return .agentLinkInsert
            case .linkOpen: return .agentLinkOpen
            case .linkNext: return .agentLinkNext
            case .linkPrevious: return .agentLinkPrevious
            case .agentClose: return .agentClose
            }
        }

        /// The row's title in Settings → Hotkeys.
        var title: String {
            switch self {
            case .dropVoice: return "Drop voice"
            case .agentText: return "Agent text"
            case .agentVoice: return "Agent voice"
            case .googleText: return "Google text"
            case .googleVoice: return "Google voice"
            case .meetingRecord: return "Meeting record"
            case .linkInsert: return "Links insert"
            case .linkOpen: return "Links open"
            case .linkNext: return "Links next"
            case .linkPrevious: return "Links previous"
            case .agentClose: return "Agent close"
            }
        }
    }

    /// One changeable hotkey: a Settings row or a tool's shortcut.
    @MainActor
    enum Target: Equatable {
        case row(Row)
        case tool(HoverTool)

        init?(id: String) {
            if id.hasPrefix(AppControlHotkeys.toolPrefix) {
                guard let tool = HoverTool(rawValue: String(id.dropFirst(AppControlHotkeys.toolPrefix.count))) else { return nil }
                self = .tool(tool)
            } else if let row = Row(rawValue: id) {
                self = .row(row)
            } else {
                return nil
            }
        }

        var id: String {
            switch self {
            case .row(let row): return row.rawValue
            case .tool(let tool): return AppControlHotkeys.toolPrefix + tool.rawValue
            }
        }

        var feature: FeatureHotkey {
            switch self {
            case .row(let row): return row.feature
            case .tool(let tool): return .tool(tool)
            }
        }

        var title: String {
            switch self {
            case .row(let row): return row.title
            case .tool(let tool): return AppControlToolbox.title(tool)
            }
        }

        /// The action's name in `HotkeyConfiguration.assignments`, the name a
        /// conflict reports.
        var conflictTitle: String {
            switch self {
            case .row(.linkInsert): return "Useful links insert"
            case .row(.linkOpen): return "Useful links open"
            case .row(.linkNext): return "Useful links next"
            case .row(.linkPrevious): return "Useful links previous"
            case .row(let row): return row.title
            case .tool(let tool): return HoverToolRegistry.info(for: tool).title
            }
        }

        /// Settings has a clear button on tool rows only.
        var clearable: Bool { if case .tool = self { return true }; return false }

        /// Agent close and the link keys are taken only while an Agent answer
        /// (with links) is on screen.
        var whileAnswerShown: Bool {
            switch self {
            case .row(.agentClose), .row(.linkInsert), .row(.linkOpen), .row(.linkNext), .row(.linkPrevious): return true
            default: return false
            }
        }
    }

    static let toolPrefix = "tool."

    /// Keys Whytap owns that no screen can change. Keys that work only inside
    /// one Whytap window (screenshot editor, Case prompt, History) are not
    /// hotkeys of the Mac and are not listed.
    private static let fixed: [(id: String, title: String, does: String, keys: String, display: String)] = [
        ("help", "Help", "Open the Help window", "option+h", "⌥H"),
        ("answerEscape", "Close", "The first Escape closes the visible Agent answer", "escape", "Esc")
    ]

    static let keysRule = "Any key Settings → Hotkeys can record: modifiers (control, option, shift, command, in any combination or none) then one key joined by +: option+m, command+shift+d, f5, ` (backquote alone), tab, left; or right_command / right_option alone; or space alone (Drop voice only, hold only). Escape and Return cannot be recorded."

    // MARK: Read

    func list(_ args: [String: AppControlValue]) -> AppControlResponse {
        guard args.isEmpty else { return Self.invalid() }
        let configuration = hotkeys().configuration
        var rows = Row.allCases.map { Self.value(.row($0), configuration) }
        rows += HoverTool.allCases.map { Self.value(.tool($0), configuration) }
        rows += Self.fixed.map { entry in
            .object(["id": .string(entry.id), "title": .string(entry.title), "does": .string(entry.does),
                     "keys": .string(entry.keys), "display": .string(entry.display), "mode": .string("tap"),
                     "modes": .array([.string("tap")]), "canChange": .bool(false), "clearable": .bool(false),
                     "default": .object(["keys": .string(entry.keys), "display": .string(entry.display), "mode": .string("tap")]),
                     "note": .string("Fixed: no screen changes it.")])
        }
        return .success(.object(["hotkeys": .array(rows), "keysAccepted": .string(Self.keysRule)]))
    }

    static func value(_ target: Target, _ configuration: HotkeyConfiguration) -> AppControlValue {
        let feature = target.feature
        let shortcut = feature.shortcut(in: configuration)
        var value: [String: AppControlValue] = [
            "id": .string(target.id), "title": .string(target.title), "does": .string(doesText(target)),
            "keys": keys(shortcut), "display": display(shortcut),
            "mode": .string(mode(feature.gesture(in: configuration), voice: feature.isVoice)),
            "modes": .array(modes(feature, configuration).map(AppControlValue.string)),
            "canChange": .bool(true), "clearable": .bool(target.clearable),
            "default": defaultValue(target)
        ]
        if case .tool(let tool) = target { value["tool"] = .string(tool.rawValue) }
        if let note = note(target, configuration) { value["note"] = .string(note) }
        return .object(value)
    }

    private static func doesText(_ target: Target) -> String {
        if case .tool(let tool) = target { return HoverToolRegistry.info(for: tool).description }
        return target.feature.label
    }

    private static func note(_ target: Target, _ configuration: HotkeyConfiguration) -> String? {
        switch target {
        case .row(.dropVoice) where configuration.dropVoiceShortcut == .holdSpace:
            return "Space is hold-only: a tap of Space is typing a space."
        case .tool(let tool) where tool.isComingSoon:
            return "Coming soon: a shortcut saved for it stays inactive until it ships."
        case .tool(.quit):
            return "A press quits Whytap, ending a dictation or recording in progress."
        default:
            return nil
        }
    }

    private static func defaultValue(_ target: Target) -> AppControlValue {
        guard case .row(let row) = target else {
            return .object(["keys": .null, "display": .null, "mode": .string("tap")])
        }
        let defaults = HotkeyConfiguration.defaults
        let shortcut = row.feature.shortcut(in: defaults)
        return .object(["keys": keys(shortcut), "display": display(shortcut),
                        "mode": .string(mode(row.feature.gesture(in: defaults), voice: row.feature.isVoice))])
    }

    /// `hold` / `toggle` for voice rows (Settings says Hold / Toggle), `tap`
    /// for one-shot actions.
    static func mode(_ gesture: HotkeyGesture, voice: Bool) -> String {
        guard voice else { return "tap" }
        return gesture == .hold ? "hold" : "toggle"
    }

    private static func modes(_ feature: FeatureHotkey, _ configuration: HotkeyConfiguration) -> [String] {
        guard feature.isVoice else { return ["tap"] }
        return feature.allowsGestureSwitch(in: configuration) ? ["hold", "toggle"] : ["hold"]
    }

    // MARK: Write

    /// `whytap_hotkey_set` with `hotkey`: keys and/or mode of one hotkey,
    /// `keys: null` for a tool, or `reset`.
    func set(_ args: [String: AppControlValue]) -> AppControlResponse {
        guard Set(args.keys).isSubset(of: ["hotkey", "keys", "mode", "reset", "expected"]),
              let id = args["hotkey"]?.string,
              let expected = args["expected"], expected == .null || expected.string != nil,
              args["keys"] == nil || args["keys"] == .null || args["keys"]?.string != nil,
              args["mode"] == nil || args["mode"]?.string != nil,
              args["reset"] == nil || args["reset"]?.bool != nil else { return Self.invalid() }
        let reset = args["reset"]?.bool ?? false
        if reset, args["keys"] != nil || args["mode"] != nil {
            return .failure("invalid_arguments", "reset restores both keys and mode; send it without keys or mode.")
        }
        if let entry = Self.fixed.first(where: { $0.id == id }) {
            return .failure("hotkey_not_allowed", "\(entry.title) (\(entry.display)) is fixed in Whytap; nothing can change it.")
        }
        guard let target = Target(id: id) else {
            return .failure("unknown_hotkey", "Unknown hotkey. Use an id from whytap_hotkeys_get.")
        }
        guard reset || args["keys"] != nil || args["mode"] != nil else {
            return .failure("invalid_arguments", "Send keys, mode, or reset true.")
        }
        if args["keys"] == .null, !target.clearable {
            return .failure("not_clearable", "\(target.title) always has keys, as in Settings; it cannot be cleared. Omit keys to keep them, send other keys, or reset true for the default.")
        }
        let preferences = hotkeys()
        let current = preferences.configuration
        let feature = target.feature
        guard Self.sameKeys(expected, feature.shortcut(in: current)) else {
            return .failure("conflict", "The current keys changed. Read whytap_hotkeys_get again before deciding whether to retry.")
        }
        var candidate = current
        if reset {
            switch target {
            case .row:
                let defaults = HotkeyConfiguration.defaults
                if let shortcut = feature.shortcut(in: defaults) { feature.assign(shortcut, in: &candidate) }
                if feature.isVoice { feature.setGesture(feature.gesture(in: defaults), in: &candidate) }
            case .tool(let tool):
                candidate.toolShortcuts[tool] = nil
            }
        }
        if case .tool(let tool) = target, args["keys"] == .null { candidate.toolShortcuts[tool] = nil }
        if let text = args["keys"]?.string {
            guard let shortcut = Self.shortcut(from: text) else {
                return .failure("invalid_hotkey", "Settings cannot record “\(text.prefix(64))”. " + Self.keysRule)
            }
            // The Settings gate: bare Space is Drop's alone (the recorder's
            // hold-Space result is ignored on every other row).
            guard feature.assign(shortcut, in: &candidate) else {
                return .failure("hotkey_not_allowed", "Space alone is Drop voice's (hold Space to dictate); \(target.title) cannot use it, as in Settings. Space with a modifier (option+space) is a normal combination.")
            }
        }
        if let text = args["mode"]?.string {
            guard let gesture = Self.gesture(from: text, voice: feature.isVoice) else {
                return .failure("invalid_mode", feature.isVoice
                    ? "\(target.title) takes mode hold or toggle."
                    : "\(target.title) is a single press (tap); it has no Hold or Toggle.")
            }
            if feature.isVoice {
                guard feature.allowsGestureSwitch(in: candidate) || gesture == .hold else {
                    return .failure("invalid_mode", "Space is hold-only: a tap of Space is typing a space, so Toggle is not possible on Space. Choose other keys for Toggle.")
                }
                feature.setGesture(gesture, in: &candidate)
            }
        }
        return save(target, candidate, from: current, keysText: args["keys"]?.string, into: preferences)
    }

    private func save(_ target: Target, _ candidate: HotkeyConfiguration, from current: HotkeyConfiguration,
                      keysText: String?, into preferences: HotkeyPreferences) -> AppControlResponse {
        let feature = target.feature
        guard candidate != current else { return reply(target, preferences, previous: current, changed: false) }
        let conflicts = candidate.conflicts
        guard conflicts.isEmpty else {
            let own = conflicts.filter { $0.actionTitles.contains(target.conflictTitle) }
            let owners = (own.isEmpty ? conflicts : own).flatMap(\.actionTitles).filter { $0 != target.conflictTitle }
            let keys = feature.shortcut(in: candidate).map(AppControlToolbox.display) ?? ""
            let used = owners.isEmpty ? "Another shortcut conflicts" : "\(keys) is already used by \(Self.list(owners))"
            return .failure("hotkey_conflict", "\(used). Nothing changed. Choose other keys, or change the other action first if the user asks."
                + Self.suggestion(nearest: keysText ?? "", target: target, in: candidate))
        }
        do { try preferences.apply(candidate) } catch {
            return .failure("hotkey_conflict", "The hotkeys could not be saved: they conflict. Nothing changed.")
        }
        // Confirm from the saved preferences, not from the request.
        let saved = preferences.configuration
        guard feature.shortcut(in: saved) == feature.shortcut(in: candidate),
              feature.gesture(in: saved) == feature.gesture(in: candidate) else {
            return .failure("unconfirmed", "The saved hotkeys do not contain the change.")
        }
        return reply(target, preferences, previous: current, changed: true)
    }

    private func reply(_ target: Target, _ preferences: HotkeyPreferences, previous: HotkeyConfiguration,
                       changed: Bool) -> AppControlResponse {
        let configuration = preferences.configuration
        let feature = target.feature
        let shortcut = feature.shortcut(in: configuration)
        let gesture = feature.gesture(in: configuration)
        let before = feature.shortcut(in: previous)
        let beforeMode = Self.mode(feature.gesture(in: previous), voice: feature.isVoice)
        var reply: [String: AppControlValue] = [
            "hotkey": Self.value(target, configuration), "title": .string(target.title),
            "keys": AppControlToolbox.hotkeyValue(shortcut).replacingKeys(Self.keys(shortcut)),
            "mode": .string(Self.mode(gesture, voice: feature.isVoice)),
            "voice": .bool(feature.isVoice), "changed": .bool(changed),
            "bound": .string(Self.bound(target, shortcut, gesture)),
            "previous": .object(["keys": Self.keys(before), "display": Self.display(before), "mode": .string(beforeMode)])
        ]
        if changed {
            var undo: [String: AppControlValue] = ["hotkey": .string(target.id), "keys": Self.keys(before),
                                                   "expected": Self.keys(shortcut)]
            if feature.isVoice { undo["mode"] = .string(beforeMode) }
            reply["undo"] = .object(undo)
        }
        if let shortcut, let effect = Self.effect(target, shortcut, gesture) { reply["takenEverywhere"] = .string(effect) }
        if case .combo(let combo)? = shortcut, let typed = AppControlToolbox.keyboardCharacter(combo) {
            reply["typesInTextFields"] = .string(typed)
        }
        return .success(.object(reply))
    }

    /// "Drop voice is now hold ` (it was hold Space)." style first half.
    static func bound(_ target: Target, _ shortcut: HotkeyShortcut?, _ gesture: HotkeyGesture) -> String {
        guard let shortcut else { return "\(target.title) has no hotkey." }
        let keys = AppControlToolbox.display(shortcut)
        guard target.feature.isVoice else { return "\(target.title) is \(keys)." }
        return "\(target.title) is \(mode(gesture, voice: true) == "hold" ? "Hold" : "Toggle") \(keys)."
    }

    /// What the new keys stop doing elsewhere, for keys a person types or
    /// apps commonly use. nil when nothing outside Whytap changes.
    static func effect(_ target: Target, _ shortcut: HotkeyShortcut, _ gesture: HotkeyGesture) -> String? {
        guard case .combo(let combo) = shortcut else { return nil }
        let display = AppControlToolbox.display(shortcut)
        let scope = target.whileAnswerShown ? "while an Agent answer is on screen" : "in every app"
        let control = UInt32(controlKey), option = UInt32(optionKey), shift = UInt32(shiftKey), command = UInt32(cmdKey)
        let typed = typedKeyName(combo)
        if combo.modifiers == 0 {
            if target == .row(.dropVoice), gesture == .hold {
                guard let typed else { return nil }
                return "A quick press of \(display) still types \(typed); holding it about 0.3 s in a text field starts dictation and erases the typed \(typed)."
            }
            if let typed { return "\(display) is now taken by Whytap \(scope): it no longer types \(typed) there." }
            switch Int(combo.keyCode) {
            case kVK_Tab, kVK_Delete, kVK_ForwardDelete:
                return "\(display) is now taken by Whytap \(scope): it no longer works as \(combo.keyTitle) there."
            default:
                return "\(display) is now taken by Whytap \(scope): other apps no longer receive it."
            }
        }
        if combo.modifiers == shift, let typed {
            return "\(display) is now taken by Whytap \(scope): it no longer types the shifted \(typed) there."
        }
        if combo.modifiers & command != 0, combo.modifiers & (control | option) == 0 {
            return "\(display) is now taken by Whytap \(scope): apps or macOS that use \(display) no longer get it."
        }
        return nil
    }

    /// "`" for a key that types a character, nil for F-keys, arrows and the like.
    private static func typedKeyName(_ combo: HotkeyTapCombo) -> String? {
        let title = combo.keyTitle
        guard title.count == 1, !"←→↑↓".contains(title) else { return nil }
        return "“\(combo.modifiers & UInt32(shiftKey) == 0 ? title.lowercased() : title)”"
    }

    // MARK: Keys

    static func gesture(from text: String, voice: Bool) -> HotkeyGesture? {
        switch text.lowercased() {
        case "hold": return voice ? .hold : nil
        case "toggle": return voice ? .tap : nil
        case "tap": return .tap
        default: return nil
        }
    }

    /// The keys a model writes for what the Settings recorder would record:
    /// modifiers (any, or none) then one key, `right_command` /
    /// `right_option` alone, or `space` alone (hold-Space, Drop's).
    static func shortcut(from text: String) -> HotkeyShortcut? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty, lowered.count <= 64 else { return nil }
        let squashed = lowered.filter { !" _-+".contains($0) }
        if ["rightcommand", "rightcmd", "r⌘", "right⌘"].contains(squashed) { return .modifier(.rightCommand) }
        if ["rightoption", "rightopt", "rightalt", "r⌥", "right⌥"].contains(squashed) { return .modifier(.rightOption) }
        // "+" separates; spaces separate modifier words too ("option m"),
        // and the rest is the key's name ("page up", "forward delete").
        let words = lowered.split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init)
        guard !words.isEmpty else { return nil }
        var modifiers: UInt32 = 0, index = 0
        while index < words.count - 1, let mask = modifierMask(words[index]) {
            guard modifiers & mask == 0 else { return nil }
            modifiers |= mask
            index += 1
        }
        let keyName = words[index...].joined()
        guard let key = keyTable[keyName] else { return nil }
        if key.code == kVK_Space, modifiers == 0 { return .holdSpace }
        return .combo(HotkeyTapCombo(keyCode: UInt32(key.code), modifiers: modifiers, keyTitle: key.title))
    }

    private static func modifierMask(_ word: String) -> UInt32? {
        switch word {
        case "ctrl", "control", "⌃": return UInt32(controlKey)
        case "opt", "option", "alt", "⌥": return UInt32(optionKey)
        case "shift", "⇧": return UInt32(shiftKey)
        case "cmd", "command", "⌘": return UInt32(cmdKey)
        default: return nil
        }
    }

    /// The `keys` form of a shortcut, readable back by `shortcut(from:)`.
    static func keys(_ shortcut: HotkeyShortcut?) -> AppControlValue {
        switch shortcut {
        case nil: return .null
        case .holdSpace?: return .string("space")
        case .modifier(.rightCommand)?: return .string("right_command")
        case .modifier(.rightOption)?: return .string("right_option")
        case .combo(let combo)?:
            let masks: [(Int, String)] = [(controlKey, "control"), (optionKey, "option"), (shiftKey, "shift"), (cmdKey, "command")]
            let names = masks.filter { combo.modifiers & UInt32($0.0) != 0 }.map(\.1)
            let key = keyNames[Int(combo.keyCode)] ?? combo.keyTitle.lowercased().replacingOccurrences(of: " ", with: "")
            return .string((names + [key]).joined(separator: "+"))
        }
    }

    static func display(_ shortcut: HotkeyShortcut?) -> AppControlValue {
        shortcut.map { .string(AppControlToolbox.display($0)) } ?? .null
    }

    /// Every key the recorder titles (`HotkeyTapCombo.keyTitle(for:event:)`):
    /// US letters, digits and punctuation, F1–F20, Space, Tab, Delete,
    /// Forward Delete, Home, End, Page Up/Down and the arrows. The first
    /// spelling of each is the one `keys` writes.
    private static let keySpellings: [(names: [String], code: Int, title: String)] = {
        var list: [(names: [String], code: Int, title: String)] = []
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                       kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                       kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (offset, code) in letters.enumerated() {
            let title = String(UnicodeScalar(UInt8(ascii: "A") + UInt8(offset)))
            list.append(([title.lowercased()], code, title))
        }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (offset, code) in digits.enumerated() { list.append(([String(offset)], code, String(offset))) }
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (offset, code) in functions.enumerated() { list.append((["f\(offset + 1)"], code, "F\(offset + 1)")) }
        list += [
            (["`", "backquote", "backtick", "grave"], kVK_ANSI_Grave, "`"), (["-", "minus"], kVK_ANSI_Minus, "-"),
            (["=", "equal", "equals"], kVK_ANSI_Equal, "="), (["[", "leftbracket"], kVK_ANSI_LeftBracket, "["),
            (["]", "rightbracket"], kVK_ANSI_RightBracket, "]"), (["\\", "backslash"], kVK_ANSI_Backslash, "\\"),
            ([";", "semicolon"], kVK_ANSI_Semicolon, ";"), (["'", "quote"], kVK_ANSI_Quote, "'"),
            ([",", "comma"], kVK_ANSI_Comma, ","), ([".", "period"], kVK_ANSI_Period, "."),
            (["/", "slash"], kVK_ANSI_Slash, "/"), (["space", "spacebar"], kVK_Space, "Space"),
            (["tab"], kVK_Tab, "Tab"), (["delete", "backspace"], kVK_Delete, "Delete"),
            (["forwarddelete"], kVK_ForwardDelete, "Forward Delete"), (["home"], kVK_Home, "Home"),
            (["end"], kVK_End, "End"), (["pageup"], kVK_PageUp, "Page Up"), (["pagedown"], kVK_PageDown, "Page Down"),
            (["left", "leftarrow", "←"], kVK_LeftArrow, "←"), (["right", "rightarrow", "→"], kVK_RightArrow, "→"),
            (["up", "uparrow", "↑"], kVK_UpArrow, "↑"), (["down", "downarrow", "↓"], kVK_DownArrow, "↓")
        ]
        return list
    }()

    private static let keyTable: [String: (code: Int, title: String)] = {
        var table: [String: (code: Int, title: String)] = [:]
        for key in keySpellings { for name in key.names { table[name] = (key.code, key.title) } }
        return table
    }()

    private static let keyNames: [Int: String] = Dictionary(keySpellings.map { ($0.code, $0.names[0]) },
                                                             uniquingKeysWith: { first, _ in first })

    /// The nearest combination nothing else uses: the same key with ⌥, ⌥⇧,
    /// ⌃⌥, ⌃⇧ or ⌃. "" when there is none.
    static func suggestion(nearest text: String, target: Target, in configuration: HotkeyConfiguration) -> String {
        guard case .combo(let wanted)? = shortcut(from: text) else { return "" }
        let masks: [UInt32] = [UInt32(optionKey), UInt32(optionKey | shiftKey), UInt32(controlKey | optionKey),
                               UInt32(controlKey | shiftKey), UInt32(controlKey)]
        for modifiers in masks where modifiers != wanted.modifiers {
            let combo = HotkeyTapCombo(keyCode: wanted.keyCode, modifiers: modifiers, keyTitle: wanted.keyTitle)
            var candidate = configuration
            target.feature.assign(.combo(combo), in: &candidate)
            guard candidate.conflicts.allSatisfy({ !$0.actionTitles.contains(target.conflictTitle) }) else { continue }
            return " Nearest free keys: \(keys(.combo(combo)).string ?? "") (\(AppControlToolbox.display(.combo(combo))))."
        }
        return ""
    }

    /// Same keys in any modifier order or spelling.
    static func sameKeys(_ expected: AppControlValue, _ current: HotkeyShortcut?) -> Bool {
        guard let wanted = expected.string else { return expected == .null && current == nil }
        guard let current else { return false }
        return shortcut(from: wanted) == current
    }

    private static func list(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique.joined(separator: " and ")
    }

    private static func invalid() -> AppControlResponse {
        .failure("invalid_arguments", "Use the documented hotkey, keys, mode, reset and expected argument types; unknown fields are rejected.")
    }
}

private extension AppControlValue {
    /// A `{keys, display}` value with `keys` in this file's spelling.
    func replacingKeys(_ keys: AppControlValue) -> AppControlValue {
        guard var object = self.object else { return self }
        object["keys"] = keys
        return .object(object)
    }
}
