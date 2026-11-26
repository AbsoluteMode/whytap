import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os.log

/// What the indicator shows: the holder app, or nil when it is unknown.
struct SecureInputHolderBadge: Equatable {
    let app: SecureInputApp?

    var label: String {
        "\(app?.name ?? "Another app") holds secure input — close its password field"
    }
}

@MainActor
protocol SecureInputHolderPresenting: AnyObject {
    /// `persistent` keeps the badge until `dismiss()`; otherwise it fades on
    /// its own. `shake` plays the macOS wrong-password shake.
    func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool)
    func dismiss()
}

/// Makes Whytap shortcuts fail loudly instead of silently while another app
/// holds Secure Event Input (an open password field, or an app such as a
/// browser that forgot to release it after Cmd-Tab).
///
/// Whytap cannot and does not get around secure input. It watches the one
/// signal secure input leaves it, modifier changes, and points at the
/// holder: the holder's logo appears to the right of the island and shakes
/// when a shortcut that could not arrive was tried. While a background app
/// keeps secure input on, the logo stays there, dimmed.
// WHY: .project-docs/decisions/2026-11-26-secure-input-holder.md
@MainActor
final class SecureInputGuard {
    struct System {
        var isSecureInputEnabled: @MainActor () -> Bool
        var frontmostApp: @MainActor () -> SecureInputApp?
        var focusedElementIsSecure: @MainActor (pid_t) -> Bool
        var isRunning: @MainActor (pid_t) -> Bool
        var ownPID: pid_t
        var blockedChords: @MainActor () -> Set<ModifierChord>
        var lastHotkeyFire: @MainActor () -> Date?
        var now: @MainActor () -> Date
        /// Runs `work` once the app that lost focus had time to release.
        var afterSwitchSettles: (@escaping @MainActor () -> Void) -> Void
    }

    static let shared = SecureInputGuard(system: .live, makePresenter: { SecureInputHolderPanel.shared })

    nonisolated static let switchSettleDelay: TimeInterval = 0.4
    static let pollInterval: TimeInterval = 1
    static let minimumShakeInterval: TimeInterval = 0.6

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey")

    private let system: System
    private let makePresenter: () -> SecureInputHolderPresenting
    private lazy var presenter: SecureInputHolderPresenting = makePresenter()

    private var tracker = SecureInputHolderTracker()
    private var detector = SecureInputAttemptDetector()
    private var lastFront: SecureInputApp?
    private var lastShake: Date?
    private(set) var persistentBadge: SecureInputHolderBadge?
    private var pollTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init(system: System, makePresenter: @escaping () -> SecureInputHolderPresenting) {
        self.system = system
        self.makePresenter = makePresenter
    }

    var isStarted: Bool { globalMonitor != nil || activationObserver != nil }

    /// Idempotent. Installs a `flagsChanged` monitor (no key contents, only
    /// which modifiers are down) and an app-activation observer.
    func start() {
        guard !isStarted else { return }
        lastFront = system.frontmostApp()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let chord = ModifierChord(eventFlags: event.modifierFlags)
            MainActor.assumeIsolated { self?.handleFlagsChanged(chord) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(ModifierChord(eventFlags: event.modifierFlags))
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                .map(SecureInputApp.init(running:))
            MainActor.assumeIsolated { self?.handleActivation(app) }
        }
    }

    // MARK: - Events (internal for tests)

    func handleFlagsChanged(_ chord: ModifierChord) {
        let now = system.now()
        guard chord.isEmpty else {
            _ = detector.flagsChanged(to: chord, at: now, lastHotkeyFire: nil, blockedChords: [])
            return
        }
        // Every modifier release on the Mac lands here; with secure input off
        // it costs one flag read.
        guard system.isSecureInputEnabled() else {
            _ = detector.flagsChanged(to: [], at: now, lastHotkeyFire: nil, blockedChords: [])
            secureInputEnded()
            return
        }
        let attempt = detector.flagsChanged(
            to: [], at: now,
            lastHotkeyFire: system.lastHotkeyFire(),
            blockedChords: system.blockedChords()
        )
        guard attempt else { return }
        reportBlockedAttempt(at: now)
    }

    func handleActivation(_ app: SecureInputApp?) {
        let previous = lastFront
        lastFront = app
        system.afterSwitchSettles { [weak self] in self?.settleSwitch(from: previous, to: app) }
    }

    func settleSwitch(from previous: SecureInputApp?, to current: SecureInputApp?) {
        tracker.didSwitch(from: previous, to: current, secureInputOn: system.isSecureInputEnabled())
        refresh()
    }

