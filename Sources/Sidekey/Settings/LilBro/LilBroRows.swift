import Foundation

/// A Settings row Lil Bro can lead to: the exact control, not only its tab or
/// feature screen ("how do I set a hotkey to start a meeting" ends on Hotkeys
/// → Meeting record; "how do I stop the sound going quiet while I dictate"
/// on Drop → Lower other audio while speaking), scrolled into view and
/// outlined.
///
/// Rows find their entry themselves: `MacRow`, `HotkeySettingRow` and
/// `ConcreteSettingPicker` look up their title on the screen they are drawn
/// on (`lilBroCatalogRow`). Every row of every Settings screen must be here;
/// `LilBroRowCoverageTests` draws each screen and fails on a row or control
/// that is not (REV 14). Rows that are data, one per app, tool or server,
/// are marked `lilBroItems()` where they are drawn and are not listed.
///
/// whytap.ai's Lil Bro endpoint parses `catalog` from this file to tell the
/// model which rows exist: keep one `row(...)` call per line, with literal
/// strings. The second argument is a Settings tab, the feature whose own
/// screen shows the row, or `tool:` the Toolbox tool whose pane shows it.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 12, REV 14)
struct LilBroRow: Hashable {
    let id: String
    let tab: SettingsWindowTab
    /// The feature whose screen shows the row (tab `.features`); nil for a
    /// row of a tab.
    let feature: AppFeature?
    /// The Toolbox tool whose pane shows the row (tab `.toolbox`).
    var tool: HoverTool? = nil
    let title: String
    /// What the row is for, in the words the model reads.
    let about: String

    /// The screen the row is on, as `LilBroController.screen` names it:
    /// `tab` or `features/feature`.
    var screen: String {
        feature.map { "\(SettingsWindowTab.features.rawValue)/\($0.rawValue)" } ?? tab.resolved.rawValue
    }

    private static func row(_ id: String, _ tab: SettingsWindowTab, _ title: String, _ about: String) -> LilBroRow {
        LilBroRow(id: id, tab: tab, feature: nil, title: title, about: about)
    }

    private static func row(_ id: String, tool: HoverTool, _ title: String, _ about: String) -> LilBroRow {
        LilBroRow(id: id, tab: .toolbox, feature: nil, tool: tool, title: title, about: about)
    }

    private static func row(_ id: String, _ feature: AppFeature, _ title: String, _ about: String) -> LilBroRow {
        LilBroRow(id: id, tab: .features, feature: feature, title: title, about: about)
    }

