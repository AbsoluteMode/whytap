import Foundation

/// Action callbacks fed into ToolboxSettingsView from the island layer.
/// Defaults are safe no-ops so tests and the Settings window can be
/// constructed without a wired island.
struct ToolboxDeps {
    /// Toggle Drop Mode fast/smart and return the mode now in effect.
    var toggleDropMode: () -> TranscriptionMode = { .fast }
    /// Current Drop transcription mode.
    var currentDropMode: () -> TranscriptionMode = { .fast }
    /// Open the floating clipboard history strip.
    var openClipboard: () -> Void = {}
    var historyCards: (HistoryStripMode) async -> [HistoryStripCard] = { _ in [] }
    var copyHistoryCard: (HistoryStripCard) -> Void = { _ in }
    /// Confirms and deletes a clipboard row; `true` when the list must reload.
    var deleteHistoryCard: (HistoryStripCard) async -> Bool = { _ in false }
    var toggleMeetingRecord: () -> Void = {}
    var openScreenshot: () -> Void = {}
    /// Show an inline tool in this process, without LaunchServices scheme lookup.
    var openHoverPanel: (HoverInlinePanel) -> Void = { _ in }
    var quitApplication: () -> Void = {}
    /// Reuse the floating translator's models, preferences and activity guard.
    var translationController: () -> TranslationWindowController? = { nil }
    var endToolSessions: () -> Void = {}
    /// Local vocabulary store behind the Vocab editor.
    var vocabulary: () -> VocabularyCache = { .shared }
    /// Current input language (nil = Auto).
    var currentLanguage: () -> AppLanguage? = { nil }
    /// Current output language (nil = off).
    var currentTargetLanguage: () -> AppLanguage? = { nil }
    /// Persist a new input language.
    var setLanguage: (AppLanguage?) -> Void = { _ in }
    /// Persist a new output language.
    var setTargetLanguage: (AppLanguage?) -> Void = { _ in }
}
