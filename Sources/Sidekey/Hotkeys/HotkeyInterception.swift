import CoreGraphics
import Foundation

// Pure logic for the hotkey interceptor indicator: which apps could swallow a
// Whytap modifier shortcut, and whether a physical press of it was lost before
// Whytap's shortcut monitors. Nothing here touches AppKit or the event system.
// WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md

/// One row of `CGGetEventTapList`, as far as the indicator needs it.
struct EventTapRecord: Equatable {
    enum Location: Equatable {
        /// `kCGHIDEventTap`: runs before every session tap.
        case hid
        case session
        case annotatedSession
    }

    let id: UInt32
    let location: Location
    /// `kCGEventTapOptionDefault`: may drop or rewrite events. A listen-only
    /// tap only observes and can never block a shortcut.
    let isActiveFilter: Bool
    let enabled: Bool
    let tappingPID: pid_t
    /// 0 for a tap on all events; otherwise the one process it filters.
    let tappedPID: pid_t
    let eventsOfInterest: UInt64

    static let flagsChangedBit = UInt64(1) << UInt64(CGEventType.flagsChanged.rawValue)

    /// Sees modifier presses (Right ⌘, Right ⌥) and can drop or rewrite them.
    var filtersModifiers: Bool { enabled && isActiveFilter && eventsOfInterest & Self.flagsChangedBit != 0 }

    init(id: UInt32, location: Location, isActiveFilter: Bool, enabled: Bool,
         tappingPID: pid_t, tappedPID: pid_t = 0, eventsOfInterest: UInt64) {
        self.id = id
        self.location = location
        self.isActiveFilter = isActiveFilter
        self.enabled = enabled
        self.tappingPID = tappingPID
        self.tappedPID = tappedPID
        self.eventsOfInterest = eventsOfInterest
    }

    init?(_ info: CGEventTapInformation) {
        let location: Location
        switch info.tapPoint {
        case .cghidEventTap: location = .hid
        case .cgSessionEventTap: location = .session
        case .cgAnnotatedSessionEventTap: location = .annotatedSession
        @unknown default: return nil
        }
        self.init(id: info.eventTapID, location: location,
                  isActiveFilter: info.options == .defaultTap, enabled: info.enabled,
                  tappingPID: info.tappingProcess, tappedPID: info.processBeingTapped,
                  eventsOfInterest: info.eventsOfInterest)
    }

    /// Every tap on the system. Public information: no permission needed.
    static func systemList() -> [EventTapRecord] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }
        return taps.prefix(Int(count)).compactMap(EventTapRecord.init)
    }
}

/// An app that owns an event tap, as the indicator names it.
struct InterceptorProcess: Equatable {
    let app: SecureInputApp
    /// Apple's own processes (Siri, accessibility services) keep modifier
    /// filters on every Mac and are never blamed.
    let isSystem: Bool
}

/// Which other apps could have swallowed a modifier press: enabled active
/// filters on `flagsChanged`, owned by another, non-system process, and
/// either global or filtering the frontmost app.
enum HotkeyInterceptorClassifier {
    static func candidates(
        in taps: [EventTapRecord],
        ownPID: pid_t,
        frontmostPID: pid_t?,
        process: (pid_t) -> InterceptorProcess?
    ) -> [SecureInputApp] {
        let order: [EventTapRecord.Location] = [.hid, .session, .annotatedSession]
        var seen = Set<pid_t>()
        var result: [SecureInputApp] = []
        let relevant = taps.filter { tap in
            tap.filtersModifiers && tap.tappingPID > 0 && tap.tappingPID != ownPID
                && (tap.tappedPID == 0 || tap.tappedPID == frontmostPID)
        }
        for location in order {
            for tap in relevant where tap.location == location && !seen.contains(tap.tappingPID) {
                seen.insert(tap.tappingPID)
                guard let owner = process(tap.tappingPID), !owner.isSystem else { continue }
                result.append(owner.app)
            }
        }
        return result
    }

    /// The HID-level modifier filters of other processes: one created after
    /// Whytap's probe runs before it, so the probe is reinstalled at the head.
    static func foreignHIDFilterIDs(in taps: [EventTapRecord], ownPID: pid_t) -> Set<UInt32> {
        Set(taps.filter { $0.location == .hid && $0.filtersModifiers && $0.tappingPID != ownPID }.map(\.id))
    }

