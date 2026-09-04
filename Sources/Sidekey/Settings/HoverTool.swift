// Sources/Sidekey/Settings/HoverTool.swift
import Foundation

/// Every tile that can appear in the hover panel or in the Toolbox catalog.
/// `rawValue` is the UserDefaults-persisted ID — never rename these.
/// `caseVault` avoids the `case` reserved word; its display title is "Case".
enum HoverTool: String, CaseIterable, Hashable {
    case dropMode
    case clipboard
    case vocab
    case caseVault
    case filler
    case inputLang
    case outputLang
    case hotkeys
    case notes
    case meetingRecord
    case quit
    case settings
}

/// Where a `.navigate` tool takes the user.
enum HoverNavigationTarget: Equatable {
    case tab(SettingsWindowTab)
    case quitRow
}

/// What happens when a tile is tapped.
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
        case .clipboard:
            return HoverToolInfo(title: "History", sfSymbol: "clock.arrow.circlepath", kind: .inlinePanel,
                                 description: "Open unified history")
        case .vocab:
            return HoverToolInfo(title: "Vocab", sfSymbol: "book", kind: .inlinePanel,
                                 description: "Manage vocabulary and custom terms")
        case .caseVault:
            return HoverToolInfo(title: "Case", sfSymbol: "key.horizontal", kind: .inlinePanel,
                                 description: "Store and reuse text snippets")
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
        case .meetingRecord:
            return HoverToolInfo(title: "Record", sfSymbol: "record.circle", kind: .action,
                                 description: "Start or stop a meeting recording")
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
