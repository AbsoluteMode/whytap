import Carbon.HIToolbox
import Foundation
import WhytapCaseKit

/// The island's tools and their hotkeys for the application controls. Every
/// change goes through the stores Settings uses: `HoverLayoutStore.placeTool`
/// / `removeTool` (Toolbox) and `HotkeyPreferences.assignToolShortcut`
/// (Hotkeys Save, its conflict check and registration). Keys follow the
/// `whytap://hotkey` rule: Control or Option, no Quit, no "Soon" tool.
// WHY: .project-docs/decisions/2026-11-22-agent-toolbox-hotkeys.md
@MainActor
struct AppControlToolbox {
    static let operations: Set<String> = ["toolbox_get", "toolbox_set", "hotkeys_get", "hotkey_set"]
    static let writes: Set<String> = ["toolbox_set", "hotkey_set"]

    let layout: () -> HoverLayoutStore
    let hotkeys: () -> HotkeyPreferences

    func handle(_ operation: String, _ args: [String: AppControlValue]) -> AppControlResponse {
        switch operation {
        case "toolbox_get":
            guard args.isEmpty else { return Self.invalid() }
            return .success(.object(["pinned": pinnedValue,
                                     "tools": .array(HoverTool.allCases.map(toolValue))]))
        case "toolbox_set": return place(args)
        // Every other hotkey (Drop, Agent, Google, meeting record, links,
        // Agent close) by `hotkey` id. WHY: .project-docs/decisions/2026-11-28-agent-all-hotkeys.md
        case "hotkeys_get": return AppControlHotkeys(hotkeys: hotkeys).list(args)
        case "hotkey_set" where args["hotkey"] != nil:
            return AppControlHotkeys(hotkeys: hotkeys).set(args)
        case "hotkey_set": return assign(args)
        default: return .failure("unknown_operation", "Unknown application-control operation.")
        }
    }

    // MARK: Toolbox

    private var pinned: [HoverTool] { layout().slots.filter { $0 != .settings } }
    private var pinnedValue: AppControlValue { .array(pinned.map { .string($0.rawValue) }) }

    private func place(_ args: [String: AppControlValue]) -> AppControlResponse {
        guard Set(args.keys).isSubset(of: ["tool", "pinned", "position", "expected"]),
              let id = args["tool"]?.string, case .bool(let pin)? = args["pinned"],
              let expected = args["expected"]?.array, expected.allSatisfy({ $0.string != nil }),
              args["position"] == nil || args["position"]?.int != nil else { return Self.invalid() }
        guard let tool = HoverTool(rawValue: id) else { return Self.unknownTool() }
        guard tool != .settings else {
            return .failure("not_movable", "Settings always stays last in the island; it cannot be removed or moved.")
        }
        guard expected == pinned.map({ .string($0.rawValue) }) else { return Self.conflict() }
        let store = layout()
        let before = pinned.firstIndex(of: tool)
        var changed = false
        if pin {
            let room = pinned.count - (before == nil ? 0 : 1) + 1
            let position = args["position"]?.int
            if let position, !(1...room).contains(position) {
                return .failure("invalid_position", "position is 1…\(room) (1 is the first tool; Settings stays last).")
            }
            if let index = position.map({ $0 - 1 }) ?? (before == nil ? pinned.count : nil) {
                changed = store.placeTool(tool, at: index)
            }
        } else {
            guard args["position"] == nil else { return Self.invalid() }
            if before != nil { store.removeTool(tool); changed = true }
        }
        // Confirm from the saved layout, not from the request.
        let after = pinned.firstIndex(of: tool)
        guard (after != nil) == pin else {
            return .failure("unconfirmed", "The saved Toolbox does not contain the change.")
        }
        return .success(.object([
            "tool": .string(tool.rawValue), "title": .string(Self.title(tool)), "pinned": .bool(pin),
            "position": after.map { .int($0 + 1) } ?? .null,
            "previousPosition": before.map { .int($0 + 1) } ?? .null,
            "changed": .bool(changed), "pinnedTools": pinnedValue
        ]))
    }

    // MARK: Hotkeys