    /// Re-reads secure input and keeps the dimmed badge in step with it.
    /// The 1 s check passes `askAccessibility: false`, so a busy frontmost
    /// app is never queried every second.
    func refresh(askAccessibility: Bool = true) {
        switch resolveHolder(askAccessibility: askAccessibility) {
        case .app(let app, inBackground: true):
            let badge = SecureInputHolderBadge(app: app)
            if persistentBadge != badge {
                persistentBadge = badge
                presenter.present(badge, shake: false, persistent: true)
                os_log("secure_input_stuck holder=%{private}@", log: Self.log, type: .info,
                       app.bundleID ?? app.name)
            }
        case .none:
            secureInputEnded()
            return
        case .app, .ownApp, .unknown:
            dismissPersistent()
        }
        updatePolling()
    }

    // MARK: - Private

    private func resolveHolder(askAccessibility: Bool = true) -> SecureInputHolder {
        let on = system.isSecureInputEnabled()
        guard on else { return .none }
        let front = system.frontmostApp()
        // Ask Accessibility only when it decides between the remembered
        // background app and the frontmost one.
        var frontHasSecureField = false
        if askAccessibility, let candidate = tracker.staleCandidate, let front, candidate.pid != front.pid {
            frontHasSecureField = system.focusedElementIsSecure(front.pid)
        }
        return tracker.resolve(secureInputOn: on, front: front, frontHasSecureField: frontHasSecureField,
                               ownPID: system.ownPID, isRunning: system.isRunning)
    }

    private func reportBlockedAttempt(at now: Date) {
        let holder = resolveHolder()
        let badge: SecureInputHolderBadge
        let persistent: Bool
        switch holder {
        case .none:
            return
        case .ownApp:
            os_log("secure_input_attempt holder=self", log: Self.log, type: .info)
            return
        case .app(let app, let inBackground):
            badge = SecureInputHolderBadge(app: app)
            persistent = inBackground
        case .unknown:
            badge = SecureInputHolderBadge(app: nil)
            persistent = false
        }
        if let lastShake, now.timeIntervalSince(lastShake) < Self.minimumShakeInterval { return }
        lastShake = now
        if persistent { persistentBadge = badge } else { persistentBadge = nil }
        presenter.present(badge, shake: true, persistent: persistent)
        os_log("secure_input_attempt holder=%{private}@ background=%{public}d", log: Self.log, type: .info,
               badge.app?.bundleID ?? badge.app?.name ?? "unknown", persistent ? 1 : 0)
        updatePolling()
    }

    private func secureInputEnded() {
        tracker.secureInputObservedOff()
        if persistentBadge != nil {
            persistentBadge = nil
            presenter.dismiss()
            os_log("secure_input_released", log: Self.log, type: .info)
        }
        updatePolling()
    }

    private func dismissPersistent() {
        guard persistentBadge != nil else { return }
        persistentBadge = nil
        presenter.dismiss()
    }

    /// A 1 s check runs only while a background holder is remembered, so
    /// the badge leaves as soon as secure input does.
    private func updatePolling() {
        let needed = tracker.staleCandidate != nil || persistentBadge != nil
        if needed, pollTimer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(askAccessibility: false) }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !needed {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    #if DEBUG
    var isPolling: Bool { pollTimer != nil }
    func stopPollingForTesting() { pollTimer?.invalidate(); pollTimer = nil }
    #endif
}

extension SecureInputGuard.System {
    @MainActor static var live: Self {
        Self(
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            frontmostApp: { NSWorkspace.shared.frontmostApplication.map(SecureInputApp.init(running:)) },
            focusedElementIsSecure: SecureInputGuard.focusedElementIsSecure(pid:),
            isRunning: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                return !app.isTerminated
            },
            ownPID: ProcessInfo.processInfo.processIdentifier,
            blockedChords: { SecureInputBlockedShortcuts.chords(in: HotkeyPreferences.shared.configuration) },
            lastHotkeyFire: { HotkeyFireRecorder.lastFire },
            now: Date.init,
            afterSwitchSettles: { work in
                DispatchQueue.main.asyncAfter(deadline: .now() + SecureInputGuard.switchSettleDelay) {
                    MainActor.assumeIsolated { work() }
                }
            }
        )
    }
}

extension SecureInputGuard {
    /// Whether the app's focused element is a password field. Reads only the
    /// element's role, never its value; a short timeout keeps a busy app
    /// from stalling the main thread.
    nonisolated static func focusedElementIsSecure(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        for attribute in [kAXSubroleAttribute, kAXRoleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               (value as? String) == (kAXSecureTextFieldSubrole as String) {
                return true
            }
        }
        return false
    }
}

extension SecureInputApp {
    init(running app: NSRunningApplication) {
        self.init(pid: app.processIdentifier,
                  name: app.localizedName ?? app.bundleIdentifier ?? "An app",
                  bundleID: app.bundleIdentifier)
    }
}

extension ModifierChord {
    init(eventFlags flags: NSEvent.ModifierFlags) {
        var chord: ModifierChord = []
        if flags.contains(.option) { chord.insert(.option) }
        if flags.contains(.shift) { chord.insert(.shift) }
        if flags.contains(.control) { chord.insert(.control) }
        if flags.contains(.command) { chord.insert(.command) }
        self = chord
    }
}
