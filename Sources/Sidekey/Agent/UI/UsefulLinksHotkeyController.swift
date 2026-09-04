import Carbon.HIToolbox
import Foundation
import os.log

/// Protocol seam for one of the four configurable Useful Links hotkeys the
/// selection chip drives. The real implementation is a Carbon
/// `RegisterEventHotKey` wrapper; tests substitute a fake monitor that
/// records `start()` / `stop()` and lets the test fire the callback
/// directly. Mirrors the `AgentResponseCloseHotkeyControlling` pattern
/// used by `AgentResponsePanel` for its ⌥Q close hotkey.
@MainActor
protocol UsefulLinksHotkeyControlling: AnyObject {
    func setOnHotkey(_ handler: @escaping () -> Void)
    func start() throws
    func stop()
}

/// Carbon `RegisterEventHotKey`-backed implementation of
/// `UsefulLinksHotkeyControlling`. Boxes one `CarbonHotkeyMonitor`. Kept
/// as a small wrapper rather than reusing the production class directly
/// so the controller can talk to one protocol regardless of test vs.
/// prod, and so the (keyCode, modifiers, id) triple comes in via the
/// factory at construction time.
@MainActor
final class CarbonUsefulLinksHotkey: UsefulLinksHotkeyControlling {
    private let shortcut: HotkeyShortcut
    private let hotKeyIDValue: UInt32
    private var monitor: HotkeyShortcutMonitor?
    private var onHotkey: () -> Void = {}

    init(shortcut: HotkeyShortcut, hotKeyIDValue: UInt32) {
        self.shortcut = shortcut
        self.hotKeyIDValue = hotKeyIDValue
    }

    func setOnHotkey(_ handler: @escaping () -> Void) {
        self.onHotkey = handler
    }

    func start() throws {
        // Re-build the inner monitor so the latest captured handler
        // wins. `CarbonHotkeyMonitor.start()` itself is idempotent
        // (calls stop() internally first) but we want a fresh
        // closure binding when the controller's `onInsert` etc. is
        // reassigned between starts.
        let handler = onHotkey
        let active = HotkeyShortcutMonitor(
            shortcut: shortcut,
            hotKeyIDValue: hotKeyIDValue,
            onHotkey: handler
        )
        try active.start()
        monitor = active
    }

    func stop() {
        monitor?.stop()
        monitor = nil
    }
}

/// Orchestrates the four actions hotkeys the selection chip needs. The
/// default set is `⌥←/⌥→/⌥↓/⌥↑`, but every combo comes from
/// `HotkeyConfiguration`. Activation policy depends on the item count AND on
/// whether the currently selected item supports `open`:
///
/// - `count == 0` — nothing registered; equivalent to `stop()`.
/// - `count >= 1` — Insert always registers; Open registers only when
///   `openAvailable` (false for a selected `copy` item — insert-only).
/// - `count >= 2` — next / previous nav register in addition.
///
/// `start(itemCount:openAvailable:)` is idempotent: calling it again rebuilds
/// the monitor set. A repeated call tears down the previous monitors and
/// re-registers them, so `onInsert` / `onOpen` / `onNext` / `onPrevious`
/// reassignments take effect on the next call without surprises. The panel
/// re-calls it whenever the selection moves so Open follows the selected item's
/// type.
///
/// The controller does NOT own the selection state or the focus
/// snapshot — those live on the response panel content view and the
/// agent controller respectively. Hotkey activations just call the
/// four closures the panel installs.
@MainActor
final class UsefulLinksHotkeyController {
    typealias ConfigurationProvider = @MainActor () -> HotkeyConfiguration
    typealias MonitorFactory = @MainActor (
        _ shortcut: HotkeyShortcut,
        _ hotKeyIDValue: UInt32
    ) -> UsefulLinksHotkeyControlling

