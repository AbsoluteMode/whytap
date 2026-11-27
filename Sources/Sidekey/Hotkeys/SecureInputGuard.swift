import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os.log

/// What the indicator shows: the holder app, or nil when it is unknown.
/// The same badge names an app that intercepts a Whytap shortcut with its
/// own event tap; `message` then replaces the Secure Input sentence.
// WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md
struct SecureInputHolderBadge: Equatable {
    let app: SecureInputApp?
    var message: String? = nil

    var label: String {
        message ?? "\(app?.name ?? "Another app") holds secure input — close its password field"
    }

    /// Shown when the app has no logo: a lock for Secure Input, a keyboard
    /// for an interceptor.
    var fallbackSymbol: String { message == nil ? "lock.fill" : "keyboard" }
}

@MainActor
protocol SecureInputHolderPresenting: AnyObject {
    /// `persistent` keeps the badge until `dismiss()`; otherwise it fades on
    /// its own. `shake` plays the macOS wrong-password shake.
    func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool)
    func dismiss()
    /// Whether a badge is on screen (a shaken one fades on its own).
    var isShowing: Bool { get }
}

/// Makes Whytap shortcuts fail loudly instead of silently while another app
/// holds Secure Event Input (an open password field, or an app such as a
/// browser that forgot to release it after Cmd-Tab).
///
/// Whytap cannot and does not get around secure input. It watches the one
/// signal secure input leaves it, modifier changes, and points at the
/// holder: while a background app keeps secure input on, its logo stays to
/// the right of the island, dimmed, and shakes when a chord of a blocked
/// shortcut is pressed. When the frontmost app holds secure input (the person
/// is in its password field) nothing shakes: the key is never seen, so a
/// failed shortcut cannot be told from typing there.
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
        /// Seconds since boot, the clock `NSEvent.timestamp` uses.
        var uptime: @MainActor () -> TimeInterval
        /// Runs `work` once the app that lost focus had time to release.
        var afterSwitchSettles: (@escaping @MainActor () -> Void) -> Void
        /// Runs `work` once a released chord's shortcut had time to arrive.
        var afterArrivalWindow: (@escaping @MainActor () -> Void) -> Void
    }

    static let shared = SecureInputGuard(system: .live, makePresenter: {
        HotkeyBlockerBadgeStack.shared.presenter(for: .secureInput)
    })

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
    /// The modifiers held right now, from the last `flagsChanged`.
    private var heldChord: ModifierChord = []
    /// Secure input read while ⌘ was down, and who was in front when it went
    /// down. Cmd-Tab commits on ⌘ release, so the activation may come just
    /// after the release (`releasedAt`) or, for ⌘H, while ⌘ is held. `on`
    /// is true only if every read while ⌘ was down saw ON.
    private var commandSample: (on: Bool, frontPID: pid_t?, releasedAt: Date?)?
    /// How long after ⌘ is released a switch still counts as Cmd-Tab.
    static let commandReleaseWindow: TimeInterval = 0.5
    /// Bumped by every OFF read: a switch still settling or a chord still in
    /// its arrival window that began before it belongs to an ended episode.
    private var offGeneration = 0
    /// Command evidence captured by switches still settling, with the
    /// uptime at which each activation was handled. A click that physically
    /// happened before that moment caused the switch, whatever order the
    /// two callbacks were delivered in, and voids its evidence.
    private var pendingEvidence: [Int: (evidence: Bool?, activationUptime: TimeInterval)] = [:]
    /// When the last click physically happened; its activation may still be
    /// in flight, so the app in `lastFront` may already be leaving.
    private var lastClickUptime: TimeInterval?
    private var nextSwitchID = 0
    private var lastShake: Date?
    private(set) var persistentBadge: SecureInputHolderBadge?
    /// A badge was presented and not yet dismissed by the guard; only then
    /// is the (lazily created) presenter asked whether it is still showing.
    private var badgeMayBeShowing = false
    private var pollTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
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
        // Only that a click happened, never where: a click while ⌘ is held
        // makes the next switch a click, not Cmd-Tab.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handleMouseDown(eventUptime: time) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.handleMouseDown(eventUptime: event.timestamp)
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
        // Every modifier change on the Mac lands here; it costs one flag read.
        let on = system.isSecureInputEnabled()
        if chord.contains(.command), !heldChord.contains(.command) {
            let clickInFlight = lastClickUptime.map { system.uptime() - $0 <= Self.commandReleaseWindow } ?? false
            commandSample = clickInFlight ? nil : (on, lastFront?.pid, nil)
        } else if !chord.contains(.command), heldChord.contains(.command), let sample = commandSample {
            commandSample = (sample.on && on, sample.frontPID, now)
        }
        heldChord = chord
        // A confirmed OFF, on a press or a release, ends every attribution.
        if !on { secureInputEnded() }
        guard chord.isEmpty, on else {
            _ = detector.flagsChanged(to: chord, at: now, blockedChords: [])
            return
        }
        guard let start = detector.flagsChanged(to: [], at: now, blockedChords: system.blockedChords()) else { return }
        let generation = offGeneration
        system.afterArrivalWindow { [weak self] in
            guard let self, self.offGeneration == generation else { return } // an OFF ended that episode
            self.evaluateAttempt(heldSince: start)
        }
    }

    /// Decided after the arrival window: a shortcut that arrived, through
    /// Carbon or an accepted Right ⌘/⌥ gesture, in either observer order,
    /// is never blamed on anyone.
    func evaluateAttempt(heldSince start: Date) {
        guard !SecureInputAttemptDetector.arrived(since: start, lastHotkeyFire: system.lastHotkeyFire()) else { return }
        guard system.isSecureInputEnabled() else {
            secureInputEnded()
            return
        }
        reportBlockedAttempt(at: system.now())
    }

    /// `eventUptime` is when the click physically happened (`NSEvent.timestamp`).
    func handleMouseDown(eventUptime: TimeInterval? = nil) {
        commandSample = nil
        let time = eventUptime ?? system.uptime()
        lastClickUptime = max(lastClickUptime ?? time, time)
        for (id, pending) in pendingEvidence where time <= pending.activationUptime {
            pendingEvidence[id] = (nil, pending.activationUptime)
        }
    }

    func handleActivation(_ app: SecureInputApp?) {
        let previous = lastFront
        lastFront = app
        // Only a keyboard switch gives evidence: ⌘ held, or released at most
        // `commandReleaseWindow` ago (Cmd-Tab commits on release), no click
        // since it went down, read with `previous` in front. A click or Dock
        // switch, with or without ⌘, names nobody.
        let now = system.now()
        var wasOn: Bool?
        if let sample = commandSample, sample.frontPID == previous?.pid {
            let held = heldChord.contains(.command) && sample.releasedAt == nil
            let justReleased = sample.releasedAt.map { now.timeIntervalSince($0) <= Self.commandReleaseWindow } ?? false
            if held || justReleased { wasOn = sample.on }
        }
        commandSample = nil // one switch per ⌘
        let generation = offGeneration
        let id = nextSwitchID
        nextSwitchID &+= 1
        pendingEvidence[id] = (wasOn, system.uptime())
        system.afterSwitchSettles { [weak self] in
            guard let self else { return }
            let captured = self.pendingEvidence.removeValue(forKey: id)?.evidence ?? nil
            // An OFF seen since the switch means the app left let go.
            let evidence = self.offGeneration == generation ? captured : false
            self.settleSwitch(from: previous, to: app, wasOnBeforeSwitch: evidence)
        }
    }

    func settleSwitch(from previous: SecureInputApp?, to current: SecureInputApp?, wasOnBeforeSwitch: Bool?) {
        guard system.isSecureInputEnabled() else {
            secureInputEnded()
            return
        }
        tracker.didSwitch(from: previous, to: current, wasOnBeforeSwitch: wasOnBeforeSwitch, secureInputOn: true)
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
                badgeMayBeShowing = true
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
        let decides = tracker.unverifiedSwitch || (tracker.staleCandidate.map { $0.pid != front?.pid } ?? false)
        if askAccessibility, decides, let front {
            frontHasSecureField = system.focusedElementIsSecure(front.pid)
            // The verdict sticks: the 1 s check must not bring the
            // remembered app back while the front field holds secure input.
            if frontHasSecureField { tracker.forgetCandidate() }
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
            secureInputEnded() // the read during resolution saw OFF
            return
        case .ownApp:
            os_log("secure_input_attempt holder=self", log: Self.log, type: .info)
            return
        case .app(_, inBackground: false):
            // The frontmost app holds it, normally its focused password
            // field. The chord may be typing there (⌥ letters, a bare ⌥), so
            // nothing shakes. WHY: .project-docs/decisions/2026-11-26-secure-input-holder.md
            dismissPersistent()
            updatePolling()
            return
        case .app(let app, inBackground: true):
            badge = SecureInputHolderBadge(app: app)
            persistent = true
        case .unknown:
            badge = SecureInputHolderBadge(app: nil)
            persistent = false
        }
        if let lastShake, now.timeIntervalSince(lastShake) < Self.minimumShakeInterval { return }
        lastShake = now
        if persistent { persistentBadge = badge } else { persistentBadge = nil }
        badgeMayBeShowing = true
        presenter.present(badge, shake: true, persistent: persistent)
        os_log("secure_input_attempt holder=%{private}@ background=%{public}d", log: Self.log, type: .info,
               badge.app?.bundleID ?? badge.app?.name ?? "unknown", persistent ? 1 : 0)
        updatePolling()
    }

    /// Secure input is off: no badge may keep claiming otherwise, whether
    /// dimmed, shaken or held open by the pointer.
    private func secureInputEnded() {
        offGeneration &+= 1
        // An OFF while ⌘ is still down: the app in front then was not holding.
        if let sample = commandSample { commandSample = (false, sample.frontPID, sample.releasedAt) }
        tracker.secureInputObservedOff()
        if persistentBadge != nil || badgeMayBeShowing {
            persistentBadge = nil
            badgeMayBeShowing = false
            presenter.dismiss()
            os_log("secure_input_released", log: Self.log, type: .info)
        }
        updatePolling()
    }

    private func dismissPersistent() {
        guard persistentBadge != nil else { return }
        persistentBadge = nil
        badgeMayBeShowing = false
        presenter.dismiss()
    }

    private var badgeShowing: Bool {
        if badgeMayBeShowing, !presenter.isShowing { badgeMayBeShowing = false }
        return badgeMayBeShowing
    }

    /// A 1 s check runs only while a badge is up or a live background holder
    /// is remembered, so the badge leaves as soon as secure input does.
    private func updatePolling() {
        var needed = persistentBadge != nil || badgeShowing
        // A remembered app back in front is checked again on the next switch.
        if let candidate = tracker.staleCandidate, candidate.pid != lastFront?.pid,
           system.isRunning(candidate.pid) { needed = true }
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
            uptime: { ProcessInfo.processInfo.systemUptime },
            afterSwitchSettles: { work in
                DispatchQueue.main.asyncAfter(deadline: .now() + SecureInputGuard.switchSettleDelay) {
                    MainActor.assumeIsolated { work() }
                }
            },
            afterArrivalWindow: { work in
                DispatchQueue.main.asyncAfter(deadline: .now() + SecureInputAttemptDetector.arrivalWindow) {
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
    static func focusedElementIsSecure(pid: pid_t) -> Bool {
        // Whytap's own windows are read in-process: an Accessibility call to
        // ourselves from the main thread could only time out.
        if pid == ProcessInfo.processInfo.processIdentifier { return ownFocusIsSecure() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
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

extension SecureInputGuard {
    static func ownFocusIsSecure() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSSecureTextField { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, editor.delegate is NSSecureTextField {
            return true
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
