// Sources/Sidekey/Settings/WhytapLink.swift
import Carbon.HIToolbox
import Foundation

/// The place a `whytap://` link shows. Any web page can open a link, so a
/// link only shows where a feature lives: it never records, captures,
/// toggles a mode, copies, pastes, authenticates or quits. Action tools open
/// their own window or their Toolbox pane, whose button stays explicit.
/// Add a case only if it is show-only (Invariant 7).
/// WHY: .project-docs/decisions/2026-10-20-whytap-links.md
enum WhytapLinkDestination: Equatable {
    /// Expand the island and open this inline hover panel.
    case hoverPanel(HoverInlinePanel)
    /// Open Settings and highlight this sidebar tab or the Quit row.
    case settings(HoverNavigationTarget)
    /// Open Settings -> Toolbox with this tool's pane selected.
    case toolboxTool(HoverTool)
    case translation(TranslationWindowController.Mode)
    /// A well-formed link to something this version does not have (a newer
    /// tile, tab or link kind): only show the island.
    case island
}

/// A setting a link may propose. It changes nothing until the user clicks
/// Assign in Whytap's own confirmation (Invariant 7). Only choices whose
/// worst case is an inconvenient, reversible setting belong here: never
/// reading data, never where data is sent, never starting anything.
/// WHY: .project-docs/decisions/2026-10-21-whytap-link-hotkeys.md
enum WhytapLinkChange: Equatable {
    /// Assign a tool's feature hotkey (Settings -> Hotkeys -> Tools).
    case toolHotkey(HoverTool, HotkeyTapCombo)
}

enum WhytapLinkRequest: Equatable {
    case show(WhytapLinkDestination)
    case propose(WhytapLinkChange)
}

/// What a proposed change would do to the current configuration.
enum WhytapLinkChangePlan: Equatable {
    /// Already set this way: nothing to confirm.
    case unchanged
    /// Ask the user; `current` is the binding it replaces.
    case confirm(current: HotkeyShortcut?)
    /// The keys belong to other actions; nothing may change.
    case conflict(actionTitles: [String])
}

/// Parses `whytap://tool/<HoverTool rawValue>`,
/// `whytap://settings/<SettingsWindowTab rawValue>` and
/// `whytap://hotkey/<HoverTool rawValue>?keys=option+shift+s`. The enums
/// themselves are the registry of linkable places: the switches below are
/// exhaustive, so a new tile or tab does not compile until it has a
/// destination and a hotkey decision.
enum WhytapLink {
    static let scheme = "whytap"

