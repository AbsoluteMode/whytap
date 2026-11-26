import Carbon.HIToolbox
import CoreGraphics
import Foundation

// Pure logic for the Secure Input holder indicator. Nothing here touches
// AppKit, Accessibility or the event system, so every scenario is testable.
// WHY: .project-docs/decisions/2026-11-26-secure-input-holder.md

/// The modifiers of a chord, side-agnostic.
struct ModifierChord: OptionSet, Hashable {
    let rawValue: UInt8
    static let option = ModifierChord(rawValue: 1 << 0)
    static let shift = ModifierChord(rawValue: 1 << 1)
    static let control = ModifierChord(rawValue: 1 << 2)
    static let command = ModifierChord(rawValue: 1 << 3)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// From Carbon `RegisterEventHotKey` modifiers (`optionKey`, `cmdKey`…).
    init(carbon modifiers: UInt32) {
        var chord: ModifierChord = []
        if modifiers & UInt32(optionKey) != 0 { chord.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { chord.insert(.shift) }
        if modifiers & UInt32(controlKey) != 0 { chord.insert(.control) }
        if modifiers & UInt32(cmdKey) != 0 { chord.insert(.command) }
        self = chord
    }

    /// From the device-independent bits of a `flagsChanged` event.
    init(cgFlags flags: CGEventFlags) {
        var chord: ModifierChord = []
        if flags.contains(.maskAlternate) { chord.insert(.option) }
        if flags.contains(.maskShift) { chord.insert(.shift) }
        if flags.contains(.maskControl) { chord.insert(.control) }
        if flags.contains(.maskCommand) { chord.insert(.command) }
        self = chord
    }
}

/// Which Whytap shortcuts macOS silently drops while another app holds
/// Secure Event Input, as far as they can be seen at all.
///
/// - The `SpaceHoldMonitor` event tap (hold-Space Drop and a hold-combo Drop)
///   gets no key events at all.
/// - Carbon `RegisterEventHotKey` combos whose modifiers are only Option
///   and/or Shift are dropped; combos with Command or Control still fire.
/// - Modifier-only shortcuts (Right Command, Right Option) run on
///   `flagsChanged`, which secure input does not block.
///
/// Only a chord that has modifiers can be noticed: a bare key or Space
/// produces no event Whytap may see.
enum SecureInputBlockedShortcuts {
    static func chords(in configuration: HotkeyConfiguration) -> Set<ModifierChord> {
        var chords = Set<ModifierChord>()
        for assignment in configuration.assignments {
            guard case .combo(let combo) = assignment.binding.key else { continue }
            let chord = ModifierChord(carbon: combo.modifiers)
            if isCarbonBlocked(chord) { chords.insert(chord) }
        }
        // A hold-combo Drop runs on the event tap, which loses every key.
        if case .combo(let combo) = configuration.dropVoiceShortcut,
           HotkeyShortcutMonitor.isDropHoldTap(shortcut: configuration.dropVoiceShortcut,
                                               gesture: configuration.normalizedDropGesture) {
            let chord = ModifierChord(carbon: combo.modifiers)
            if !chord.isEmpty { chords.insert(chord) }
        }
        return chords
    }

    static func isCarbonBlocked(_ chord: ModifierChord) -> Bool {
        !chord.isEmpty && chord.isDisjoint(with: [.control, .command])
    }
}

/// Remembers when any Whytap shortcut last reached Whytap, so a chord that
/// did work is never reported as blocked. Main thread only: Carbon and
/// `NSEvent` monitors deliver there.
enum HotkeyFireRecorder {
    nonisolated(unsafe) private(set) static var lastFire: Date?

    static func noteFired(at date: Date = Date()) { lastFire = date }

    #if DEBUG
    static func resetForTesting() { lastFire = nil }
    #endif
}

/// Turns the `flagsChanged` stream, the only keyboard signal secure input
/// leaves Whytap, into "the person just tried a shortcut that could not
/// arrive": a chord of a blocked shortcut was held and released, briefly,
/// and no Whytap shortcut fired meanwhile.
struct SecureInputAttemptDetector {
    static let maximumHold: TimeInterval = 3

    private var heldSince: Date?
    private var peak: ModifierChord = []

    /// Returns `true` when the release ends a likely failed attempt.
    mutating func flagsChanged(
        to chord: ModifierChord,
        at date: Date,
        lastHotkeyFire: Date?,
        blockedChords: Set<ModifierChord>
    ) -> Bool {
        if !chord.isEmpty {
            if heldSince == nil { heldSince = date; peak = [] }
            peak.formUnion(chord)
            return false
        }
        guard let start = heldSince else { return false }
        let held = peak
        heldSince = nil
        peak = []
        guard blockedChords.contains(held) else { return false }
        guard date.timeIntervalSince(start) <= Self.maximumHold else { return false }
        if let lastHotkeyFire, lastHotkeyFire >= start { return false }
        return true
    }
}

/// An app as Whytap needs it to name the holder.
struct SecureInputApp: Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String?
}

enum SecureInputHolder: Equatable {
    /// Secure input is off: every shortcut can arrive.
    case none
    /// Whytap's own password field (Settings keys, Case). Pointing at
    /// Whytap's own logo would not help; the field releases secure input as
    /// soon as it loses focus.
    case ownApp
    /// `inBackground` is the stuck case: the app is not frontmost yet keeps
    /// secure input on.
    case app(SecureInputApp, inBackground: Bool)
    /// Secure input is on but its owner cannot be named.
    case unknown
}

/// Names the app that holds Secure Event Input.
///
/// macOS has no API for the owner. `kCGSSessionSecureInputPID` (what `ioreg`
/// prints) reports the frontmost app while any process holds secure input,
/// so after Cmd-Tab it names the innocent app. Whytap therefore remembers
/// the app the person left while secure input stayed on, and trusts the
/// frontmost app only when its focused element is a password field or no
/// switch happened since secure input came on.
struct SecureInputHolderTracker {
    private(set) var staleCandidate: SecureInputApp?

    /// Called shortly after the frontmost app changed from `previous`, once
    /// the app that lost focus had the chance to release secure input.
    mutating func didSwitch(from previous: SecureInputApp?, to current: SecureInputApp?, secureInputOn: Bool) {
        guard secureInputOn else { staleCandidate = nil; return }
        guard staleCandidate == nil, let previous, previous.pid != current?.pid else { return }
        staleCandidate = previous
    }

    mutating func secureInputObservedOff() { staleCandidate = nil }

    func resolve(
        secureInputOn: Bool,
        front: SecureInputApp?,
        frontHasSecureField: Bool,
        ownPID: pid_t,
        isRunning: (pid_t) -> Bool
    ) -> SecureInputHolder {
        guard secureInputOn else { return .none }
        if let front, frontHasSecureField {
            return front.pid == ownPID ? .ownApp : .app(front, inBackground: false)
        }
        if let candidate = staleCandidate, candidate.pid != front?.pid {
            if candidate.pid == ownPID { return .ownApp }
            return isRunning(candidate.pid) ? .app(candidate, inBackground: true) : .unknown
        }
        guard let front else { return .unknown }
        return front.pid == ownPID ? .ownApp : .app(front, inBackground: false)
    }
}
