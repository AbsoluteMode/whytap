import Foundation

/// A Settings row Lil Bro can lead to: the exact control, not only its tab
/// ("how do I set a hotkey to start a meeting" ends on Hotkeys → Meeting
/// record, scrolled into view and outlined). The tab view tags the row with
/// `lilBroRow(_:focused:)` and scrolls to it when `SettingsWindowSelection`
/// asks.
///
/// whytap.ai's Lil Bro endpoint parses `catalog` from this file to tell the
/// model which rows exist: keep one `row(...)` call per line, with literal
/// strings.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 12)
struct LilBroRow: Hashable {
    let id: String
    let tab: SettingsWindowTab
    let title: String
    /// What the row is for, in the words the model reads.
    let about: String

    private static func row(_ id: String, _ tab: SettingsWindowTab, _ title: String, _ about: String) -> LilBroRow {
        LilBroRow(id: id, tab: tab, title: title, about: about)
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
    ]

    static func named(_ id: String) -> LilBroRow? {
        catalog.first { $0.id == id }
    }
}
