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
