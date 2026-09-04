import AppKit
import CoreGraphics
import Foundation
import os.log

protocol HotkeyShortcutMonitoring: AnyObject {
    func start() throws
    func stop()
}

extension CarbonHotkeyMonitor: HotkeyShortcutMonitoring {}

final class HotkeyShortcutMonitor: HotkeyShortcutMonitoring {
    typealias Callback = () -> Void
    typealias SuppressionGate = () -> Bool

    private let monitor: HotkeyShortcutMonitoring

    /// - Parameters:
    ///   - onHotkeyReleased: release/stop hook; `nil` no-ops on release. Drop
    ///     registrations routed to the `SpaceHoldMonitor` tap must pass it — a
    ///     nil release leaves the Drop mic stoppable only via Escape (asserted
    ///     on the Drop-only hold-combo route).
    ///   - onCancel: discard hook used **only** by the CGEventTap-backed
    ///     `SpaceHoldMonitor` path — both `.holdSpace` and a swallowed hold-combo
    ///     Drop (Escape while recording → drop the take without transcribing).
    ///     The Carbon/modifier monitors have no cancel gesture, so it is ignored
    ///     for them. Threaded as an extra parameter here rather than on
    ///     `HotkeyShortcutMonitoring` so the generic protocol (`start()`/`stop()`)
    ///     stays unchanged. When `nil`, cancel is a no-op.
    ///   - dropHoldSwallow: set **only** by the Drop registration when Drop is a
    ///     hold-combo (`.combo` + gesture `.hold`). It routes the combo through
    ///     the generalized `SpaceHoldMonitor` CGEventTap (which swallows the
    ///     bound character so e.g. ∂ never prints and adds Escape-cancel) instead
    ///     of Carbon `RegisterEventHotKey`. Defaults to `false`, so every other
    ///     combo (agent close, hover ⌥1..5, history, help, agent text/voice)
    ///     keeps the Carbon route with no Input Monitoring and no swallow.
    ///     Ignored for `.holdSpace` (already the tap) and `.modifier`.
    init(
        shortcut: HotkeyShortcut,
        hotKeyIDValue: UInt32,
        onHotkey: @escaping Callback,
        onHotkeyReleased: Callback? = nil,
        onCancel: Callback? = nil,
        shouldSuppress: SuppressionGate? = nil,
        dropHoldSwallow: Bool = false,
        onAccessibilityLost: Callback? = nil
    ) {
        switch shortcut {
        case .combo(let combo) where dropHoldSwallow:
            // Hold-combo Drop: the SAME active CGEventTap the hold-Space Drop
            // uses, generalized to this combo's key + modifiers. It swallows the
            // bound character from the first keyDown (so ∂ never prints) and
            // honours `onCancel` (Escape), neither of which the Carbon path can
            // do. Gated by Input Monitoring (requested in `registerHotkey`).
            // A nil release would leave the mic stoppable only via Escape.
            assert(onHotkeyReleased != nil, "SpaceHold-routed Drop requires a release handler")
            monitor = SpaceHoldMonitor(
                triggerKeyCode: CGKeyCode(combo.keyCode),
                requiredModifiers: combo.cgEventFlags,
                onHotkey: onHotkey,
                onHotkeyReleased: onHotkeyReleased ?? {},
                onCancel: onCancel ?? {},
                onAccessibilityLost: onAccessibilityLost ?? {}
            )
        case .combo(let combo):
            monitor = CarbonHotkeyMonitor(
                keyCode: combo.keyCode,
                modifiers: combo.modifiers,
                hotKeyIDValue: hotKeyIDValue,
                onHotkey: onHotkey,
                onHotkeyReleased: onHotkeyReleased,
                shouldSuppress: shouldSuppress
            )
        case .modifier(let key):
            monitor = ModifierOnlyHotkeyMonitor(
                key: key,
                onHotkey: onHotkey,
                onHotkeyReleased: onHotkeyReleased,
                shouldSuppress: shouldSuppress
            )
        case .holdSpace:
            // CGEventTap-backed Space-hold Drop trigger. Gated by Input
            // Monitoring. `onHotkeyReleased` stops + transcribes on release;
            // `onCancel` discards on Escape. Default Drop binding.
            // `.holdSpace` is Drop-only by TWO guards: the Settings recording
            // gate (`assignShortcut` rejects it for non-Drop targets, B3) and
            // the load normalization (`HotkeyPreferences.nonDropShortcut`
            // treats a stale persisted non-Drop `.holdSpace` as a decode
            // failure). Any registration reaching this path is therefore a
            // Drop and must pass a release handler — a nil release leaves the
            // mic stoppable only via Escape.
            assert(onHotkeyReleased != nil, "SpaceHold-routed Drop requires a release handler")
            monitor = SpaceHoldMonitor(
                onHotkey: onHotkey,
                onHotkeyReleased: onHotkeyReleased ?? {},
                onCancel: onCancel ?? {},
                onAccessibilityLost: onAccessibilityLost ?? {}
            )
        }
    }