    private func assign(_ args: [String: AppControlValue]) -> AppControlResponse {
        guard Set(args.keys).isSubset(of: ["tool", "keys", "expected"]), let id = args["tool"]?.string,
              let keys = args["keys"], keys == .null || keys.string != nil,
              let expected = args["expected"], expected == .null || expected.string != nil else { return Self.invalid() }
        guard let tool = HoverTool(rawValue: id) else { return Self.unknownTool() }
        guard WhytapLink.acceptsLinkHotkey(tool) else {
            return .failure("hotkey_not_allowed", tool.isComingSoon
                ? "\(Self.title(tool)) is coming soon; it cannot get a hotkey yet."
                : "\(Self.title(tool)) cannot get a hotkey through the older tool form. Use whytap_hotkey_set with hotkey tool.\(tool.rawValue), which takes any key Settings accepts.")
        }
        let preferences = hotkeys()
        guard Self.sameKeys(expected, Self.keysValue(preferences.toolShortcuts[tool])) else { return Self.conflict() }
        var shortcut: HotkeyShortcut?
        if let text = keys.string {
            guard text.count <= 64, let combo = WhytapLink.linkCombo(from: text) else {
                return .failure("invalid_hotkey", "Write keys as modifiers then one key joined by +, with Control or Option: option+s, control+shift+f5. Keys: A–Z, 0–9, F1–F20 and US punctuation. The older tool form takes only these; for any other key Settings accepts (command+shift+s, a bare key, arrows), use whytap_hotkey_set with hotkey tool.\(tool.rawValue)."
                    + Self.suggestion(nearest: text, for: tool, in: preferences.configuration))
            }
            shortcut = .combo(combo)
        }
        let result = preferences.assignToolShortcut(shortcut, to: tool)
        switch result {
        case .saved, .unchanged:
            // Confirm from the saved preferences, not from the request.
            guard preferences.toolShortcuts[tool] == shortcut else {
                return .failure("unconfirmed", "The saved hotkeys do not contain the change.")
            }
            var reply: [String: AppControlValue] = ["tool": .string(tool.rawValue), "title": .string(Self.title(tool)),
                                                    "hotkey": Self.hotkeyValue(shortcut), "changed": .bool(result == .saved)]
            if case .combo(let combo)? = shortcut, let typed = Self.keyboardCharacter(combo) {
                reply["typesInTextFields"] = .string(typed)
            }
            return .success(.object(reply))
        case .conflict(let conflicts):
            let owners = conflicts.flatMap(\.actionTitles).filter { $0 != Self.title(tool) }
            let display = shortcut.map(Self.display) ?? ""
            let used = owners.isEmpty ? "Another shortcut conflicts" : "\(display) is already used by \(Self.list(owners))"
            return .failure("hotkey_conflict", "\(used). Nothing changed. Choose other keys, or the user can free them in Settings → Hotkeys."
                + Self.suggestion(nearest: keys.string ?? "", for: tool, in: preferences.configuration))
        case .rejectedHoldSpace:
            return Self.invalid()
        }
    }

    // MARK: Values

    private func toolValue(_ tool: HoverTool) -> AppControlValue {
        let shortcut = hotkeys().toolShortcuts[tool]
        let position: AppControlValue = tool == .settings ? .null : pinned.firstIndex(of: tool).map { .int($0 + 1) } ?? .null
        return .object([
            "tool": .string(tool.rawValue), "title": .string(Self.title(tool)),
            "description": .string(HoverToolRegistry.info(for: tool).description),
            "pinned": .bool(tool == .settings || layout().slots.contains(tool)),
            "position": position, "movable": .bool(tool != .settings),
            "comingSoon": .bool(tool.isComingSoon),
            "hotkey": Self.hotkeyValue(shortcut),
            "hotkeyAssignable": .bool(WhytapLink.acceptsLinkHotkey(tool))
        ])
    }

    static func title(_ tool: HoverTool) -> String { HoverToolRegistry.info(for: tool).title }

    static func keysValue(_ shortcut: HotkeyShortcut?) -> AppControlValue {
        switch shortcut {
        case .combo(let combo)?: return .string(WhytapLink.linkKeys(for: combo))
        case .modifier(.rightCommand)?: return .string("right_command")
        case .modifier(.rightOption)?: return .string("right_option")
        case .holdSpace?: return .string("space")
        case nil: return .null
        }
    }

