import AppKit
import os.log

/// Lifecycle adapter for an agent answer close shortcut. Two concrete
/// adapters share it: `CarbonResponseCloseHotkey` (the user-configurable ⌥Q,
/// a Carbon hotkey) and `EscapeCloseEventMonitor` (the fixed bare Escape, a
/// PASSIVE NSEvent observer). The owner keeps one instance of each alive
/// across `start()` / `stop()` cycles — `start()` registers the shortcut,
/// `stop()` tears it down. The callback wired via `setOnHotkey` must funnel
/// into the same dismiss path as the close button so panel close is a single
/// source of truth.
@MainActor
protocol AgentResponseCloseHotkeyControlling: AnyObject {
    func setOnHotkey(_ handler: @escaping () -> Void)
    func start() throws
    func stop()
}

/// Production wiring of the answer panel's Option+Q close hotkey on top
/// of `CarbonHotkeyMonitor`. Splits the protocol's `setOnHotkey` /
/// `start()` / `stop()` lifecycle from `CarbonHotkeyMonitor`'s init-time
/// closure capture — the owner constructs the adapter first and wires
/// the callback in once it has a `self` reference, then `start()`s
/// only when the answer surface is visible.
@MainActor
final class CarbonResponseCloseHotkey: AgentResponseCloseHotkeyControlling {
    private let hotkeyPreferences: HotkeyPreferences
    private var monitor: HotkeyShortcutMonitor?
    private var onHotkey: (() -> Void)?

    init(hotkeyPreferences: HotkeyPreferences) {
        self.hotkeyPreferences = hotkeyPreferences
    }

    func setOnHotkey(_ handler: @escaping () -> Void) {
        self.onHotkey = handler
        // If start() already constructed the monitor, tear it down so
        // the next start() rebuilds with the new handler. Callers in
        // this codebase wire the handler BEFORE start(), so this is
        // defensive.
        if let monitor {
            monitor.stop()
        }
        self.monitor = nil
    }

    func start() throws {
        let handler = onHotkey ?? {}
        monitor?.stop()
        let shortcut = hotkeyPreferences.agentCloseShortcut
        let active = HotkeyShortcutMonitor(
            shortcut: shortcut,
            hotKeyIDValue: CarbonHotkeyMonitor.responseCloseHotKeyID,
            onHotkey: handler
        )
        monitor = active
        try active.start()
    }

    func stop() {
        monitor?.stop()
    }
}

/// Production wiring of the answer panel's bare-Escape close. Unlike
/// `CarbonResponseCloseHotkey` (the configurable ⌥Q) this one is FIXED by
/// product — Escape with no chord modifiers — and reads no preference.
///
/// Deliberately NOT a Carbon hotkey: a bare-Escape `RegisterEventHotKey`
/// steals the key system-wide (before the frontmost app sees it), which is
/// the recurring "Escape stops working in other apps" bug. And gating a grab
/// on whytap-frontmost kills Esc-close entirely, because whytap is an
/// accessory app whose non-activating island panel never makes it frontmost.
/// Passive NSEvent monitors resolve both: the answer closes on Esc from
/// anywhere, while the key still reaches the app the user is working in
/// (that app may also act on it — the accepted trade-off). The global
/// monitor needs Accessibility, which the agent gesture already requires;
/// without it Esc-close degrades to ✕/⌥Q, same soft-fail contract as ⌥Q.
/// WHY: docs/decisions/2026-07-02-escape-close-passive-monitor.md
@MainActor
final class EscapeCloseEventMonitor: AgentResponseCloseHotkeyControlling {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey")

    /// `NSEvent.keyCode` for Escape (kVK_Escape).
    private static let escapeKeyCode = UInt16(CarbonHotkeyMonitor.escapeKeyCode)

    /// Global monitor: Escape pressed while ANOTHER app is frontmost (the
    /// normal case — accessory app, non-activating answer panel). Local
    /// monitor: Escape pressed while a whytap window happens to be key
    /// (e.g. Settings open next to a visible answer). Both are passive.
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onHotkey: (() -> Void)?

    /// Bare Escape = the Escape key with no chord modifier held. Keyboard
    /// STATE flags (Caps Lock, fn) don't make a chord — Esc stays Esc.
    nonisolated static func isBareEscape(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == escapeKeyCode else { return false }
        return modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    func setOnHotkey(_ handler: @escaping () -> Void) {
        self.onHotkey = handler
    }

    func start() throws {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent monitor handlers run on the installing (main) thread.
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            // Passive: never swallow — key windows (Settings etc.) keep
            // their own Escape semantics.
            return event
        }
        if globalMonitor == nil {
            // Accessibility missing (or monitor creation failed): Esc-close
            // only works while a whytap window is key. ✕/⌥Q still close.
            os_log(
                "escape_close_global_monitor_unavailable",
                log: Self.log, type: .default
            )
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard Self.isBareEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else { return }
        onHotkey?()
    }
}
