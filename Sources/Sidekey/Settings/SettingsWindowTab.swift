import SwiftUI

enum SettingsWindowTab: String, CaseIterable, Identifiable {
    /// The list of features and each feature's own screen. First, so Settings
    /// opens on it.
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    case features
    case apiAndModels
    case hotkeys
    case permissions
    case notes
    case agentMode
    case toolbox
    case notifications
    case integrations
    case backup
    case other

    var id: String { rawValue }

    /// Sidebar tabs. `agentMode` stays a case so `whytap://settings/agentMode`
    /// keeps working; it opens the Agent's screen in Features (`resolved`,
    /// `SettingsWindowSelection.select`).
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    static var availableCases: [SettingsWindowTab] {
        allCases.filter { $0 != .agentMode }
    }

    /// The tab that actually shows this tab's settings.
    var resolved: SettingsWindowTab {
        self == .agentMode ? .features : self
    }

    static var defaultAvailable: SettingsWindowTab {
        availableCases.first ?? .features
    }

    var isAvailable: Bool {
        Self.availableCases.contains(self)
    }

    var title: String {
        switch self {
        case .features:
            return "Features"
        case .apiAndModels:
            return "API & Models"
        case .hotkeys:
            return "Hotkeys"
        case .permissions:
            return "Permissions"
        case .notes:
            return "Meetings"
        case .agentMode:
            return "Agents"
        case .toolbox:
            return "Toolbox"
        case .notifications:
            return "Notifications"
        case .integrations:
            return "Integrations"
        case .backup:
            return "Backup"
        case .other:
            return "Other"
        }
    }

    var systemImageName: String {
        fallbackSystemImageName
    }

    var iconTint: Color {
        switch self {
        case .features: return Color(hexCSS: "#5469CC")
        case .apiAndModels: return Color(hexCSS: "#5469CC")
        case .hotkeys: return Color(hexCSS: "#65656D")
        case .permissions: return Color(hexCSS: "#27845A")
        case .notes: return Color(hexCSS: "#A07513")
        case .agentMode: return Color(hexCSS: "#8A50C6")
        case .toolbox: return Color(hexCSS: "#237EB0")
        case .notifications: return Color(hexCSS: "#CB4055")
        case .integrations: return Color(hexCSS: "#5E69B8")
        case .backup: return Color(hexCSS: "#27845A")
        case .other: return Color(hexCSS: "#65656D")
        }
    }

    var fallbackSystemImageName: String {
        switch self {
        case .features:
            return "sparkles"
        case .apiAndModels:
            return "cpu"
        case .hotkeys:
            return "keyboard"
        case .permissions:
            return "checkmark.shield.fill"
        case .notes:
            return "note.text"
        case .agentMode:
            return "bolt.horizontal.circle.fill"
        case .toolbox:
            return "square.grid.2x2"
        case .notifications:
            return "bell.badge"
        case .integrations:
            return "puzzlepiece.extension"
        case .backup:
            return "externaldrive.badge.timemachine"
        case .other:
            return "ellipsis.circle"
        }
    }

    var pdfResourceName: String? {
        switch self {
        case .features, .apiAndModels, .hotkeys, .permissions, .notes, .agentMode, .toolbox, .notifications, .integrations, .backup, .other:
            return nil
        }
    }
}
