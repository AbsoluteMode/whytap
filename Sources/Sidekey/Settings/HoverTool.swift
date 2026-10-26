// Sources/Sidekey/Settings/HoverTool.swift
import Foundation

/// Every tile that can appear in the hover panel or in the Toolbox catalog.
/// `rawValue` is the UserDefaults-persisted ID — never rename these.
/// `caseVault` avoids the `case` reserved word; its display title is "Case".
enum HoverTool: String, CaseIterable, Hashable {
    case dropMode
    case clipboard
    case notifs
    case vocab
    case caseVault
    case filler
    case inputLang
    case outputLang
    case hotkeys
    case notes
    case meetingRecord
    case meetingAssistant
    case monitor
    case brightness
    case tasks
    case calendar
    case translate
    case subtitles
    case quit
    case settings
    case screenshot
}

/// Where a `.navigate` tool takes the user.
enum HoverNavigationTarget: Equatable {
    case tab(SettingsWindowTab)
    case quitRow
}

/// Activation in the live island. Toolbox first selects the tool’s pane.
enum HoverToolKind: Equatable {
    /// Opens an inline sub-panel in the hover or in the Toolbox right pane.
    case inlinePanel
    /// Executes an immediate action (toggle, open strip, open window).
    case action
    /// Navigates to a Settings destination and highlights it.
    case navigate(HoverNavigationTarget)
}

struct HoverToolInfo: Equatable {
    let title: String
    let sfSymbol: String
    let kind: HoverToolKind
    let description: String
}

/// Single source of truth for tile metadata. Both the live hover and the
/// Toolbox tab read this — never hardcode title/symbol/kind twice.
enum HoverToolRegistry {
    static func info(for tool: HoverTool) -> HoverToolInfo {
        switch tool {
        case .dropMode:
            return HoverToolInfo(title: "Drop Mode", sfSymbol: "bolt", kind: .action,
                                 description: "Switch between Fast and Smart transcription")
        case .notifs:
            return HoverToolInfo(title: "Notify", sfSymbol: "bell.badge", kind: .inlinePanel,
                                 description: "View notifications and manage script sources")
        case .clipboard:
            return HoverToolInfo(title: "History", sfSymbol: "clock.arrow.circlepath", kind: .inlinePanel,
                                 description: "Open unified history")
        case .vocab:
            return HoverToolInfo(title: "Vocab", sfSymbol: "book", kind: .inlinePanel,
                                 description: "Manage vocabulary and custom terms")
        case .caseVault:
            return HoverToolInfo(title: "Case", sfSymbol: "key.horizontal", kind: .inlinePanel,
                                 description: "Keep API keys your agents can use")
        case .filler:
            return HoverToolInfo(title: "Filler", sfSymbol: "scissors", kind: .inlinePanel,
                                 description: "Fill in common phrases")
        case .inputLang:
            return HoverToolInfo(title: "Input Lang", sfSymbol: "globe", kind: .inlinePanel,
                                 description: "Choose input language for transcription")
        case .outputLang:
            return HoverToolInfo(title: "Output Lang", sfSymbol: "globe", kind: .inlinePanel,
                                 description: "Choose output language for Smart Mode translation")
        case .hotkeys:
            return HoverToolInfo(title: "Hotkeys", sfSymbol: "keyboard",
                                 kind: .navigate(.tab(.hotkeys)),
                                 description: "View and configure keyboard shortcuts")
        case .notes:
            return HoverToolInfo(title: "Notes", sfSymbol: "note.text",
                                 kind: .navigate(.tab(.notes)),
                                 description: "Open meeting notes")
        case .meetingAssistant:
            return HoverToolInfo(title: "Meeting Assistant", sfSymbol: "text.bubble", kind: .action,
                                 description: "Beta. Questions and answers for your selected Space. Enable listening for each meeting with the wand")
        case .meetingRecord:
            return HoverToolInfo(title: "Record", sfSymbol: "record.circle", kind: .action,
                                 description: "Start or stop a meeting recording")
        case .monitor:
            return HoverToolInfo(title: "Monitor", sfSymbol: "waveform.path.ecg", kind: .inlinePanel,
                                 description: "Open server status and custom dashboards")
        case .brightness:
            return HoverToolInfo(title: "Display", sfSymbol: "sun.max", kind: .inlinePanel,
                                 description: "Screen brightness and Extra boost")
        case .tasks:
            return HoverToolInfo(title: "To-do", sfSymbol: "checklist", kind: .inlinePanel,
                                 description: "Quick local tasks and completion history")
        case .calendar:
            return HoverToolInfo(title: "Calendar", sfSymbol: "calendar", kind: .inlinePanel,
                                 description: "Today's schedule and connected calendars")
        case .translate:
            return HoverToolInfo(title: "Translate", sfSymbol: "character.bubble", kind: .action,
                                 description: "Translate text with your chosen LLM")
        case .subtitles:
            return HoverToolInfo(title: "Subtitles", sfSymbol: "captions.bubble", kind: .action,
                                 description: "Translate system audio into live subtitles")
        case .screenshot:
            return HoverToolInfo(title: "Shot", sfSymbol: "viewfinder", kind: .action,
                                 description: "Capture an area, annotate it and blur text and numbers")
        case .quit:
            return HoverToolInfo(title: "Quit", sfSymbol: "rectangle.portrait.and.arrow.right",
                                 kind: .navigate(.quitRow),
                                 description: "Quit Whytap")
        case .settings:
            return HoverToolInfo(title: "Settings", sfSymbol: "slider.horizontal.3",
                                 kind: .action,
                                 description: "Open settings")
        }
    }

    static func description(
        for tool: HoverTool,
        mode: TranscriptionMode,
        inputLanguage: AppLanguage?,
        outputLanguage: AppLanguage?
    ) -> String {
        let baseDescription = info(for: tool).description
        guard tool == .dropMode,
              mode == .smart,
              let outputLanguage,
              outputLanguage.code != inputLanguage?.code else {
            return baseDescription
        }

        return "Smart Mode is on. Output Language: \(outputLanguage.displayName)"
    }
}
