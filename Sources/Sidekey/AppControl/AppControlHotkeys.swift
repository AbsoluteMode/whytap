import Foundation
import WhytapCaseKit

/// Every Whytap hotkey for the application controls: Drop, the Agent, Google
/// search, meeting recording, the answer's link keys and Agent close, plus
/// the island tools (their writes stay in `AppControlToolbox`). A change is
/// the one Settings → Features makes for that row (`FeatureHotkey.assign`,
/// `setGesture`) saved through `HotkeyPreferences.apply`, the Hotkeys Save
/// path: one conflict check, persistence, and the monitors re-register
/// because they observe those published preferences.
// WHY: .project-docs/decisions/2026-11-28-agent-all-hotkeys.md
@MainActor
struct AppControlHotkeys {
    let hotkeys: () -> HotkeyPreferences

    /// The Settings → Hotkeys rows, in their order there. `conflictTitle` is
    /// the action's name in `HotkeyConfiguration.assignments`, the name a
    /// conflict reports.
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

        var conflictTitle: String {
            switch self {
            case .linkInsert: return "Useful links insert"
            case .linkOpen: return "Useful links open"
            case .linkNext: return "Useful links next"
            case .linkPrevious: return "Useful links previous"
            default: return title
            }
        }
    }

    static let toolPrefix = "tool."

    /// Keys Whytap owns that no screen can change. Keys that work only inside
    /// one Whytap window (screenshot editor, Case prompt, History) are not hotkeys
    /// of the Mac and are not listed.
    private static let fixed: [(id: String, title: String, does: String, keys: String, display: String)] = [
        ("help", "Help", "Open the Help window", "option+h", "⌥H"),
        ("answerEscape", "Close", "The first Escape closes the visible Agent answer", "escape", "Esc")
    ]

    // MARK: Read

    func list(_ args: [String: AppControlValue]) -> AppControlResponse {
        guard args.isEmpty else { return Self.invalid() }
        let configuration = hotkeys().configuration
        var rows = Row.allCases.map { Self.rowValue($0, configuration) }
        rows += HoverTool.allCases.map { Self.toolValue($0, configuration) }
        rows += Self.fixed.map { entry in
            .object(["id": .string(entry.id), "title": .string(entry.title), "does": .string(entry.does),
                     "keys": .string(entry.keys), "display": .string(entry.display), "mode": .string("tap"),
                     "modes": .array([.string("tap")]), "changeable": .bool(false), "clearable": .bool(false),
                     "default": .object(["keys": .string(entry.keys), "display": .string(entry.display), "mode": .string("tap")]),
                     "note": .string("Fixed: no screen changes it.")])
        }
        return .success(.object(["hotkeys": .array(rows)]))
    }

    static func rowValue(_ row: Row, _ configuration: HotkeyConfiguration) -> AppControlValue {
        let feature = row.feature
        let shortcut = feature.shortcut(in: configuration)
        let defaults = HotkeyConfiguration.defaults
        var value: [String: AppControlValue] = [
            "id": .string(row.rawValue), "title": .string(row.title), "does": .string(feature.label),
            "keys": AppControlToolbox.keysValue(shortcut),
            "display": shortcut.map { .string(AppControlToolbox.display($0)) } ?? .null,
            "mode": .string(mode(feature.gesture(in: configuration), voice: feature.isVoice)),
            "modes": .array(modes(feature, configuration).map(AppControlValue.string)),
            "changeable": .bool(true), "clearable": .bool(false),
            "default": defaultValue(row, defaults)
        ]
        if row == .dropVoice, shortcut == .holdSpace {
            value["note"] = .string("Space is hold-only: a tap of Space is typing a space.")
        }
        return .object(value)
    }

    private static func defaultValue(_ row: Row, _ defaults: HotkeyConfiguration) -> AppControlValue {
        let shortcut = row.feature.shortcut(in: defaults)
        return .object(["keys": AppControlToolbox.keysValue(shortcut),
                        "display": shortcut.map { .string(AppControlToolbox.display($0)) } ?? .null,
                        "mode": .string(mode(row.feature.gesture(in: defaults), voice: row.feature.isVoice))])
    }

    private static func toolValue(_ tool: HoverTool, _ configuration: HotkeyConfiguration) -> AppControlValue {
        let shortcut = configuration.toolShortcuts[tool]
        let assignable = WhytapLink.acceptsLinkHotkey(tool)
        var value: [String: AppControlValue] = [
            "id": .string(toolPrefix + tool.rawValue), "tool": .string(tool.rawValue),
            "title": .string(AppControlToolbox.title(tool)), "does": .string(HoverToolRegistry.info(for: tool).description),
            "keys": AppControlToolbox.keysValue(shortcut),
            "display": shortcut.map { .string(AppControlToolbox.display($0)) } ?? .null,
            "mode": .string("tap"), "modes": .array([.string("tap")]),
            "changeable": .bool(assignable), "clearable": .bool(assignable),
            "default": .object(["keys": .null, "display": .null, "mode": .string("tap")])
        ]
        if !assignable {
            value["note"] = .string(tool.isComingSoon ? "Coming soon: it cannot get a hotkey yet."
                : "Only Settings → Hotkeys sets it: a stray press would end a dictation or recording.")
        }
        return .object(value)
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

    /// `whytap_hotkey_set` with `hotkey`: keys and/or mode of one row, or
    /// `reset`. A `tool.<id>` hotkey goes to the island-tool path unchanged.
    func set(_ args: [String: AppControlValue],
             tool assignTool: ([String: AppControlValue]) -> AppControlResponse) -> AppControlResponse {
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
        if id.hasPrefix(Self.toolPrefix) {
            guard args["mode"] == nil || args["mode"] == .string("tap") else {
                return .failure("invalid_mode", "Tool hotkeys are a single press (tap); they have no Hold or Toggle.")
            }
            guard reset || args["keys"] != nil else { return Self.invalid() }
            return assignTool(["tool": .string(String(id.dropFirst(Self.toolPrefix.count))),
                               "keys": reset ? .null : args["keys"]!, "expected": expected])
        }
        if let entry = Self.fixed.first(where: { $0.id == id }) {
            return .failure("hotkey_not_allowed", "\(entry.title) (\(entry.display)) is fixed in Whytap; nothing can change it.")
        }
        guard let row = Row(rawValue: id) else {
            return .failure("unknown_hotkey", "Unknown hotkey. Use an id from whytap_hotkeys_get.")
        }
        guard reset || args["keys"] != nil || args["mode"] != nil else {
            return .failure("invalid_arguments", "Send keys, mode, or reset true.")
        }
        if args["keys"] == .null {
            return .failure("not_clearable", "\(row.title) always has keys; it cannot be cleared. Omit keys to keep them, send other keys, or reset true for the default.")
        }
        let preferences = hotkeys()
        let current = preferences.configuration
        let feature = row.feature
        guard Self.sameKeys(expected, AppControlToolbox.keysValue(feature.shortcut(in: current))) else {
            return .failure("conflict", "The current keys changed. Read whytap_hotkeys_get again before deciding whether to retry.")
        }
        var candidate = current
        if reset {
            let defaults = HotkeyConfiguration.defaults
            if let shortcut = feature.shortcut(in: defaults) { feature.assign(shortcut, in: &candidate) }
            if feature.isVoice { feature.setGesture(feature.gesture(in: defaults), in: &candidate) }
        }
        if let text = args["keys"]?.string {
            switch Self.shortcut(from: text, for: row, in: current) {
            case .success(let shortcut): feature.assign(shortcut, in: &candidate)
            case .failure(let refusal): return refusal.response
            }
        }
        if let text = args["mode"]?.string {
            guard let gesture = Self.gesture(from: text, voice: feature.isVoice) else {
                return .failure("invalid_mode", feature.isVoice
                    ? "\(row.title) takes mode hold or toggle."
                    : "\(row.title) is a single press (tap); it has no Hold or Toggle.")
            }
            if feature.isVoice {
                guard feature.allowsGestureSwitch(in: candidate) || gesture == .hold else {
                    return .failure("invalid_mode", "Space is hold-only: a tap of Space is typing a space, so Toggle is not possible on Space. Choose other keys for Toggle.")
                }
                feature.setGesture(gesture, in: &candidate)
            }
        }
        return save(row, candidate, from: current, keysText: args["keys"]?.string, into: preferences)
    }

    private func save(_ row: Row, _ candidate: HotkeyConfiguration, from current: HotkeyConfiguration,
                      keysText: String?, into preferences: HotkeyPreferences) -> AppControlResponse {
        let feature = row.feature
        let previous: AppControlValue = .object([
            "keys": AppControlToolbox.keysValue(feature.shortcut(in: current)),
            "mode": .string(Self.mode(feature.gesture(in: current), voice: feature.isVoice))])
        guard candidate != current else { return reply(row, preferences, previous: previous, changed: false) }
        let conflicts = candidate.conflicts
        guard conflicts.isEmpty else {
            let own = conflicts.filter { $0.actionTitles.contains(row.conflictTitle) }
            let owners = (own.isEmpty ? conflicts : own).flatMap(\.actionTitles).filter { $0 != row.conflictTitle }
            let keys = feature.shortcut(in: candidate).map(AppControlToolbox.display) ?? ""
            let used = owners.isEmpty ? "Another shortcut conflicts" : "\(keys) is already used by \(Self.list(owners))"
            return .failure("hotkey_conflict", "\(used). Nothing changed. Choose other keys, or change the other action first if the user asks."
                + Self.suggestion(nearest: keysText ?? "", row: row, in: candidate))
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
        return reply(row, preferences, previous: previous, changed: true)
    }

    private func reply(_ row: Row, _ preferences: HotkeyPreferences, previous: AppControlValue,
                       changed: Bool) -> AppControlResponse {
        let configuration = preferences.configuration
        let shortcut = row.feature.shortcut(in: configuration)
        var reply: [String: AppControlValue] = [
            "hotkey": Self.rowValue(row, configuration), "title": .string(row.title),
            "keys": AppControlToolbox.hotkeyValue(shortcut),
            "mode": .string(Self.mode(row.feature.gesture(in: configuration), voice: row.feature.isVoice)),
            "voice": .bool(row.feature.isVoice), "previous": previous, "changed": .bool(changed)
        ]
        if case .combo(let combo)? = shortcut, let typed = AppControlToolbox.keyboardCharacter(combo) {
            reply["typesInTextFields"] = .string(typed)
        }
        return .success(.object(reply))
    }

    // MARK: Keys

    struct Refusal: Error {
        let code: String, message: String
        var response: AppControlResponse { .failure(code, message) }
    }

    static func gesture(from text: String, voice: Bool) -> HotkeyGesture? {
        switch text.lowercased() {
        case "hold": return voice ? .hold : nil
        case "toggle": return voice ? .tap : nil
        case "tap": return voice ? .tap : .tap
        default: return nil
        }
    }

    /// Keys a model may write for a Settings row: `space` (Drop only, hold),
    /// `right_command` / `right_option` alone, a combo with Control or Option
    /// (`option+m`, `control+command+d`) or a bare F1–F20. Command or Shift
    /// alone and bare typing keys stay with the Settings recorder: a misread
    /// request must not take ⌘C or a letter from every app.
    static func shortcut(from text: String, for row: Row,
                         in configuration: HotkeyConfiguration) -> Result<HotkeyShortcut, Refusal> {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        let squashed = lowered.filter { !" _-+".contains($0) }
        guard lowered.count <= 64 else { return .failure(invalidKeys(text, row, configuration)) }
        if ["space", "holdspace", "spacebar"].contains(squashed) {
            guard row == .dropVoice else {
                return .failure(Refusal(code: "hotkey_not_allowed",
                                        message: "Bare Space is Drop's alone (hold Space to dictate); \(row.title) cannot use it."))
            }
            return .success(.holdSpace)
        }
        if ["rightcommand", "rightcmd", "r⌘", "right⌘"].contains(squashed) { return .success(.modifier(.rightCommand)) }
        if ["rightoption", "rightopt", "rightalt", "r⌥", "right⌥"].contains(squashed) { return .success(.modifier(.rightOption)) }
        if let combo = WhytapLink.linkCombo(from: lowered) { return .success(.combo(combo)) }
        if lowered.range(of: #"^f([1-9]|1[0-9]|20)$"#, options: .regularExpression) != nil,
           let combo = WhytapLink.linkCombo(from: "option+" + lowered) {
            return .success(.combo(HotkeyTapCombo(keyCode: combo.keyCode, modifiers: 0, keyTitle: combo.keyTitle)))
        }
        return .failure(invalidKeys(text, row, configuration))
    }

    private static func invalidKeys(_ text: String, _ row: Row, _ configuration: HotkeyConfiguration) -> Refusal {
        Refusal(code: "invalid_hotkey",
                message: "Write keys as modifiers then one key joined by +, with Control or Option: option+m, control+command+d, control+shift+f5 (A–Z, 0–9, F1–F20, US punctuation); or a bare F1–F20; or right_command / right_option alone"
                    + (row == .dropVoice ? "; or space (hold Space)" : "")
                    + ". Command or Shift alone and bare typing keys are not accepted here, so app and system shortcuts and typing stay free; the user can record any key in Settings → Hotkeys."
                    + suggestion(nearest: text, row: row, in: configuration))
    }

    /// The nearest combo the rules accept that nothing else uses: the same
    /// key with ⌥, ⌥⇧, ⌃⌥, ⌃⇧ or ⌃. "" when there is none.
    static func suggestion(nearest text: String, row: Row, in configuration: HotkeyConfiguration) -> String {
        guard let key = text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).last.map(String.init) else { return "" }
        let wanted = WhytapLink.linkCombo(from: text)
        for modifiers in ["option", "option+shift", "control+option", "control+shift", "control"] {
            guard let combo = WhytapLink.linkCombo(from: modifiers + "+" + key), combo != wanted else { continue }
            var candidate = configuration
            row.feature.assign(.combo(combo), in: &candidate)
            guard candidate.conflicts.allSatisfy({ !$0.actionTitles.contains(row.conflictTitle) }) else { continue }
            return " Nearest free keys: \(WhytapLink.linkKeys(for: combo)) (\(AppControlToolbox.display(.combo(combo))))."
        }
        return ""
    }

    /// Same keys in any modifier order or spelling.
    static func sameKeys(_ expected: AppControlValue, _ current: AppControlValue) -> Bool {
        guard let wanted = expected.string, let saved = current.string else { return expected == current }
        if let lhs = WhytapLink.linkCombo(from: wanted), let rhs = WhytapLink.linkCombo(from: saved) { return lhs == rhs }
        let squash = { (text: String) in text.lowercased().filter { !" _-+".contains($0) } }
        return squash(wanted) == squash(saved)
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
