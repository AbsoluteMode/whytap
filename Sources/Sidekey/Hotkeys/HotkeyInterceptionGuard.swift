import AppKit
import Combine
import CoreGraphics
import Darwin
import os.log

/// Points at the app that swallows a Whytap modifier shortcut (Right ⌘,
/// Right ⌥) with its own event tap, such as a keyboard layout switcher bound
/// to the same key.
///
/// The signal is exact, not a guess: Whytap's HID-level probe saw the key go
/// down alone, and Whytap's shortcut monitors never saw that same press held.
/// Only then is the tap list read: the owners of enabled active
/// `flagsChanged` filters (not Apple's, not Whytap's) that already existed
/// when the press began, with the same app in front, are named as possible
/// interceptors. The logo shakes beside the island for about 3 s, then hides;
/// every new lost press shows it again. It never stays dimmed.
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
    /// Bumped on every probe install and stop: a callback or verdict from an
    /// earlier probe is discarded.
    private(set) var probeGeneration = 0
    private var contexts: [Int: HotkeyPressContext] = [:]
    /// Other processes' HID modifier filters when the probe was installed.
    private var probeBaseline: Set<UInt32> = []
    private var probeRetryAt: TimeInterval?
    private var lastHeadCheck: TimeInterval?
    /// The press whose badge is up, so a late delivery of it can take it back.
    private var shownForPress: Int?
    /// The last badge shown, for diagnostics and tests; it hides by itself.
    private(set) var lastBadge: SecureInputHolderBadge?
    private var started = false
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var preferencesObservation: AnyCancellable?

    init(system: System, probe: HotkeyPressProbing, makePresenter: @escaping () -> SecureInputHolderPresenting) {
        self.system = system
        self.probe = probe
        self.makePresenter = makePresenter
    }

    /// Idempotent. Watches `flagsChanged` where Whytap's shortcuts do (which
    /// modifiers are down, nothing else), follows shortcut, capability,
    /// permission and session changes, and keeps the probe installed exactly
    /// while a modifier shortcut is live.
    func start() {
        guard !started else { return }
        started = true
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            let time = Self.eventTime(of: event)
            MainActor.assumeIsolated { self?.handleDelivered(rawFlags: flags, eventTime: time) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            self?.handleDelivered(rawFlags: flags, eventTime: Self.eventTime(of: event))
            return event
        }) { monitors.append(local) }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { guard_ in
            guard_.system.after(Self.launchSettleDelay) { [weak guard_] in guard_?.keepProbeAtHead() }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.bindingsOrSessionChanged() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.bindingsOrSessionChanged() }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.accessibility.api"] {
            observe(distributed, Notification.Name(name)) { guard_ in
                // The lock and trust flags settle just after the notice.
                guard_.system.after(0.5) { [weak guard_] in guard_?.bindingsOrSessionChanged(retryNow: true) }
            }
        }
        observe(NotificationCenter.default, .sidekeyCapabilityFlagsChanged) { $0.bindingsOrSessionChanged() }
        // Published before the value changes: read it on the next turn.
        preferencesObservation = HotkeyPreferences.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bindingsOrSessionChanged() } }
        }
        syncProbe()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (HotkeyInterceptionGuard) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    nonisolated private static func eventTime(of event: NSEvent) -> TimeInterval {
        HotkeyEventTime.seconds(event.cgEvent?.timestamp ?? 0, fallback: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Events (internal for tests)

    /// A `flagsChanged` that reached Whytap's shortcut monitors.
    func handleDelivered(rawFlags: UInt64, eventTime: TimeInterval) {
        let reversed = detector.delivered(rawFlags: rawFlags, eventTime: eventTime)
        if let shown = shownForPress, reversed.contains(shown) {
            // The press did arrive, only late: take the claim back.
            shownForPress = nil
            presenter.dismiss()
        }
        syncProbe()
        let now = system.uptime()
        if lastHeadCheck.map({ now - $0 >= Self.headCheckInterval }) ?? true {
            lastHeadCheck = now
            keepProbeAtHead()
        }
    }

    /// A hardware `flagsChanged` the probe saw, before any session tap.
    /// `generation` is the probe install it came from.
    func handlePhysical(rawFlags: UInt64, eventTime: TimeInterval, seenAt: TimeInterval, generation: Int) {
        guard generation == probeGeneration, probe.isRunning else { return }
        let changes = detector.physical(rawFlags: rawFlags, eventTime: eventTime, seenAt: seenAt,
                                        watched: system.watchedKeys())
        for change in changes {
            switch change {
            case .began(let id, let at):
                let front = system.frontmostPID()
                contexts[id] = HotkeyPressContext(
                    frontmostPID: front,
                    filterOwners: HotkeyInterceptorClassifier.filterOwners(in: system.tapList(), ownPID: system.ownPID,
                                                                          frontmostPID: front))
                schedule(id, due: at + HotkeyInterceptionDetector.holdDecision)
            case .ended(let id, let at):
                schedule(id, due: at + HotkeyInterceptionDetector.decisionDelay)
            }
        }
        if contexts.count > 64 {
            contexts = contexts.filter { detector.presses[$0.key] != nil }
        }
    }

    /// Shortcuts, capabilities, Accessibility or the session changed.
    func bindingsOrSessionChanged(retryNow: Bool = false) {
        if retryNow { probeRetryAt = nil }
        syncProbe()
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
        stopProbe()
        installProbe()
    }

    // MARK: - Private

    private func schedule(_ id: Int, due: TimeInterval, retries: Int = 0) {
        let generation = probeGeneration
        let delay = max(0, due - system.uptime())
        system.after(delay) { [weak self] in
            guard let self, self.probeGeneration == generation else { return }
            let late = self.system.uptime() - due
            if late > Self.lateDecisionSlack, retries < Self.maxDecisionRetries {
                self.schedule(id, due: self.system.uptime() + HotkeyInterceptionDetector.decisionDelay,
                              retries: retries + 1)
                return
            }
            self.decide(id)
        }
    }

    private func decide(_ id: Int) {
        guard let verdict = detector.decide(id, now: system.uptime()) else { return }
        guard case .blocked(let key) = verdict, let context = contexts.removeValue(forKey: id) else {
            contexts[id] = nil
            return
        }
        reportBlocked(key, press: id, context: context)
    }

    private func reportBlocked(_ key: HotkeyModifierKey, press: Int, context: HotkeyPressContext) {
        guard system.watchedKeys().contains(key), system.isSessionInteractive() else { return }
        let candidates = HotkeyInterceptorClassifier.candidates(
            in: system.tapList(), context: context, frontmostPID: system.frontmostPID(),
            ownPID: system.ownPID, process: system.process)
        guard let first = candidates.first else {
            // Lost, but no filter of another app in the same context: say nothing.
            os_log("hotkey_press_lost interceptor=none", log: Self.log, type: .info)
            return
        }
        let badge = SecureInputHolderBadge(app: first,
                                           message: HotkeyInterceptorClassifier.message(for: candidates, key: key))
        lastBadge = badge
        shownForPress = press
        // Transient: shaken and highlighted, then hidden by the panel about
        // 3 s later. A new lost press presents again, which restarts that
        // time. WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md
        presenter.present(badge, shake: true, persistent: false)
        os_log("hotkey_press_lost interceptor=%{private}@ candidates=%{public}d", log: Self.log, type: .info,
               first.bundleID ?? first.name, candidates.count)
    }

    /// The probe exists exactly while a modifier shortcut is live and the
    /// session is interactive.
    private func syncProbe() {
        let needed = !system.watchedKeys().isEmpty && system.isSessionInteractive()
        if !needed {
            if probe.isRunning { stopProbe() }
            return
        }
        guard !probe.isRunning else { return }
        if let probeRetryAt, system.uptime() < probeRetryAt { return }
        installProbe()
    }

    private func stopProbe() {
        probe.stop()
        probeGeneration &+= 1
        detector.reset()
        contexts = [:]
    }

    private func installProbe() {
        probeGeneration &+= 1
        detector.reset()
        contexts = [:]
        let generation = probeGeneration
        probeBaseline = HotkeyInterceptorClassifier.foreignHIDFilterIDs(in: system.tapList(), ownPID: system.ownPID)
        let installed = probe.start(
            deliver: { [weak self] flags, eventTime, seenAt in
                self?.handlePhysical(rawFlags: flags, eventTime: eventTime, seenAt: seenAt, generation: generation)
            },
            onFailure: { [weak self] in
                guard let self, self.probeGeneration == generation else { return }
                self.probeGeneration &+= 1
                self.detector.reset()
                self.contexts = [:]
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