    static func message(for apps: [SecureInputApp], key: HotkeyModifierKey) -> String {
        let names: String
        switch apps.count {
        case 0: names = "Another app"
        case 1: names = apps[0].name
        case 2: names = "\(apps[0].name) or \(apps[1].name)"
        default: names = "\(apps[0].name) or another app"
        }
        return "\(names) is intercepting \(key.title) — change the key in one of the apps"
    }
}

/// Compares two views of the same modifier press: the physical one, seen by
/// Whytap's HID-level probe before any session tap, and the delivered one,
/// seen by the `NSEvent` monitors Whytap's shortcuts use. A press the probe
/// saw and the monitors never saw held was lost (dropped, or its flags
/// rewritten) by a tap in between: the precise "blocked press" signal.
///
/// Times are seconds of system uptime, read when each observer handled the
/// event. The probe runs first in the event pipeline, so a delivered press is
/// never observed before its physical press; the two arrive on the main
/// thread in either order, so verdicts are deferred (`decisionDelay`).
struct HotkeyInterceptionDetector {
    /// After a physical release: time for the delivered event to be handled.
    static let decisionDelay: TimeInterval = 0.3
    /// A press still held this long without delivery is already lost (a
    /// hold gesture would have started).
    static let holdDecision: TimeInterval = 0.5
    /// Clock reads on two threads.
    static let tolerance: TimeInterval = 0.05

    struct Press: Hashable {
        let key: HotkeyModifierKey
        let startedAt: TimeInterval
    }

    enum Verdict: Equatable {
        case delivered(HotkeyModifierKey)
        case blocked(HotkeyModifierKey)
    }

    private var physicalPress: [HotkeyModifierKey: Press] = [:]
    private var deliveredHeld: Set<HotkeyModifierKey> = []
    private var lastDeliveredDown: [HotkeyModifierKey: TimeInterval] = [:]
    private var decided: Set<Press> = []

    /// A physical `flagsChanged`. Returns the presses that just began (decide
    /// them at `startedAt + holdDecision`) and just ended (decide them
    /// `decisionDelay` from now).
    mutating func physical(rawFlags: UInt64, at time: TimeInterval,
                           watched: Set<HotkeyModifierKey>) -> (began: [Press], ended: [Press]) {
        var began: [Press] = []
        var ended: [Press] = []
        for key in HotkeyModifierKey.allCases {
            let held = HotkeyFlags.isHeld(key, rawFlags)
            if held, physicalPress[key] == nil, watched.contains(key) {
                let press = Press(key: key, startedAt: time)
                physicalPress[key] = press
                began.append(press)
            } else if !held, let press = physicalPress.removeValue(forKey: key) {
                ended.append(press)
            }
        }
        return (began, ended)
    }

    /// A `flagsChanged` that reached Whytap's shortcut monitors.
    mutating func delivered(rawFlags: UInt64, at time: TimeInterval) {
        for key in HotkeyModifierKey.allCases {
            let held = HotkeyFlags.isHeld(key, rawFlags)
            if held, !deliveredHeld.contains(key) {
                deliveredHeld.insert(key)
                lastDeliveredDown[key] = time
            } else if !held {
                deliveredHeld.remove(key)
            }
        }
    }

    /// The verdict for a press, once: nil if it was already given or the
    /// press is still held and young.
    mutating func decide(_ press: Press, now: TimeInterval) -> Verdict? {
        guard !decided.contains(press) else { return nil }
        if let delivered = lastDeliveredDown[press.key], delivered >= press.startedAt - Self.tolerance {
            remember(press)
            return .delivered(press.key)
        }
        if physicalPress[press.key] == press, now - press.startedAt < Self.holdDecision { return nil }
        remember(press)
        return .blocked(press.key)
    }

    /// The probe stopped or restarted: a press in progress can no longer be
    /// judged.
    mutating func forgetPhysical() {
        for press in physicalPress.values { remember(press) }
        physicalPress = [:]
    }

    private mutating func remember(_ press: Press) {
        decided.insert(press)
        // Only recent presses can still be asked about.
        if decided.count > 16 {
            decided = decided.filter { $0.startedAt >= press.startedAt - 10 }
        }
    }
}