    static let catalog: [LilBroRow] = [
        row("hotkeys.agentText", .hotkeys, "Agent text", "Shortcut that opens the Agent's text input"),
        row("hotkeys.agentVoice", .hotkeys, "Agent voice", "Shortcut to ask the Agent by voice"),
        row("hotkeys.googleText", .hotkeys, "Google text", "Shortcut that opens Google search by text"),
        row("hotkeys.googleVoice", .hotkeys, "Google voice", "Shortcut to search Google by voice"),
        row("hotkeys.dropVoice", .hotkeys, "Drop voice", "Dictation shortcut (Drop): hold or toggle to speak"),
        row("hotkeys.meetingRecord", .hotkeys, "Meeting record", "Shortcut that starts and stops a meeting recording"),
        row("hotkeys.linksInsert", .hotkeys, "Links insert", "Shortcut that inserts a saved link"),
        row("hotkeys.linksOpen", .hotkeys, "Links open", "Shortcut that opens a saved link"),
        row("hotkeys.linksNext", .hotkeys, "Links next", "Shortcut for the next saved link"),
        row("hotkeys.linksPrevious", .hotkeys, "Links previous", "Shortcut for the previous saved link"),
        row("hotkeys.agentClose", .hotkeys, "Agent close", "Shortcut that closes the Agent's answer"),
        row("hotkeys.toolRecord", .hotkeys, "Record (additional shortcut)", "A second shortcut for the Record tool that starts and stops a meeting recording"),
        row("hotkeys.toolSettings", .hotkeys, "Settings", "Shortcut for the Settings hover tool, which opens Whytap Settings"),
        row("hotkeys.toolDropMode", .hotkeys, "Drop Mode", "Shortcut for the Drop Mode hover tool, which switches Drop between Fast and Smart"),
        row("hotkeys.toolClipboard", .hotkeys, "History", "Shortcut for the History hover tool, which opens clipboard history"),
        row("hotkeys.toolNotifs", .hotkeys, "Notify", "Shortcut for the Notify hover tool, which opens Notify, what arrived from your sources"),
        row("hotkeys.toolVocab", .hotkeys, "Vocab", "Shortcut for the Vocab hover tool, which opens Vocab, words Drop should spell right"),
        row("hotkeys.toolCaseVault", .hotkeys, "Case", "Shortcut for the Case hover tool, which opens Case, your secret keys"),
        row("hotkeys.toolFiller", .hotkeys, "Filler", "Shortcut for the Filler hover tool, which opens Filler, words Drop cuts"),
        row("hotkeys.toolInputLang", .hotkeys, "Input Lang", "Shortcut for the Input Lang hover tool, which picks the language you speak"),
        row("hotkeys.toolOutputLang", .hotkeys, "Output Lang", "Shortcut for the Output Lang hover tool, which picks the language Drop writes in"),
        row("hotkeys.toolHotkeys", .hotkeys, "Hotkeys", "Shortcut for the Hotkeys hover tool, which shows your hotkeys"),
        row("hotkeys.toolNotes", .hotkeys, "Notes", "Shortcut for the Notes hover tool, which opens your meeting notes"),
        row("hotkeys.toolMonitor", .hotkeys, "Monitor", "Shortcut for the Monitor hover tool, which opens Monitor dashboards"),
        row("hotkeys.toolBrightness", .hotkeys, "Display", "Shortcut for the Display hover tool, which opens the screen brightness slider"),
        row("hotkeys.toolTasks", .hotkeys, "To-do", "Shortcut for the To-do hover tool, which opens your task list"),
        row("hotkeys.toolCalendar", .hotkeys, "Calendar", "Shortcut for the Calendar hover tool, which opens today's calendar"),
        row("hotkeys.toolTranslate", .hotkeys, "Translate", "Shortcut for the Translate hover tool, which opens Translate"),
        row("hotkeys.toolSubtitles", .hotkeys, "Subtitles", "Shortcut for the Subtitles hover tool, which starts live subtitles"),
        row("hotkeys.toolScreenshot", .hotkeys, "Shot", "Shortcut for the Shot hover tool, which captures a screenshot of an area"),
        row("hotkeys.toolQuit", .hotkeys, "Quit", "Shortcut for the Quit hover tool, which quits Whytap"),
        row("drop.dictate", .drop, "Dictate", "Drop's shortcut: hold or toggle it and speak, the text is typed where you are"),
        row("drop.mode", .drop, "Mode", "Fast types exactly what you said; Smart also fixes slips and punctuation"),
        row("drop.language", .drop, "Language you speak", "The language Drop listens for, or detect automatically"),
        row("drop.lowerOtherAudio", .drop, "Lower other audio while speaking", "Turns down other sound (music, videos) while you dictate and restores it after; turn it off so audio is not lowered"),
        row("drop.stopAutomatically", .drop, "Stop Drop automatically", "In toggle mode, stops dictation by itself after you stop speaking"),
        row("drop.vocab", .drop, "Vocab", "Names and terms Drop should spell right"),
        row("drop.filler", .drop, "Filler", "Words Drop cuts from your dictation"),
        row("agent.switch", .agent, "Agent", "Turns the Agent (Right Command) on or off"),
        row("agent.typeShortcut", .agent, "Type to the Agent", "Shortcut that opens the Agent's text input"),
        row("agent.talkShortcut", .agent, "Talk to the Agent", "Shortcut to ask the Agent by voice"),
        row("agent.closeShortcut", .agent, "Close the answer", "Shortcut that closes the Agent's answer"),
        row("agent.allowActions", .agent, "Allow file edits and commands", "Lets the Agent edit files and run commands; off means it only answers"),
        row("meetings.switch", .meetings, "Meeting Notes", "Turns Meeting Notes on or off: offers to take notes when a call starts"),
        row("meetings.recordShortcut", .meetings, "Start or stop taking notes", "Shortcut that starts and stops a meeting recording"),
        row("meetings.readyNotification", .meetings, "Tell me when a note is ready", "A notification when a meeting note is ready"),
        row("meetings.yourNotes", .meetings, "Your notes", "Opens every meeting note and its transcript"),
        row("googleSearch.switch", .googleSearch, "Google search", "Turns Google search from the keyboard on or off"),
        row("googleSearch.typeShortcut", .googleSearch, "Type a search", "Shortcut that opens a Google search box"),
        row("googleSearch.sayShortcut", .googleSearch, "Say a search", "Shortcut to search Google by voice"),
        row("translateSubtitles.card", .translateSubtitles, "Translate & Subtitles", "Whether Translate and Subtitles are in the island (Toolbox)"),
        row("translateSubtitles.translate", .translateSubtitles, "Translate", "Try Translate: type or paste text and translate it"),
        row("translateSubtitles.subtitles", .translateSubtitles, "Subtitles", "Try Subtitles: live subtitles for what your Mac plays"),
        row("translateSubtitles.openTranslate", .translateSubtitles, "Open Translate", "Shortcut that opens Translate"),
        row("translateSubtitles.startSubtitles", .translateSubtitles, "Start Subtitles", "Shortcut that starts or stops live subtitles"),
        row("screenshots.card", .screenshots, "Screenshots", "Whether Shot is in the island (Toolbox)"),
        row("screenshots.captureNow", .screenshots, "Capture an area now", "Takes a screenshot of an area now"),
        row("screenshots.shortcut", .screenshots, "Capture an area", "Shortcut that captures a screenshot of an area"),
        row("todo.card", .todo, "To-do", "Whether To-do is in the island (Toolbox)"),
        row("todo.yourTasks", .todo, "Your tasks", "Opens To-do in the island"),
        row("todo.shortcut", .todo, "Open To-do", "Shortcut that opens To-do"),
        row("case.card", .caseVault, "Case", "Whether Case, the secret keys store, is in the island (Toolbox)"),
        row("case.yourKeys", .caseVault, "Your keys", "Opens Case with your secret keys"),
        row("case.shortcut", .caseVault, "Open Case", "Shortcut that opens Case"),
        row("notify.inIsland", .notify, "Notify in the island", "History of what arrived, Clear All and the sources"),
        row("notify.shortcut", .notify, "Open Notify", "Shortcut that opens Notify"),
        row("notify.meetingNotes", .notify, "Meeting notes", "Notify me when my meeting notes are ready"),
        row("monitor.inIsland", .monitor, "Monitor in the island", "Pick a dashboard to see its numbers in the island"),
        row("monitor.shortcut", .monitor, "Open Monitor", "Shortcut that opens Monitor"),
        row("hover.dropMode", .hover, "Drop Mode", "Shows or hides Drop Mode in the island (it switches Drop between Fast and Smart); its shortcut and options"),
        row("hover.clipboard", .hover, "History", "Shows or hides History in the island (it opens clipboard history); its shortcut and options"),
        row("hover.notifs", .hover, "Notify", "Shows or hides Notify in the island (it opens Notify, what arrived from your sources); its shortcut and options"),
        row("hover.vocab", .hover, "Vocab", "Shows or hides Vocab in the island (it opens Vocab, words Drop should spell right); its shortcut and options"),
        row("hover.caseVault", .hover, "Case", "Shows or hides Case in the island (it opens Case, your secret keys); its shortcut and options"),
        row("hover.filler", .hover, "Filler", "Shows or hides Filler in the island (it opens Filler, words Drop cuts); its shortcut and options"),
        row("hover.inputLang", .hover, "Input Lang", "Shows or hides Input Lang in the island (it picks the language you speak); its shortcut and options"),
        row("hover.outputLang", .hover, "Output Lang", "Shows or hides Output Lang in the island (it picks the language Drop writes in); its shortcut and options"),
        row("hover.hotkeys", .hover, "Hotkeys", "Shows or hides Hotkeys in the island (it shows your hotkeys); its shortcut and options"),
        row("hover.notes", .hover, "Notes", "Shows or hides Notes in the island (it opens your meeting notes); its shortcut and options"),
        row("hover.meetingRecord", .hover, "Record", "Shows or hides Record in the island (it starts and stops a meeting recording); its shortcut and options"),
        row("hover.monitor", .hover, "Monitor", "Shows or hides Monitor in the island (it opens Monitor dashboards); its shortcut and options"),
        row("hover.brightness", .hover, "Display", "Shows or hides Display in the island (it opens the screen brightness slider); its shortcut and options"),
        row("hover.tasks", .hover, "To-do", "Shows or hides To-do in the island (it opens your task list); its shortcut and options"),
        row("hover.calendar", .hover, "Calendar", "Shows or hides Calendar in the island (it opens today's calendar); its shortcut and options"),
        row("hover.translate", .hover, "Translate", "Shows or hides Translate in the island (it opens Translate); its shortcut and options"),
        row("hover.subtitles", .hover, "Subtitles", "Shows or hides Subtitles in the island (it starts live subtitles); its shortcut and options"),
        row("hover.screenshot", .hover, "Shot", "Shows or hides Shot in the island (it captures a screenshot of an area); its shortcut and options"),
        row("hover.quit", .hover, "Quit", "Shows or hides Quit in the island (it quits Whytap); its shortcut and options"),
        row("apiAndModels.speech", .apiAndModels, "Speech", "The speech-to-text model every voice feature uses"),
        row("apiAndModels.llm", .apiAndModels, "LLM", "The language model every text feature uses"),
        row("apiAndModels.search", .apiAndModels, "Search", "What the Agent searches the web with (built-in or Tavily)"),
        row("apiAndModels.subtitles", .apiAndModels, "Subtitles", "The model for live subtitles and their translation"),
        row("apiAndModels.dropFast", .apiAndModels, "Drop Fast", "Drop Fast's own speech model (under Advanced)"),
        row("apiAndModels.dropSmart", .apiAndModels, "Drop Smart", "Drop Smart's own speech and cleanup models (under Advanced)"),
        row("apiAndModels.meetings", .apiAndModels, "Meetings", "Meeting transcription and summary models (under Advanced)"),
        row("apiAndModels.agent", .apiAndModels, "Agent", "The Agent's voice and answer models (under Advanced)"),
        row("apiAndModels.voiceSearch", .apiAndModels, "Voice search", "Voice search's own speech model (under Advanced)"),
        row("apiAndModels.translation", .apiAndModels, "Translation", "Translate's own model (under Advanced)"),
        row("permissions.keyboard", .permissions, "Keyboard control", "Accessibility and keyboard access Drop and hotkeys need"),
        row("permissions.microphone", .permissions, "Microphone", "Microphone access for Drop, the Agent and meetings"),
        row("permissions.screenRecording", .permissions, "Screen Recording", "Screen recording access for screenshots and meeting audio"),
        row("other.autoHide", .other, "Auto-hide island", "Fades the island into the notch after a while of no use"),
        row("other.showIslandOn", .other, "Show island on", "Which display shows the island"),
        row("other.screenshotProtection", .other, "Screenshot protection", "Hides the island from screenshots and screen shares"),
        row("other.backup", .other, "Backup", "Opens Backup: back up and restore Whytap's settings"),
        row("other.integrations", .other, "Integrations", "Opens Integrations: GitHub, calendars and tools that use Whytap"),
        row("backup.automaticBackup", .backup, "Automatic backup", "Backs up Whytap's settings on its own"),
        row("backup.syncSettings", .backup, "Sync settings between Macs", "Keeps settings the same on your Macs"),
        row("drop.needs.keyboard", .drop, "Keyboard control", "Drop needs keyboard control (Accessibility) to type for you: Allow"),
        row("drop.needs.microphone", .drop, "Microphone", "Drop needs the microphone: Allow"),
        row("drop.needs.speechModel", .drop, "Speech-to-text model", "The speech model Drop uses: download the free model on this Mac or add a key"),
        row("drop.needs.shortcutHeard", .drop, "Your shortcut is heard", "Checks that macOS lets Drop hear its shortcut"),
        row("agent.needs.keyboard", .agent, "Keyboard control", "The Agent needs keyboard control (Accessibility): Allow"),
        row("agent.needs.microphone", .agent, "Microphone", "To talk to the Agent it needs the microphone: Allow"),
        row("agent.needs.screenRecording", .agent, "Screen Recording", "Lets the Agent see your screen when you ask: Allow"),
        row("agent.needs.speechModel", .agent, "Speech-to-text model", "The speech model for talking to the Agent"),
        row("agent.needs.textModel", .agent, "Text model that can use tools", "The model the Agent answers with: add a key or pick a model"),
        row("googleSearch.needs.microphone", .googleSearch, "Microphone", "Voice search needs the microphone: Allow"),
        row("googleSearch.needs.speechModel", .googleSearch, "Speech-to-text model", "The speech model for voice search"),
        row("meetings.needs.microphone", .meetings, "Microphone", "Meeting Notes records your side with the microphone: Allow"),
        row("meetings.needs.systemAudio", .meetings, "System audio", "Records the other side of the call: allow system audio recording"),
        row("meetings.needs.speechModel", .meetings, "Speech-to-text model", "The model that transcribes meetings"),
        row("meetings.needs.textModel", .meetings, "Text model", "The model that writes the meeting summary"),
        row("screenshots.needs.screenRecording", .screenshots, "Screen Recording", "Shot needs Screen Recording to capture the screen: Allow"),
        row("translateSubtitles.needs.subtitlesKey", .translateSubtitles, "Soniox or OpenAI key for Subtitles", "Subtitles need a Soniox or OpenAI key: add a key"),
        row("translateSubtitles.needs.systemAudio", .translateSubtitles, "System audio", "Subtitles listen to what your Mac plays: allow system audio recording"),
        row("translateSubtitles.needs.textModel", .translateSubtitles, "Text model for Translate", "The model Translate uses: add a key or pick a model"),
        row("monitor.buildDashboard", .monitor, "Build a dashboard", "A prompt for your coding agent to build a Monitor dashboard: Show prompt, Copy prompt"),
        row("notify.addYourOwn", .notify, "Add your own", "A prompt for your coding agent to connect a new notification source: Show prompt, Copy prompt"),
        row("hotkeys.save", .hotkeys, "Save changes", "Save, Revert or Reset to defaults for the hotkeys you changed"),
        row("permissions.dropShortcut", .permissions, "Drop shortcut", "Whether Drop's shortcut works, and Retry shortcut or the fix when it does not"),
        row("permissions.refresh", .permissions, "Refresh", "Checks permissions again after you changed them in System Settings"),
        row("integrations.github", .integrations, "GitHub", "Connect GitHub (or an access token) for encrypted backups; check or disconnect it"),
        row("integrations.calendars", .integrations, "Calendars", "Calendars Whytap reads: allow access to calendars, open Internet Accounts to add Google or Outlook"),
        row("backup.backUpAndRestore", .backup, "Back up and restore", "Back up now, Restore backup, save or show the recovery code, Connect GitHub"),
        row("toolbox.openTodo", tool: .tasks, "Open To-do", "Opens your task list inside Hover"),
        row("toolbox.openCalendar", tool: .calendar, "Open Calendar", "Opens today's calendar inside Hover (coming soon)"),
        row("toolbox.holdBrightness", tool: .brightness, "Hold brightness", "Keeps the screen brightness you set"),
        row("toolbox.extraBrightness", tool: .brightness, "Extra", "Brightness above the normal maximum (uses more battery)"),
        row("toolbox.brightnessKeys", tool: .brightness, "Brightness keys", "Lets the keyboard brightness keys use Whytap's brightness"),
    ]

    static func named(_ id: String) -> LilBroRow? {
        byID[id]
    }

    /// The row drawn on `screen` under `title`, if it is listed.
    static func at(screen: String, title: String) -> LilBroRow? {
        byPlace[Place(screen: screen, title: title)]
    }

    private struct Place: Hashable {
        let screen: String
        let title: String
    }

    private static let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byPlace = Dictionary(catalog.map { (Place(screen: $0.screen, title: $0.title), $0) },
                                            uniquingKeysWith: { first, _ in first })
}