    /// Callbacks invoked when each hotkey fires. Default to no-op so a
    /// caller that wires them lazily doesn't crash on early fires.
    var onInsert: () -> Void = {}
    var onOpen: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}

    private let configurationProvider: ConfigurationProvider
    private let monitorFactory: MonitorFactory
    private var monitors: [UsefulLinksHotkeyControlling] = []

    private static let log = OSLog(
        subsystem: "com.rootwise.sidekey",
        category: "useful-links-hotkey"
    )

    init(
        configurationProvider: ConfigurationProvider? = nil,
        monitorFactory: MonitorFactory? = nil
    ) {
        self.configurationProvider = configurationProvider ?? { HotkeyPreferences.shared.configuration }
        self.monitorFactory = monitorFactory ?? Self.defaultFactory
    }

    /// Rebuilds the active monitor set to match the visible actions block size
    /// and the selected item's capabilities. Calling with `itemCount = 0` is
    /// the same as `stop()`. `openAvailable` gates the Open (→) hotkey — pass
    /// `false` when the selected item is insert-only (a copy item).
    /// Idempotent: repeated calls always tear down the previous set.
    func start(itemCount: Int, openAvailable: Bool) {
        stop()
        guard itemCount > 0 else { return }

        let configuration = configurationProvider()
        register(
            shortcut: configuration.usefulLinksInsertShortcut,
            hotKeyIDValue: CarbonHotkeyMonitor.usefulLinksInsertHotKeyID,
            handler: { [weak self] in self?.onInsert() }
        )
        if openAvailable {
            register(
                shortcut: configuration.usefulLinksOpenShortcut,
                hotKeyIDValue: CarbonHotkeyMonitor.usefulLinksOpenHotKeyID,
                handler: { [weak self] in self?.onOpen() }
            )
        }

        guard itemCount >= 2 else { return }

        register(
            shortcut: configuration.usefulLinksNextShortcut,
            hotKeyIDValue: CarbonHotkeyMonitor.usefulLinksDownHotKeyID,
            handler: { [weak self] in self?.onNext() }
        )
        register(
            shortcut: configuration.usefulLinksPreviousShortcut,
            hotKeyIDValue: CarbonHotkeyMonitor.usefulLinksUpHotKeyID,
            handler: { [weak self] in self?.onPrevious() }
        )
    }

    /// Tears down every registered monitor. Safe to call repeatedly.
    func stop() {
        for monitor in monitors {
            monitor.stop()
        }
        monitors.removeAll()
    }

    deinit {
        // `stop()` requires MainActor. Carbon registrations leak only if
        // the controller is dropped without an explicit `stop()` — the
        // response panel always calls `stop()` in its `close()` path so
        // this deinit path is defensive only.
        for monitor in monitors {
            MainActor.assumeIsolated {
                monitor.stop()
            }
        }
    }

    private func register(
        shortcut: HotkeyShortcut,
        hotKeyIDValue: UInt32,
        handler: @escaping () -> Void
    ) {
        let monitor = monitorFactory(
            shortcut,
            hotKeyIDValue
        )
        monitor.setOnHotkey(handler)
        do {
            try monitor.start()
            monitors.append(monitor)
        } catch {
            // Carbon `RegisterEventHotKey` can return paramErr /
            // eventInternalErr (e.g. on a hot-key collision with another
            // app holding the same combo). Soft-fail: log it, leave the
            // chip / click path working. The hotkey is a power-user
            // accelerator — the chip still opens on click.
            os_log(
                "register failed shortcut=%{public}@ id=%{public}u err=%{public}@",
                log: Self.log, type: .error,
                shortcut.title,
                hotKeyIDValue,
                String(describing: error)
            )
        }
    }

    /// Production factory — wraps `CarbonHotkeyMonitor`.
    private static let defaultFactory: MonitorFactory = { shortcut, hotKeyIDValue in
        CarbonUsefulLinksHotkey(
            shortcut: shortcut,
            hotKeyIDValue: hotKeyIDValue
        )
    }
}
