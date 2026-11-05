/// The Brightness capsule's state as supplied by the island.
enum HoverBrightnessStatus: Equatable {
    /// The backlight level, 0...1.
    case level(Double)
    case extra
}

/// In-memory presentation of the state supplied by the island. Resolving a
/// capsule never reads stores or invents an enabled state for navigation tools.
struct HoverToolPresentation: Equatable {
    let title: String
    let status: String?

    static func resolve(
        tool: HoverTool,
        mode: TranscriptionMode,
        inputLanguage: AppLanguage?,
        outputLanguage: AppLanguage?,
        meetingRecordingActive: Bool,
        brightness: HoverBrightnessStatus? = nil
    ) -> Self {
        let status: String?
        switch tool {
        case .dropMode:
            status = mode == .fast ? "Fast" : "Smart"
        case .inputLang:
            status = inputLanguage?.displayName ?? "Auto"
        case .outputLang:
            status = mode == .fast ? "Smart only" : (outputLanguage?.displayName ?? "Off")
        case .meetingRecord:
            status = meetingRecordingActive ? "Recording" : "Not recording"
        case .brightness:
            switch brightness {
            case .extra: status = "Extra"
            case .level(let level): status = "\(Int((ScreenBrightnessScale.clampedLevel(level) * 100).rounded()))%"
            case nil: status = nil
            }
        case .clipboard, .notifs, .vocab, .caseVault, .filler, .hotkeys, .notes, .monitor, .tasks, .calendar, .translate, .subtitles, .screenshot, .quit, .settings:
            status = nil
        }
        return Self(title: HoverToolRegistry.info(for: tool).title, status: status)
    }
}
