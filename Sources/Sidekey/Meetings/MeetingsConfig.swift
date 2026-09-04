import Foundation

/// Configuration surface for the Meeting Notes feature.
///
/// Two roles:
///
/// 1. **Feature flag** — `isEnabled` toggles the entire `MeetingsCoordinator`
///    wiring on or off via `UserDefaults`. The rollout default is now `true`
///    so prod installs run the detector without requiring a manual
///    `defaults write`; an explicit stored `false` still disables it for
///    rollback / local debugging.
///
/// 2. **Named constants** — single source of truth for the magic
///    timings spread across the detector, pill, prerecord buffer,
///    recorder, and coordinator. Centralising them here keeps the
///    cross-stage spec (`docs/specs/meetings.md`) in sync with one file
///    instead of half a dozen hard-coded literals.
///
/// Constants are static because they are spec-fixed values, not
/// per-instance preferences. `isEnabled` lives on the instance so tests
/// can inject an isolated `UserDefaults` suite.
@MainActor
final class MeetingsConfig {
    /// `UserDefaults` key for the feature-flag toggle. Centralised so
    /// `defaults write <bundle-id> com.sidekey.meetings.enabled -bool false`
    /// has one canonical rollback key string.
    static let isEnabledDefaultsKey = "com.sidekey.meetings.enabled"

    /// Deprecated pre-Dynamic-Island key for the user's preferred protocol
    /// language. The active source of truth is now
    /// `PrivacyPreferences.selectedLanguage` so Drop, Agent, and Meetings read
    /// the same UI-selected language.
    static let preferredLanguageDefaultsKey = "com.sidekey.meetings.preferredLanguage"

    /// Speech-in-system-audio seconds required within `detectorWindowSeconds`
    /// before the detector triggers. Spec: filters out short Sidekey-like
    /// dictation bursts (< 5s).
    static let detectorMinSpeechSeconds: TimeInterval = 5

    /// Rolling window the detector evaluates `detectorMinSpeechSeconds`
    /// against. Spec.
    static let detectorWindowSeconds: TimeInterval = 10

    /// Meeting suggestion bar auto-dismiss after this many seconds of
    /// inaction. Spec: ignore = decline, so user does not need to click
    /// Skip actively.
    static let pillDecisionTimeoutSeconds: TimeInterval = 20

    /// FIFO RAM ring buffer length covering audio between detector trigger
    /// and accept/dismiss. Spec: avoids losing the first minute of the
    /// meeting because the detector needs ≥ 5s of speech before triggering
    /// and the pill can sit unanswered for up to 20s.
    static let prerecordBufferCapacitySeconds: TimeInterval = 60

    /// Safety: auto-stop the recorder if the mic has been released for
    /// this many seconds. Spec: catches "forgot to press Stop" cases.
    static let autoEndMicReleasedSeconds: TimeInterval = 3  // PoC: mute в Zoom/Meet/Teams не releases mic device (app-level mute keeps stream open), поэтому threshold не impact mute scenarios. Real leave/quit = mic released → через 3s auto-finalize + session reset. Quick rejoin (>3s gap) = новая meeting session → новая pill.

    /// Auto-end cannot finalize a recording younger than this. Meeting
    /// apps flap the mic while joining a call (Zoom prejoin preview →
    /// release → conference audio re-acquire, routinely > 3s), which
    /// used to kill a seconds-old recording and produce a junk meeting
    /// plus a bogus Reconnect nudge. The release timer defers so
    /// auto-end can only land once the recording is at least this old.
    static let autoEndStartupGraceSeconds: TimeInterval = 30

    /// An auto-ended recording remains eligible for reconnect during this
    /// window — every re-fire inside it asks via the Notes / Reconnect /
    /// Skip pill, however short the gap. Manual Stop still finalizes
    /// immediately.
    /// WHY: docs/decisions/2026-07-29-reconnect-always-asks.md
    static let reconnectGracePeriodSeconds: TimeInterval = 3 * 60

    /// After the user dismisses a pill, suppress new pills for this many
    /// minutes within the same mic session. Spec: do not nag.
    static let cooldownAfterDismissMinutes: Int = 0  // PoC Notion-style: per-session dedup only via firedInCurrentSession; new mic-session = fresh chance

    /// `MeetingRecorder` rotates the on-disk WAV chunk every this many
    /// seconds so a crash mid-meeting keeps everything flushed so far.
    static let chunkRotationSeconds: TimeInterval = 30

    /// `MeetingsEditBridge` debounce window for note edits before they are
    /// persisted to the local store. 500 ms keeps write traffic to a
    /// manageable rate while still feeling instant to the user.
    static let editDebounceMilliseconds: Int = 500

    private let defaults: UserDefaults

    /// - Parameter defaults: typically `.standard`; tests inject an
    ///   isolated suite so flipping `isEnabled` does not leak between
    ///   tests or into the real user preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Feature flag. Reads / writes through to the injected
    /// `UserDefaults`. Missing key means enabled for the current rollout;
    /// explicit `false` remains a kill switch.
    var isEnabled: Bool {
        get {
            guard let stored = defaults.object(forKey: Self.isEnabledDefaultsKey) as? Bool else {
                return true
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Self.isEnabledDefaultsKey) }
    }

    /// User-pinned protocol language. `nil` = auto — the transcriber derives
    /// the language from the audio itself. This intentionally reads the same
    /// `PrivacyPreferences.selectedLanguage` value the Dynamic Island language
    /// control writes, keeping all voice surfaces on one source of truth.
    var preferredLanguage: String? {
        get {
            PrivacyPreferences(defaults: defaults).selectedLanguage?.code
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prefs = PrivacyPreferences(defaults: defaults)
            if !trimmed.isEmpty, let language = AppLanguage.find(code: trimmed) {
                prefs.selectedLanguage = language
            } else {
                prefs.selectedLanguage = nil
            }
        }
    }
}
