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

    /// The tap list proves which apps could have taken the press, not which
    /// one did, so every owner is named as a possible interceptor.
    static func message(for apps: [SecureInputApp], key: HotkeyModifierKey) -> String {
        let names: String
        switch apps.count {
        case 0: names = "Another app"
        case 1: names = apps[0].name
        case 2: names = "\(apps[0].name) or \(apps[1].name)"
        default: names = "\(apps[0].name) or another app"
        }
        return "\(names) may be intercepting \(key.title)"
    }

    /// The candidates of a verdict, judged against the context the press
    /// began in: the same frontmost app, and only the very filters (by tap
    /// id) that existed then and still exist. A replacement tap of the same
    /// app, or a changed frontmost app, gives no candidates.
    static func candidates(
        in taps: [EventTapRecord],
        context: HotkeyPressContext,
        frontmostPID: pid_t?,
        ownPID: pid_t,
        process: (pid_t) -> InterceptorProcess?
    ) -> [SecureInputApp] {
        guard frontmostPID == context.frontmostPID else { return [] }
        let surviving = taps.filter { context.filterIDs.contains($0.id) }
        return candidates(in: surviving, ownPID: ownPID, frontmostPID: frontmostPID, process: process)
    }

    /// The modifier filters (tap ids) that could act on a press made with
    /// `frontmostPID` in front.
    static func filterIDs(in taps: [EventTapRecord], ownPID: pid_t, frontmostPID: pid_t?) -> Set<UInt32> {
        Set(taps.filter { tap in
            tap.filtersModifiers && tap.tappingPID > 0 && tap.tappingPID != ownPID
                && (tap.tappedPID == 0 || tap.tappedPID == frontmostPID)
        }.map(\.id))
    }
}

/// What surrounded a press when it began, read on the main thread close
/// enough to the event that nothing could have changed in between.
struct HotkeyPressContext: Equatable {
    let frontmostPID: pid_t?
    let filterIDs: Set<UInt32>
}

/// Compares two views of the same modifier press: the physical one, seen by
/// Whytap's HID-level probe before any session tap, and the delivered one,
/// seen by the `NSEvent` monitors Whytap's shortcuts use. A press the probe
/// saw that the monitors never saw held was lost (dropped, or its flags
/// rewritten) by a tap in between: the precise "blocked press" signal.
///
/// Each press is its own record. It is matched only with a delivered press
/// of the same key carrying the same event timestamp (the same hardware
/// event), or one whose event time lies inside that press's own interval (an
/// app that swallows and re-posts the key). A later press never covers an
/// earlier one. Event times come from the events; `seenAt` times are the
/// main-thread clock the deadlines use.
///
/// Only a press the real monitors could take is judged: the key goes down
/// alone (`HotkeyFlags.isOnly`), and a press that gains another modifier
/// while held is retired, as the gesture monitors cancel it.
struct HotkeyInterceptionDetector {
    /// After a physical release (main-thread time): grace for the delivered
    /// event to be handled.
    static let decisionDelay: TimeInterval = 0.3
    /// A press still held this long is judged without waiting for its
    /// release (a hold gesture would have started).
    static let holdDecision: TimeInterval = 0.5
    /// Event-time slack when matching a delivered press to a physical one.
    static let tolerance: TimeInterval = 0.002
    /// Records older than this are dropped (a release the probe missed).
    static let retention: TimeInterval = 30

    enum Verdict: Equatable {
        case delivered(HotkeyModifierKey)
        case blocked(HotkeyModifierKey)
    }

    struct Press: Equatable {
        let id: Int
        let key: HotkeyModifierKey
        let eventTime: TimeInterval
        let seenAt: TimeInterval
        var endTime: TimeInterval?
        var endSeenAt: TimeInterval?
        var eligible = true
        var verdict: Verdict?
    }

    enum Change: Equatable {
        /// Judge at `seenAt + holdDecision` if still held.
        case began(id: Int, at: TimeInterval)
        /// Judge at `endSeenAt + decisionDelay`.
        case ended(id: Int, at: TimeInterval)
    }

    private(set) var presses: [Int: Press] = [:]
    private var heldPress: [HotkeyModifierKey: Int] = [:]
    /// A key that went down with other modifiers: no press until released.
    private var heldIneligible: Set<HotkeyModifierKey> = []
    /// Event times of every delivered event that had the key down alone,
    /// whether or not the release before it was delivered.
    private var deliveredDowns: [HotkeyModifierKey: [TimeInterval]] = [:]
    private var nextID = 0