    /// `nil` rejects the URL: another scheme, no kind, an empty or nested
    /// path, or an id with characters no enum raw value uses (`..`, `%2F`).
    static func request(for url: URL) -> WhytapLinkRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.user == nil, components.password == nil, components.port == nil,
              let kind = components.host?.lowercased(), !kind.isEmpty
        else { return nil }

        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, segments[0].isEmpty else { return nil }
        let id = String(segments[1])
        guard !id.isEmpty, id.count <= 64,
              id.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }

        switch kind {
        case "tool":
            return .show(HoverTool(rawValue: id).map(destination(for:)) ?? .island)
        case "settings":
            return .show(SettingsWindowTab(rawValue: id).map(destination(for:)) ?? .island)
        case "hotkey":
            // Anything it cannot propose safely still shows where hotkeys live.
            guard let tool = HoverTool(rawValue: id), acceptsLinkHotkey(tool),
                  let items = components.queryItems, items.count == 1, items[0].name == "keys",
                  let combo = items[0].value.flatMap(linkCombo(from:))
            else { return .show(.settings(.tab(.hotkeys))) }
            return .propose(.toolHotkey(tool, combo))
        default:
            return .show(.island)
        }
    }

    static func destination(for tool: HoverTool) -> WhytapLinkDestination {
        switch tool {
        case .clipboard: return .hoverPanel(.history)
        case .notifs: return .hoverPanel(.notifications)
        case .vocab: return .hoverPanel(.vocabularyEditor)
        // Both Case surfaces request Touch ID on appear; a link must not
        // prompt. Toolbox lists Case in its catalog for the user to click.
        case .caseVault: return .settings(.tab(.toolbox))
        case .filler: return .hoverPanel(.fillerEditor)
        case .inputLang: return .hoverPanel(.inputLanguagePicker)
        case .outputLang: return .hoverPanel(.outputLanguagePicker)
        case .monitor: return .hoverPanel(.monitor)
        case .brightness: return .hoverPanel(.brightness)
        case .hotkeys: return .settings(.tab(.hotkeys))
        case .notes: return .settings(.tab(.notes))
        // Highlights the Quit row; quitting needs the user's click.
        case .quit: return .settings(.quitRow)
        case .settings: return .settings(.tab(.apiAndModels))
        case .tasks: return .hoverPanel(.tasks)
        case .calendar: return .hoverPanel(.calendar)
        case .translate: return .translation(.text)
        // The window opens idle; subtitles start from its own button.
        case .subtitles: return .translation(.subtitles)
        // Toolbox shows the pane; the mode switch, recording and capture
        // stay behind its explicit buttons.
        case .dropMode, .meetingRecord, .screenshot: return .toolboxTool(tool)
        }
    }

    static func destination(for tab: SettingsWindowTab) -> WhytapLinkDestination {
        switch tab {
        case .apiAndModels, .hotkeys, .permissions, .notes, .agentMode, .toolbox,
             .notifications, .integrations, .backup, .other:
            return .settings(.tab(tab))
        }
    }

    /// Whether a link may propose this tool's hotkey.
    static func acceptsLinkHotkey(_ tool: HoverTool) -> Bool {
        switch tool {
        // A stray Quit hotkey would end a dictation or recording mid-take.
        case .quit:
            return false
        case .dropMode, .clipboard, .notifs, .vocab, .caseVault, .filler, .inputLang,
             .outputLang, .hotkeys, .notes, .meetingRecord, .monitor, .brightness, .tasks,
             .calendar, .translate, .subtitles, .settings, .screenshot:
            return true
        }
    }

    /// `option+shift+s`: modifiers then one key, joined by `+`. Requires ⌃ or
    /// ⌥, so a link cannot take app shortcuts (⌘C, ⌘Q) or typed capitals
    /// (⇧A). Keys: A–Z, 0–9, US punctuation and F1–F20; no Space, Tab,
    /// Return, Escape or Delete.
    static func linkCombo(from keys: String) -> HotkeyTapCombo? {
        let tokens = keys.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init)
        guard (2...5).contains(tokens.count), let keyToken = tokens.last,
              let key = linkKeys[keyToken]
        else { return nil }
        var modifiers: UInt32 = 0
        for token in tokens.dropLast() {
            let mask: Int
            switch token {
            case "ctrl", "control": mask = controlKey
            case "opt", "option", "alt": mask = optionKey
            case "shift": mask = shiftKey
            case "cmd", "command": mask = cmdKey
            default: return nil
            }
            guard modifiers & UInt32(mask) == 0 else { return nil }
            modifiers |= UInt32(mask)
        }
        guard modifiers & UInt32(controlKey | optionKey) != 0 else { return nil }
        return HotkeyTapCombo(keyCode: UInt32(key.code), modifiers: modifiers, keyTitle: key.title)
    }

    private static let linkKeys: [String: (code: Int, title: String)] = {
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
                       kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                       kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                       kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                       kVK_ANSI_Y, kVK_ANSI_Z]
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                         kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16,
                         kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let punctuation: [(String, Int)] = [
            ("`", kVK_ANSI_Grave), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal),
            ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket), ("\\", kVK_ANSI_Backslash),
            (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma),
            (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash)
        ]
        var table: [String: (code: Int, title: String)] = [:]
        for (offset, code) in letters.enumerated() {
            let title = String(UnicodeScalar(UInt8(ascii: "A") + UInt8(offset)))
            table[title.lowercased()] = (code, title)
        }
        for (offset, code) in digits.enumerated() { table[String(offset)] = (code, String(offset)) }
        for (offset, code) in functions.enumerated() { table["f\(offset + 1)"] = (code, "F\(offset + 1)") }
        for (title, code) in punctuation { table[title] = (code, title) }
        return table
    }()
}

extension WhytapLinkChange {
    /// The configuration with only this change applied.
    func applied(to configuration: HotkeyConfiguration) -> HotkeyConfiguration {
        var result = configuration
        switch self {
        case .toolHotkey(let tool, let combo):
            result.toolShortcuts[tool] = .combo(combo)
        }
        return result
    }

    func plan(for configuration: HotkeyConfiguration) -> WhytapLinkChangePlan {
        switch self {
        case .toolHotkey(let tool, let combo):
            let current = configuration.toolShortcuts[tool]
            if current == .combo(combo) { return .unchanged }
            let key = HotkeyBinding(gesture: .tap, key: .combo(combo)).conflictKey
            let owners = applied(to: configuration).assignments
                .filter { $0.binding.conflictKey == key }
                .map(\.actionTitle)
                .filter { $0 != HoverToolRegistry.info(for: tool).title }
            return owners.isEmpty ? .confirm(current: current) : .conflict(actionTitles: owners)
        }
    }
}
