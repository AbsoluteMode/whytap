import AppKit
import CoreGraphics
import os

/// Whytap's view of a modifier press before any other app's session tap.
@MainActor
protocol HotkeyPressProbing: AnyObject {
    var isRunning: Bool { get }
    /// `deliver` gets the raw flags of each hardware `flagsChanged` and the
    /// uptime the probe saw it at. Returns false when the tap cannot exist
    /// (no Accessibility).
    func start(deliver: @escaping @MainActor (UInt64, TimeInterval) -> Void,
               onFailure: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

/// A HID-level event tap on `flagsChanged` only, inserted at the head, on its
/// own thread. It returns every event untouched and reads only which
/// modifiers are down and who posted the event: no ordinary keys, no
/// characters, nothing logged or stored. It is an active (`.defaultTap`) tap because that is what
/// Accessibility allows; a listen-only tap needs Input Monitoring, which
/// Whytap asks for only as a fallback.
// WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md
@MainActor
final class HotkeyPressProbe: HotkeyPressProbing {
    /// A tap macOS keeps disabling with no event in between is given up, as
    /// in SpaceHoldMonitor and Brightness keys.
    static let maxConsecutiveReenables = 3

    private var session: HotkeyPressProbeSession?

    var isRunning: Bool { session != nil }

    func start(deliver: @escaping @MainActor (UInt64, TimeInterval) -> Void,
               onFailure: @escaping @MainActor () -> Void) -> Bool {
        stop()
        let session = HotkeyPressProbeSession(deliver: deliver, onFailure: onFailure)
        session.owner = self
        activeHotkeyPressProbeSession.withLock { $0 = session }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        guard session.thread.installTap(mask: mask, placement: .headInsertEventTap, location: .cghidEventTap,
                                        callback: hotkeyPressProbeCallback) != nil else {
            activeHotkeyPressProbeSession.withLock { if $0 === session { $0 = nil } }
            return false
        }
        self.session = session
        return true
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        activeHotkeyPressProbeSession.withLock { if $0 === session { $0 = nil } }
        session.thread.enableTap(false)
    }

    fileprivate func tapWasDisabled(_ disabled: HotkeyPressProbeSession, attempt: Int) {
        guard session === disabled else { return }
        if attempt <= Self.maxConsecutiveReenables, AXIsProcessTrusted() {
            disabled.thread.enableTap(true)
        } else {
            stop()
            disabled.onFailure()
        }
    }
}

private let hotkeyPressProbeOwnPID = ProcessInfo.processInfo.processIdentifier

/// The installed probe, for the C callback, which cannot capture it.
private let activeHotkeyPressProbeSession = OSAllocatedUnfairLock<HotkeyPressProbeSession?>(initialState: nil)

private final class HotkeyPressProbeSession: @unchecked Sendable {
    let thread = SpaceHoldMonitor.TapThread(queueLabel: "com.rootwise.sidekey.hotkey-press-probe")
    let deliver: @MainActor (UInt64, TimeInterval) -> Void
    let onFailure: @MainActor () -> Void
    let reenables = OSAllocatedUnfairLock(initialState: 0)
    /// Main thread only.
    weak var owner: HotkeyPressProbe?

    init(deliver: @escaping @MainActor (UInt64, TimeInterval) -> Void, onFailure: @escaping @MainActor () -> Void) {
        self.deliver = deliver
        self.onFailure = onFailure
    }
}

private func hotkeyPressProbeCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                      userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let unchanged = Unmanaged.passUnretained(event)
    guard let session = activeHotkeyPressProbeSession.withLock({ $0 }) else { return unchanged }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let attempt = session.reenables.withLock { count in
            count += 1
            return count
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.owner?.tapWasDisabled(session, attempt: attempt) }
        }
        return unchanged
    }
    guard type == .flagsChanged else { return unchanged }
    session.reenables.withLock { $0 = 0 }
    // Whytap's own posted events are not presses. Another app's posted
    // modifier counts: whether hardware events carry pid 0 is not verified,
    // and a stricter filter could hide every press.
    guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(hotkeyPressProbeOwnPID) else { return unchanged }
    // The main thread can be busy, so the press keeps the time it was seen.
    let seenAt = ProcessInfo.processInfo.systemUptime
    let flags = event.flags.rawValue
    DispatchQueue.main.async {
        MainActor.assumeIsolated { session.deliver(flags, seenAt) }
    }
    return unchanged
}