    /// Whether a Drop binding runs on the CGEventTap (`SpaceHoldMonitor`) and
    /// therefore needs Input Monitoring and the keystroke-swallow route.
    ///
    /// `true` for hold-Space and a hold-combo Drop (both swallow the keystroke
    /// through the tap); `false` for a tap-combo Drop (deferred; would use
    /// Carbon) and a modifier Drop. This is the single predicate behind both the
    /// `dropHoldSwallow` routing flag and the `registerHotkey` Input Monitoring
    /// gate, so the two never drift.
    static func isDropHoldTap(shortcut: HotkeyShortcut, gesture: HotkeyGesture) -> Bool {
        switch shortcut {
        case .holdSpace:
            return true
        case .combo:
            return gesture == .hold
        case .modifier:
            return false
        }
    }

    func start() throws {
        try monitor.start()
    }

    func stop() {
        monitor.stop()
    }

    #if DEBUG
    /// Test-only: the shortcut was routed to a Carbon `RegisterEventHotKey`
    /// monitor (`.combo`). Lets routing tests assert the dispatch without
    /// calling `start()`, which would touch real Carbon / Input Monitoring.
    var routedMonitorIsCarbon: Bool { monitor is CarbonHotkeyMonitor }

    /// Test-only: the shortcut was routed to the CGEventTap Space-hold monitor
    /// (`.holdSpace`).
    var routedMonitorIsSpaceHold: Bool { monitor is SpaceHoldMonitor }
    #endif
}

final class ModifierOnlyHotkeyMonitor: HotkeyShortcutMonitoring {
    typealias Callback = () -> Void
    typealias SuppressionGate = () -> Bool

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey")
    private static let monitoredEvents: NSEvent.EventTypeMask = [.flagsChanged]

    private let key: HotkeyModifierKey
    private let onHotkey: Callback
    private let onHotkeyReleased: Callback?
    private let shouldSuppress: SuppressionGate?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isHeld = false

    init(
        key: HotkeyModifierKey,
        onHotkey: @escaping Callback,
        onHotkeyReleased: Callback? = nil,
        shouldSuppress: SuppressionGate? = nil
    ) {
        self.key = key
        self.onHotkey = onHotkey
        self.onHotkeyReleased = onHotkeyReleased
        self.shouldSuppress = shouldSuppress
    }

    deinit {
        stop()
    }

    func start() throws {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.monitoredEvents) { [weak self] event in
            self?.handle(event)
        }
        if globalMonitor == nil {
            os_log("modifier monitor global install failed", log: Self.log, type: .error)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.monitoredEvents) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isHeld = false
    }

    private func handle(_ event: NSEvent) {
        let rawFlags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        let held = HotkeyFlags.isHeld(key, rawFlags)
        if held && !isHeld && HotkeyFlags.isOnly(key, rawFlags) {
            isHeld = true
            guard shouldSuppress?() != true else { return }
            DispatchQueue.main.async(execute: onHotkey)
        } else if !held && isHeld {
            isHeld = false
            if let onHotkeyReleased {
                DispatchQueue.main.async(execute: onHotkeyReleased)
            }
        }
    }
}