    static func hotkeyValue(_ shortcut: HotkeyShortcut?) -> AppControlValue {
        guard let shortcut else { return .null }
        return .object(["keys": keysValue(shortcut), "display": .string(display(shortcut))])
    }

    /// `⌥S`, as the keycaps read.
    static func display(_ shortcut: HotkeyShortcut) -> String {
        switch shortcut {
        case .combo(let combo): return combo.shortcutChipTitles.joined()
        case .modifier(let key): return key.shortcutChipTitle
        case .holdSpace: return "Space"
        }
    }

    /// Tests replace it: the real answer depends on the Mac's keyboard layout.
    static var keyboardCharacter: (HotkeyTapCombo) -> String? = typedCharacter

    /// The character an Option combo types in text fields on the current
    /// keyboard layout (⌥F is ƒ on US). A global hotkey takes that key, so
    /// the user can no longer type the character; the Agent says so.
    static func typedCharacter(_ combo: HotkeyTapCombo) -> String? {
        let option = UInt32(optionKey), shift = UInt32(shiftKey)
        // Function keys type nothing; ⌃ and ⌘ combos are not typing.
        let key = WhytapLink.linkKeys(for: combo).split(separator: "+").last.map(String.init) ?? ""
        let functionKey = key.count > 1 && key.hasPrefix("f") && key.dropFirst().allSatisfy(\.isNumber)
        guard combo.modifiers & option != 0, combo.modifiers & ~(option | shift) == 0, !functionKey else { return nil }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "its ⌥ character"
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(combo.keyCode), UInt16(kUCKeyActionDown), (combo.modifiers >> 8) & 0xFF,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                  characters.count, &length, &characters)
        }
        guard status == noErr else { return "its ⌥ character" }
        let text = String(utf16CodeUnits: characters, count: length)
        // A dead key (⌥E, ⌥U on US) types an accent on the next letter.
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return deadKeys != 0 ? "its ⌥ accent" : nil
        }
        return text
    }

    /// The nearest keys the rules accept that nothing uses yet: the same key
    /// with ⌥, ⌥⇧, ⌃⌥, ⌃⇧ or ⌃, in that order. "" when there is none.
    static func suggestion(nearest text: String, for tool: HoverTool, in configuration: HotkeyConfiguration) -> String {
        guard let key = text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).last.map(String.init) else { return "" }
        let wanted = WhytapLink.linkCombo(from: text)
        for modifiers in ["option", "option+shift", "control+option", "control+shift", "control"] {
            guard let combo = WhytapLink.linkCombo(from: modifiers + "+" + key), combo != wanted else { continue }
            let candidate = configuration.settingToolShortcut(.combo(combo), for: tool)
            guard candidate.conflicts.allSatisfy({ !$0.actionTitles.contains(title(tool)) }) else { continue }
            let keys = WhytapLink.linkKeys(for: combo)
            return " Nearest free keys: \(keys) (\(display(.combo(combo))))."
        }
        return ""
    }

    /// The expected keys match when they name the same combo in any order or
    /// spelling (`shift+option+s` = `option+shift+s`), or are the same text.
    private static func sameKeys(_ expected: AppControlValue, _ current: AppControlValue) -> Bool {
        guard let wanted = expected.string, let saved = current.string else { return expected == current }
        if let lhs = WhytapLink.linkCombo(from: wanted), let rhs = WhytapLink.linkCombo(from: saved) { return lhs == rhs }
        return wanted.lowercased() == saved.lowercased()
    }

    private static func list(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique.joined(separator: " and ")
    }

    private static func invalid() -> AppControlResponse {
        .failure("invalid_arguments", "Use the documented tool, keys and argument types; unknown fields are rejected.")
    }
    private static func unknownTool() -> AppControlResponse {
        .failure("unknown_tool", "Unknown tool. Use a tool id from whytap_toolbox_get.")
    }
    private static func conflict() -> AppControlResponse {
        .failure("conflict", "The current value changed. Read whytap_toolbox_get again before deciding whether to retry.")
    }
}
