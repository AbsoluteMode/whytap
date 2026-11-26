import AppKit
import CoreGraphics
import Darwin
import os.log

/// Points at the app that swallows a Whytap modifier shortcut (Right ⌘,
/// Right ⌥) with its own event tap, such as a keyboard layout switcher bound
/// to the same key.
///
/// The signal is exact, not a guess: Whytap's HID-level probe saw the key go
/// down, and Whytap's shortcut monitors never saw it held. Only then is the
/// tap list read, and the app owning an enabled active `flagsChanged` filter
/// (not Apple's, not Whytap's) gets its logo beside the island, shaking, for
/// about 3 s; then it hides. Every new lost press shows it again and restarts
/// the time. It never stays dimmed.
// WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md
@MainActor
final class HotkeyInterceptionGuard {
    struct System {
        /// Modifier keys a live Whytap shortcut is bound to.
        var watchedKeys: @MainActor () -> Set<HotkeyModifierKey>
        var tapList: @MainActor () -> [EventTapRecord]
        var process: @MainActor (pid_t) -> InterceptorProcess?
        var frontmostPID: @MainActor () -> pid_t?
        var ownPID: pid_t
        /// False on the lock screen or while another user's session is on
        /// the console: Whytap's monitors see nothing there by design.
        var isSessionInteractive: @MainActor () -> Bool
        var uptime: @MainActor () -> TimeInterval
        var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    }

    static let shared = HotkeyInterceptionGuard(
        system: .live,
        probe: HotkeyPressProbe(),
        makePresenter: { HotkeyBlockerBadgeStack.shared.presenter(for: .interception) }
    )

    /// How often a delivered modifier change may re-read the tap list to keep
    /// the probe in front of a newly installed HID filter.
    static let headCheckInterval: TimeInterval = 10
    /// A tap that cannot be created (no Accessibility) is retried this late.
    static let probeRetryInterval: TimeInterval = 30
    /// A decision that ran this late found a busy main thread: the delivered
    /// event may still be queued, so it waits once more.
    static let lateDecisionSlack: TimeInterval = 0.15
    static let maxDecisionRetries = 3
    /// After an app launches, its tap is usually up within this time.
    static let launchSettleDelay: TimeInterval = 3

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey")

    private let system: System
    private let probe: HotkeyPressProbing
    private let makePresenter: () -> SecureInputHolderPresenting
    private lazy var presenter: SecureInputHolderPresenting = makePresenter()

    private var detector = HotkeyInterceptionDetector()
    /// Other processes' HID modifier filters when the probe was installed.
    private var probeBaseline: Set<UInt32> = []
    private var probeRetryAt: TimeInterval?
    /// The last badge shown, for diagnostics and tests; it hides by itself.
    private(set) var lastBadge: SecureInputHolderBadge?
    private var lastHeadCheck: TimeInterval?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var launchObserver: NSObjectProtocol?
    private var started = false

    init(system: System, probe: HotkeyPressProbing, makePresenter: @escaping () -> SecureInputHolderPresenting) {
        self.system = system
        self.probe = probe
        self.makePresenter = makePresenter
    }

