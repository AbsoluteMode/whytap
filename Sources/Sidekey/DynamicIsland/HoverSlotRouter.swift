import Foundation

/// The inline sub-panels a Hover tile can open. Public mirror of IslandView's
/// private `IslandHoverPanelMode` cases that correspond to `.inlinePanel` tools,
/// so a hover-slot hotkey fired from `AppDelegate` can request a specific panel
/// without leaking the view's private enum. `IslandView` maps this back onto its
/// own panel-mode state.
enum HoverInlinePanel: Equatable {
    /// Unified clipboard/drop/agent History panel (#313). The Clipboard tile
    /// became this inline hover panel, so its feature hotkey opens History in-place
    /// rather than firing the old bottom-strip action.
    case history
    case tasks
    case calendar
    case notifications
    case vocabularyEditor
    case caseVault
    case fillerEditor
    case inputLanguagePicker
    case outputLanguagePicker
    case monitor
    case brightness
}

/// A one-shot "open this inline panel" request carried on `AppState`. The
/// monotonic `token` makes two consecutive requests for the SAME panel distinct
/// `@Published` change events, so `IslandView.onChange` fires both times (a bare
/// `HoverInlinePanel?` would be deduplicated by SwiftUI when the value repeats).
struct HoverPanelRequest: Equatable {
    let panel: HoverInlinePanel
    let token: Int
    /// A brightness key: show the strip briefly without taking keyboard focus.
    var isGlance = false
}

/// The single effect a Hover slot produces when activated — by a tile click OR
/// by its assigned feature hotkey (D1: one source of truth for tool → effect).
///
/// `.action`/`.navigate` tools resolve to a concrete `IslandActions` closure and
/// can run without the drawer open (they open windows / toggle state).
/// `.inlinePanel` tools resolve to `.openPanel`, which only makes sense once the
/// Hover is expanded — the drawer hosts the sub-panel.
///
/// `.toggleDropMode` is the exception among action tools: both activation paths
/// call `actions.toggleDropMode()` themselves and consume the returned mode
/// (tile click in `IslandView` syncs its state + shows the ON Smart/Fast
/// status; the feature hotkey in `AppDelegate.onToolHotkeyActivated` publishes it via
/// `AppState.publishDropModeHotkeyToggle`), so `invoke` is a no-op for it.
enum HoverSlotEffect: Equatable {
    case toggleDropMode
    case openSettings
    case openHotkeys
    case openNotes
    case toggleMeetingRecord
    case openMonitor
    case openCalendar
    case openTranslate
    case openSubtitles
    case openScreenshot
    case quit
    case openPanel(HoverInlinePanel)
    /// A tool that is listed with a "Soon" badge: activating it does nothing.
    case comingSoon

    /// `true` when the effect needs the Hover drawer expanded to be meaningful
    /// (the inline sub-panels render inside it). Action/navigate effects open
    /// their own surfaces and do not require expansion.
    var requiresExpansion: Bool {
        switch self {
        case .openPanel:
            return true
        case .toggleDropMode, .openSettings, .openHotkeys, .openNotes,
             .toggleMeetingRecord, .openMonitor, .openCalendar, .openTranslate, .openSubtitles, .openScreenshot, .quit,
             .comingSoon:
            return false
        }
    }

    /// The translation window a tool hotkey toggles. Tile clicks, tool search
    /// and `whytap://` links keep the open-only `invoke` path.
    var hotkeyTranslationToggle: TranslationWindowController.Mode? {
        switch self {
        case .openTranslate: return .text
        case .openSubtitles: return .subtitles
        default: return nil
        }
    }

    /// Fire the matching `IslandActions` closure for an action/navigate effect.
    /// `.openPanel` effects are handled by the view (panel-mode state) and
    /// `.toggleDropMode` by `AppDelegate.onToolHotkeyActivated`, so both are
    /// intentionally a no-op here — the caller drives them separately.
    @MainActor
    func invoke(on actions: IslandActions) {
        switch self {
        case .toggleDropMode:
            // Handled by `AppDelegate.onToolHotkeyActivated` directly — the
            // returned mode must be published via
            // `AppState.publishDropModeHotkeyToggle`, so routing it through
            // `invoke` would silently drop the UI feedback.
            break
        case .openSettings:
            actions.openSettings()
        case .openHotkeys:
            actions.openHotkeys()
        case .openNotes:
            actions.openMeetings()
        case .toggleMeetingRecord:
            actions.toggleMeetingRecord()
        case .openMonitor:
            actions.openMonitor()
        case .openCalendar:
            actions.openCalendar()
        case .openTranslate:
            actions.openTranslate()
        case .openSubtitles:
            actions.openSubtitles()
        case .openScreenshot:
            actions.openScreenshot()
        case .quit:
            actions.quitApplication()
        case .openPanel, .comingSoon:
            break
        }
    }
}

/// Maps a `HoverTool` to its single activation effect. The one source of truth
/// shared by the tile-click handler in `IslandView` and the feature hotkey handler in
/// `AppDelegate`, so the keyboard path always matches the click path (D1). Pure
/// and side-effect free — directly unit-testable.
enum HoverSlotRouter {
    static func effect(for tool: HoverTool) -> HoverSlotEffect {
        // The one gate for every path: tile, search, hotkey and Toolbox all end here.
        // WHY: .project-docs/decisions/2026-11-21-calendar-soon.md
        if tool.isComingSoon { return .comingSoon }
        switch tool {
        case .dropMode:
            return .toggleDropMode
        case .notifs:
            return .openPanel(.notifications)
        case .clipboard:
            return .openPanel(.history)
        case .settings:
            return .openSettings
        case .hotkeys:
            return .openHotkeys
        case .notes:
            return .openNotes
        case .meetingRecord:
            return .toggleMeetingRecord
        case .monitor:
            return .openPanel(.monitor)
        case .brightness:
            return .openPanel(.brightness)
        case .tasks:
            return .openPanel(.tasks)
        case .calendar:
            return .openPanel(.calendar)
        case .translate:
            return .openTranslate
        case .subtitles:
            return .openSubtitles
        case .screenshot:
            return .openScreenshot
        case .quit:
            return .quit
        case .vocab:
            return .openPanel(.vocabularyEditor)
        case .caseVault:
            return .openPanel(.caseVault)
        case .filler:
            return .openPanel(.fillerEditor)
        case .inputLang:
            return .openPanel(.inputLanguagePicker)
        case .outputLang:
            return .openPanel(.outputLanguagePicker)
        }
    }
}
