enum SettingsWindowTab: String, CaseIterable, Identifiable {
    case models
    case hotkeys
    case permissions
    case notes
    case agentMode
    case toolbox
    case other

    var id: String { rawValue }

    static var availableCases: [SettingsWindowTab] {
        allCases
    }

    static var defaultAvailable: SettingsWindowTab {
        availableCases.first ?? .models
    }

    var isAvailable: Bool {
        Self.availableCases.contains(self)
    }

    var title: String {
        switch self {
        case .models:
            return "Models"
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
        case .other:
            return "Other"
        }
    }

    var systemImageName: String {
        fallbackSystemImageName
    }

    var fallbackSystemImageName: String {
        switch self {
        case .models:
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
        case .other:
            return "ellipsis.circle"
        }
    }

    var pdfResourceName: String? {
        switch self {
        case .models, .hotkeys, .permissions, .notes, .agentMode, .toolbox, .other:
            return nil
        }
    }
}