    /// Idempotent. Watches `flagsChanged` where Whytap's shortcuts do (which
    /// modifiers are down, nothing else) and installs the probe while a
    /// modifier shortcut exists.
    func start() {
        guard !started else { return }
        started = true
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            let time = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated { self?.handleDelivered(rawFlags: flags, at: time) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            self?.handleDelivered(rawFlags: flags, at: ProcessInfo.processInfo.systemUptime)
            return event
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.system.after(Self.launchSettleDelay) { [weak self] in self?.keepProbeAtHead() }
            }
        }
        syncProbe()
    }

    // MARK: - Events (internal for tests)

    /// A `flagsChanged` that reached Whytap's shortcut monitors.
    func handleDelivered(rawFlags: UInt64, at time: TimeInterval) {
        detector.delivered(rawFlags: rawFlags, at: time)
        syncProbe()
        let now = system.uptime()
        if lastHeadCheck.map({ now - $0 >= Self.headCheckInterval }) ?? true {
            lastHeadCheck = now
            keepProbeAtHead()
        }
    }

    /// A hardware `flagsChanged` the probe saw, before any session tap.
    func handlePhysical(rawFlags: UInt64, at time: TimeInterval) {
        let (began, ended) = detector.physical(rawFlags: rawFlags, at: time, watched: system.watchedKeys())
        for press in began {
            schedule(press, due: press.startedAt + HotkeyInterceptionDetector.holdDecision)
        }
        let now = system.uptime()
        for press in ended {
            schedule(press, due: now + HotkeyInterceptionDetector.decisionDelay)
        }
    }

    /// Reinstalls the probe when another app put a HID modifier filter in
    /// front of it since it was installed.
    func keepProbeAtHead() {
        guard probe.isRunning else { return }
        let current = HotkeyInterceptorClassifier.foreignHIDFilterIDs(in: system.tapList(), ownPID: system.ownPID)
        if current.isSubset(of: probeBaseline) {
            probeBaseline = current
            return
        }
        os_log("hotkey_probe_reinstalled", log: Self.log, type: .info)
        probe.stop()
        installProbe()
    }

    // MARK: - Private

    private func schedule(_ press: HotkeyInterceptionDetector.Press, due: TimeInterval, retries: Int = 0) {
        let delay = max(0, due - system.uptime())
        system.after(delay) { [weak self] in
            guard let self else { return }
            let late = self.system.uptime() - due
            if late > Self.lateDecisionSlack, retries < Self.maxDecisionRetries {
                self.schedule(press, due: self.system.uptime() + HotkeyInterceptionDetector.decisionDelay,
                              retries: retries + 1)
                return
            }
            self.decide(press)
        }
    }

    private func decide(_ press: HotkeyInterceptionDetector.Press) {
        guard let verdict = detector.decide(press, now: system.uptime()) else { return }
        if case .blocked(let key) = verdict { reportBlocked(key) }
    }

    private func reportBlocked(_ key: HotkeyModifierKey) {
        guard system.watchedKeys().contains(key), system.isSessionInteractive() else { return }
        let candidates = HotkeyInterceptorClassifier.candidates(
            in: system.tapList(), ownPID: system.ownPID, frontmostPID: system.frontmostPID(),
            process: system.process)
        guard let first = candidates.first else {
            // Lost, but no other app's filter could have done it: say nothing.
            os_log("hotkey_press_lost interceptor=none", log: Self.log, type: .info)
            return
        }
        let badge = SecureInputHolderBadge(app: first,
                                           message: HotkeyInterceptorClassifier.message(for: candidates, key: key))
        lastBadge = badge
        // Transient: shaken and highlighted, then hidden by the panel about
        // 3 s later. A new lost press presents again, which restarts that
        // time. WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md
        presenter.present(badge, shake: true, persistent: false)
        os_log("hotkey_press_lost interceptor=%{private}@ candidates=%{public}d", log: Self.log, type: .info,
               first.bundleID ?? first.name, candidates.count)
    }

    /// Installs the probe while a modifier shortcut exists, removes it
    /// otherwise.
    private func syncProbe() {
        let watched = system.watchedKeys()
        if watched.isEmpty {
            if probe.isRunning {
                probe.stop()
                detector.forgetPhysical()
            }
            return
        }
        guard !probe.isRunning else { return }
        if let probeRetryAt, system.uptime() < probeRetryAt { return }
        installProbe()
    }

    private func installProbe() {
        detector.forgetPhysical()
        probeBaseline = HotkeyInterceptorClassifier.foreignHIDFilterIDs(in: system.tapList(), ownPID: system.ownPID)
        let installed = probe.start(
            deliver: { [weak self] flags, time in self?.handlePhysical(rawFlags: flags, at: time) },
            onFailure: { [weak self] in
                guard let self else { return }
                self.detector.forgetPhysical()
                self.probeRetryAt = self.system.uptime() + Self.probeRetryInterval
            }
        )
        probeRetryAt = installed ? nil : system.uptime() + Self.probeRetryInterval
    }

}

extension HotkeyInterceptionGuard {
    /// Modifier keys bound to a shortcut that is switched on.
    static func watchedKeys(in configuration: HotkeyConfiguration, agentEnabled: Bool,
                            googleEnabled: Bool) -> Set<HotkeyModifierKey> {
        var shortcuts: [HotkeyShortcut] = [
            configuration.dropVoiceShortcut,
            configuration.agentCloseShortcut,
            configuration.usefulLinksInsertShortcut,
            configuration.usefulLinksOpenShortcut,
            configuration.usefulLinksNextShortcut,
            configuration.usefulLinksPreviousShortcut,
            configuration.meetingRecordShortcut
        ] + Array(configuration.toolShortcuts.values)
        if agentEnabled { shortcuts += [configuration.agentTextShortcut, configuration.agentVoiceShortcut] }
        if googleEnabled {
            shortcuts += [configuration.googleSearchTextShortcut, configuration.googleSearchVoiceShortcut]
        }
        return Set(shortcuts.compactMap(\.modifierKey))
    }
}

extension HotkeyInterceptionGuard.System {
    @MainActor static var live: Self {
        Self(
            watchedKeys: {
                HotkeyInterceptionGuard.watchedKeys(
                    in: HotkeyPreferences.shared.configuration,
                    agentEnabled: UserPreferencesCache.shared.currentAgentEnabled,
                    googleEnabled: UserPreferencesCache.shared.currentGoogleEnabled)
            },
            tapList: EventTapRecord.systemList,
            process: InterceptorProcess.live(pid:),
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            ownPID: ProcessInfo.processInfo.processIdentifier,
            isSessionInteractive: {
                guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
                let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? false
                let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
                return onConsole && !locked
            },
            uptime: { ProcessInfo.processInfo.systemUptime },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { work() }
                }
            }
        )
    }
}

extension InterceptorProcess {
    /// Name and bundle ID of a tap's owner. A process without a bundle (a
    /// command-line remapper) is named by its executable.
    @MainActor static func live(pid: pid_t) -> InterceptorProcess? {
        let path = executablePath(pid: pid)
        let isSystemPath = path.map { $0.hasPrefix("/System/") || $0.hasPrefix("/usr/") } ?? false
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            let bundleID = app.bundleIdentifier
            let isApple = bundleID?.hasPrefix("com.apple.") ?? false
            return InterceptorProcess(app: SecureInputApp(running: app), isSystem: isApple || isSystemPath)
        }
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        return InterceptorProcess(app: SecureInputApp(pid: pid, name: name, bundleID: nil), isSystem: isSystemPath)
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