    /// A physical `flagsChanged` seen by the probe.
    mutating func physical(rawFlags: UInt64, eventTime: TimeInterval, seenAt: TimeInterval,
                           watched: Set<HotkeyModifierKey>) -> [Change] {
        var changes: [Change] = []
        for key in HotkeyModifierKey.allCases {
            let held = HotkeyFlags.isHeld(key, rawFlags)
            if let id = heldPress[key] {
                if !held {
                    heldPress[key] = nil
                    presses[id]?.endTime = eventTime
                    presses[id]?.endSeenAt = seenAt
                    if presses[id]?.eligible == true { changes.append(.ended(id: id, at: seenAt)) }
                } else if !HotkeyFlags.isOnly(key, rawFlags) {
                    presses[id]?.eligible = false // Shift added: the gesture is cancelled
                }
            } else if held {
                guard !heldIneligible.contains(key) else { continue }
                guard watched.contains(key), HotkeyFlags.isOnly(key, rawFlags) else {
                    heldIneligible.insert(key)
                    continue
                }
                let id = nextID
                nextID += 1
                presses[id] = Press(id: id, key: key, eventTime: eventTime, seenAt: seenAt)
                heldPress[key] = id
                changes.append(.began(id: id, at: seenAt))
            } else {
                heldIneligible.remove(key)
            }
        }
        prune(now: seenAt)
        return changes
    }

    /// A `flagsChanged` that reached Whytap's shortcut monitors. Returns the
    /// presses already judged blocked that this delivery proves arrived.
    ///
    /// Every event with the key down alone is kept by its own event time,
    /// with no delivered press boundaries: a release that never reached the
    /// monitors cannot hide the next press. Which press an event belongs to
    /// is decided by the physical presses' boundaries alone.
    mutating func delivered(rawFlags: UInt64, eventTime: TimeInterval) -> [Int] {
        var reversed: [Int] = []
        for key in HotkeyModifierKey.allCases where HotkeyFlags.isOnly(key, rawFlags) {
            deliveredDowns[key, default: []].append(eventTime)
            if deliveredDowns[key]!.count > 64 { deliveredDowns[key]!.removeFirst() }
            for (id, press) in presses where press.key == key && press.verdict == .blocked(key)
                && Self.matches(press, eventTime) {
                presses[id]?.verdict = .delivered(key)
                reversed.append(id)
            }
        }
        return reversed
    }

    /// The key stopped being a shortcut: its presses, held or awaiting a
    /// verdict, are retired, and a press still held starts nothing new.
    mutating func retire(keysOutside watched: Set<HotkeyModifierKey>) {
        for (id, press) in presses where !watched.contains(press.key) && press.verdict == nil {
            presses[id]?.eligible = false
        }
        for key in HotkeyModifierKey.allCases where !watched.contains(key) {
            if heldPress.removeValue(forKey: key) != nil { heldIneligible.insert(key) }
        }
    }

    /// The press began in a context that cannot be established: it is
    /// retired unjudged.
    mutating func retire(_ id: Int) {
        presses[id]?.eligible = false
    }

    /// The verdict for a press, once it is due: nil before its deadline, for
    /// a retired or unknown press, or when already given.
    mutating func decide(_ id: Int, now: TimeInterval) -> Verdict? {
        guard var press = presses[id], press.eligible, press.verdict == nil else { return nil }
        if let endSeenAt = press.endSeenAt {
            guard now - endSeenAt >= Self.decisionDelay - 0.000_1 else { return nil }
        } else {
            guard now - press.seenAt >= Self.holdDecision - 0.000_1 else { return nil }
        }
        let arrived = (deliveredDowns[press.key] ?? []).contains { Self.matches(press, $0) }
        press.verdict = arrived ? .delivered(press.key) : .blocked(press.key)
        presses[id] = press
        return press.verdict
    }

    /// The probe stopped, restarted or the session went inactive: nothing
    /// seen so far can be judged any more.
    mutating func reset() {
        presses = [:]
        heldPress = [:]
        heldIneligible = []
    }

    private static func matches(_ press: Press, _ delivered: TimeInterval) -> Bool {
        if abs(delivered - press.eventTime) <= tolerance { return true }
        let end = press.endTime ?? .infinity
        return delivered >= press.eventTime - tolerance && delivered <= end + tolerance
    }

    private mutating func prune(now: TimeInterval) {
        for (id, press) in presses where now - press.seenAt > Self.retention {
            presses[id] = nil
            if heldPress[press.key] == id { heldPress[press.key] = nil }
        }
    }
}
