import CoreGraphics
import XCTest
@testable import Sidekey

/// An app such as Punto Switcher, bound to Right Option, swallows the press
/// with its own event tap: Whytap names it beside the island instead of
/// failing silently. Tap lists are fake; the probe and the clock are fakes.
@MainActor
final class HotkeyInterceptionTests: XCTestCase {
    // Raw `flagsChanged` flags as macOS sends them.
    private let rightOptionDown: UInt64 = 0x080000 | 0x40
    private let leftOptionDown: UInt64 = 0x080000 | 0x20
    private let rightCommandDown: UInt64 = 0x100000 | 0x10
    private let noModifiers: UInt64 = 0x100

    private let ownPID: pid_t = 100
    private let puntoPID: pid_t = 200
    private let siriPID: pid_t = 300
    private let raycastPID: pid_t = 400
    private let bttPID: pid_t = 500
    private let frontPID: pid_t = 600

    private let keysAndModifiers: UInt64 = (1 << 10) | (1 << 11) | (1 << 12)
    private let keysOnly: UInt64 = (1 << 10) | (1 << 11)

    private lazy var punto = SecureInputApp(pid: puntoPID, name: "Punto Switcher", bundleID: "ru.yandex.desktop.PuntoSwitcher")
    private lazy var btt = SecureInputApp(pid: bttPID, name: "BetterTouchTool", bundleID: "com.hegenberg.BetterTouchTool")

    private func process(_ pid: pid_t) -> InterceptorProcess? {
        switch pid {
        case puntoPID: return InterceptorProcess(app: punto, isSystem: false)
        case bttPID: return InterceptorProcess(app: btt, isSystem: false)
        case siriPID: return InterceptorProcess(app: SecureInputApp(pid: siriPID, name: "Siri", bundleID: "com.apple.Siri"), isSystem: true)
        case raycastPID: return InterceptorProcess(app: SecureInputApp(pid: raycastPID, name: "Raycast", bundleID: "com.raycast.macos"), isSystem: false)
        case ownPID: return InterceptorProcess(app: SecureInputApp(pid: ownPID, name: "Whytap", bundleID: "com.rootwise.sidekey"), isSystem: false)
        default: return nil
        }
    }

    /// A Mac as measured on 2026-11-26: Whytap's own taps, Raycast's HID
    /// keyDown filter, Siri's modifier filters and a listen-only observer.
    private var ordinaryTaps: [EventTapRecord] {
        [
            EventTapRecord(id: 1, location: .session, isActiveFilter: true, enabled: false, tappingPID: ownPID, eventsOfInterest: keysOnly),
            EventTapRecord(id: 2, location: .hid, isActiveFilter: true, enabled: true, tappingPID: ownPID, eventsOfInterest: 1 << 12),
            EventTapRecord(id: 3, location: .hid, isActiveFilter: true, enabled: true, tappingPID: raycastPID, eventsOfInterest: 1 << 10),
            EventTapRecord(id: 4, location: .session, isActiveFilter: true, enabled: true, tappingPID: siriPID, eventsOfInterest: keysAndModifiers),
            EventTapRecord(id: 5, location: .session, isActiveFilter: false, enabled: true, tappingPID: bttPID, eventsOfInterest: keysAndModifiers)
        ]
    }

    private var puntoTap: EventTapRecord {
        EventTapRecord(id: 9, location: .session, isActiveFilter: true, enabled: true, tappingPID: puntoPID, eventsOfInterest: keysAndModifiers)
    }

    // MARK: - Tap list classification

    func testOnlyAnotherAppsEnabledModifierFilterIsACandidate() {
        let none = HotkeyInterceptorClassifier.candidates(in: ordinaryTaps, ownPID: ownPID, frontmostPID: frontPID, process: process)
        XCTAssertEqual(none, [], "own taps, keyDown-only filters, Apple's filters and listen-only taps are benign")

        let withPunto = HotkeyInterceptorClassifier.candidates(in: ordinaryTaps + [puntoTap], ownPID: ownPID,
                                                               frontmostPID: frontPID, process: process)
        XCTAssertEqual(withPunto, [punto])
    }

    func testDisabledTapAndUnknownProcessAreNotCandidates() {
        let disabled = EventTapRecord(id: 9, location: .session, isActiveFilter: true, enabled: false,
                                      tappingPID: puntoPID, eventsOfInterest: keysAndModifiers)
        let orphan = EventTapRecord(id: 10, location: .hid, isActiveFilter: true, enabled: true,
                                    tappingPID: 9_999, eventsOfInterest: keysAndModifiers)
        XCTAssertEqual(HotkeyInterceptorClassifier.candidates(in: [disabled, orphan], ownPID: ownPID,
                                                             frontmostPID: frontPID, process: process), [])
    }

    func testPerProcessTapCountsOnlyForTheFrontmostApp() {
        let onOtherApp = EventTapRecord(id: 9, location: .session, isActiveFilter: true, enabled: true,
                                        tappingPID: puntoPID, tappedPID: 777, eventsOfInterest: keysAndModifiers)
        XCTAssertEqual(HotkeyInterceptorClassifier.candidates(in: [onOtherApp], ownPID: ownPID, frontmostPID: frontPID,
                                                             process: process), [])
        let onFront = EventTapRecord(id: 9, location: .session, isActiveFilter: true, enabled: true,
                                     tappingPID: puntoPID, tappedPID: frontPID, eventsOfInterest: keysAndModifiers)
        XCTAssertEqual(HotkeyInterceptorClassifier.candidates(in: [onFront], ownPID: ownPID, frontmostPID: frontPID,
                                                             process: process), [punto])
    }

    func testHIDFiltersComeFirstAndEachAppOnce() {
        let bttHID = EventTapRecord(id: 11, location: .hid, isActiveFilter: true, enabled: true,
                                    tappingPID: bttPID, eventsOfInterest: 1 << 12)
        let bttSession = EventTapRecord(id: 12, location: .session, isActiveFilter: true, enabled: true,
                                        tappingPID: bttPID, eventsOfInterest: 1 << 12)
        let result = HotkeyInterceptorClassifier.candidates(in: [puntoTap, bttSession, bttHID], ownPID: ownPID,
                                                            frontmostPID: frontPID, process: process)
        XCTAssertEqual(result, [btt, punto])
    }

    func testMessageNamesTheKeyAndTheApps() {
        XCTAssertEqual(HotkeyInterceptorClassifier.message(for: [punto], key: .rightOption),
                       "Punto Switcher is intercepting Right Option — change the key in one of the apps")
        XCTAssertEqual(HotkeyInterceptorClassifier.message(for: [punto, btt], key: .rightCommand),
                       "Punto Switcher or BetterTouchTool is intercepting Right Command — change the key in one of the apps")
        let third = SecureInputApp(pid: 1, name: "Karabiner", bundleID: nil)
        XCTAssertTrue(HotkeyInterceptorClassifier.message(for: [punto, btt, third], key: .rightOption)
            .hasPrefix("Punto Switcher or another app is intercepting Right Option"))
    }

    func testForeignHIDFilterIDsIgnoreOwnAndSessionTaps() {
        let puntoHID = EventTapRecord(id: 20, location: .hid, isActiveFilter: true, enabled: true,
                                      tappingPID: puntoPID, eventsOfInterest: keysAndModifiers)
        XCTAssertEqual(HotkeyInterceptorClassifier.foreignHIDFilterIDs(in: ordinaryTaps + [puntoTap, puntoHID], ownPID: ownPID),
                       [20])
    }

    func testRecordParsesCoreGraphicsInformation() {
        var info = CGEventTapInformation()
        info.eventTapID = 42
        info.tapPoint = .cghidEventTap
        info.options = .defaultTap
        info.eventsOfInterest = keysAndModifiers
        info.tappingProcess = puntoPID
        info.processBeingTapped = 0
        info.enabled = true
        let record = EventTapRecord(info)
        XCTAssertEqual(record, EventTapRecord(id: 42, location: .hid, isActiveFilter: true, enabled: true,
                                              tappingPID: puntoPID, eventsOfInterest: keysAndModifiers))
        XCTAssertTrue(record?.filtersModifiers == true)
        info.options = .listenOnly
        XCTAssertFalse(EventTapRecord(info)?.filtersModifiers ?? true)
    }

    // MARK: - Detector

    func testDeliveredPressIsNotBlocked() {
        var detector = HotkeyInterceptionDetector()
        let began = detector.physical(rawFlags: rightOptionDown, at: 10, watched: [.rightOption]).began
        detector.delivered(rawFlags: rightOptionDown, at: 10.001)
        let ended = detector.physical(rawFlags: noModifiers, at: 10.1, watched: [.rightOption]).ended
        detector.delivered(rawFlags: noModifiers, at: 10.101)
        XCTAssertEqual(began, ended)
        XCTAssertEqual(detector.decide(ended[0], now: 10.4), .delivered(.rightOption))
        XCTAssertNil(detector.decide(ended[0], now: 10.6), "one verdict per press")
    }

    func testSwallowedPressIsBlocked() {
        var detector = HotkeyInterceptionDetector()
        _ = detector.physical(rawFlags: rightOptionDown, at: 10, watched: [.rightOption])
        let ended = detector.physical(rawFlags: noModifiers, at: 10.1, watched: [.rightOption]).ended
        XCTAssertEqual(detector.decide(ended[0], now: 10.4), .blocked(.rightOption))
    }

    func testRewrittenFlagsAreBlocked() {
        // The interceptor lets the event through but clears the right-side bit.
        var detector = HotkeyInterceptionDetector()
        _ = detector.physical(rawFlags: rightOptionDown, at: 10, watched: [.rightOption])
        detector.delivered(rawFlags: leftOptionDown, at: 10.001)
        let ended = detector.physical(rawFlags: noModifiers, at: 10.1, watched: [.rightOption]).ended
        detector.delivered(rawFlags: noModifiers, at: 10.101)
        XCTAssertEqual(detector.decide(ended[0], now: 10.4), .blocked(.rightOption))
    }

    func testDeliveryHandledBeforeThePhysicalPressStillCounts() {
        // Both reach the main thread in either order; their clocks keep the truth.
        var detector = HotkeyInterceptionDetector()
        detector.delivered(rawFlags: rightOptionDown, at: 10.002)
        _ = detector.physical(rawFlags: rightOptionDown, at: 10, watched: [.rightOption])
        let ended = detector.physical(rawFlags: noModifiers, at: 10.1, watched: [.rightOption]).ended
        XCTAssertEqual(detector.decide(ended[0], now: 10.4), .delivered(.rightOption))
    }

    func testDeliveryOfAnEarlierPressDoesNotCoverALaterOne() {
        var detector = HotkeyInterceptionDetector()
        detector.delivered(rawFlags: rightOptionDown, at: 5)
        detector.delivered(rawFlags: noModifiers, at: 5.1)
        _ = detector.physical(rawFlags: rightOptionDown, at: 10, watched: [.rightOption])
        let ended = detector.physical(rawFlags: noModifiers, at: 10.1, watched: [.rightOption]).ended
        XCTAssertEqual(detector.decide(ended[0], now: 10.4), .blocked(.rightOption))
    }

    func testLongHoldIsJudgedWhileHeld() {
        var detector = HotkeyInterceptionDetector()
        let press = detector.physical(rawFlags: rightOptionDown, at: 10, watched: [.rightOption]).began[0]
        XCTAssertNil(detector.decide(press, now: 10.2), "too young")
        XCTAssertEqual(detector.decide(press, now: 10.5), .blocked(.rightOption))
        let ended = detector.physical(rawFlags: noModifiers, at: 12, watched: [.rightOption]).ended
        XCTAssertNil(detector.decide(ended[0], now: 12.3), "already reported")
    }

    func testUnwatchedKeyIsIgnored() {
        var detector = HotkeyInterceptionDetector()
        let result = detector.physical(rawFlags: rightCommandDown, at: 10, watched: [.rightOption])
        XCTAssertTrue(result.began.isEmpty)
    }

    // MARK: - Guard

    private final class FakeProbe: HotkeyPressProbing {
        var isRunning = false
        var allowStart = true
        var starts = 0
        var deliver: (@MainActor (UInt64, TimeInterval) -> Void)?
        var onFailure: (@MainActor () -> Void)?

        func start(deliver: @escaping @MainActor (UInt64, TimeInterval) -> Void,
                   onFailure: @escaping @MainActor () -> Void) -> Bool {
            starts += 1
            guard allowStart else { return false }
            isRunning = true
            self.deliver = deliver
            self.onFailure = onFailure
            return true
        }

        func stop() { isRunning = false }
    }

    private final class FakePresenter: SecureInputHolderPresenting {
        var presented: [(badge: SecureInputHolderBadge, shake: Bool, persistent: Bool)] = []
        var dismissals = 0
        var isShowing = false

        func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool) {
            presented.append((badge, shake, persistent))
            isShowing = true
        }

        func dismiss() {
            dismissals += 1
            isShowing = false
        }
    }

    private final class World {
        var watched: Set<HotkeyModifierKey> = [.rightCommand, .rightOption]
        var taps: [EventTapRecord] = []
        var interactive = true
        var uptime: TimeInterval = 100
        var scheduled: [(at: TimeInterval, work: @MainActor () -> Void)] = []

        /// Runs every scheduled work due by `time`, in order.
        @MainActor func advance(to time: TimeInterval) {
            while let next = scheduled.enumerated().filter({ $0.element.at <= time }).min(by: { $0.element.at < $1.element.at }) {
                scheduled.remove(at: next.offset)
                uptime = max(uptime, next.element.at)
                next.element.work()
            }
            uptime = time
        }
    }

    private func makeGuard(_ world: World, probe: FakeProbe, presenter: FakePresenter) -> HotkeyInterceptionGuard {
        let system = HotkeyInterceptionGuard.System(
            watchedKeys: { world.watched },
            tapList: { world.taps },
            process: { [unowned self] pid in self.process(pid) },
            frontmostPID: { [frontPID] in frontPID },
            ownPID: ownPID,
            isSessionInteractive: { world.interactive },
            uptime: { world.uptime },
            after: { delay, work in world.scheduled.append((world.uptime + delay, work)) }
        )
        return HotkeyInterceptionGuard(system: system, probe: probe, makePresenter: { presenter })
    }

    /// Starts the guard's probe the way production does: the first delivered
    /// modifier change.
    private func started(_ world: World, _ probe: FakeProbe, _ presenter: FakePresenter) -> HotkeyInterceptionGuard {
        let guard_ = makeGuard(world, probe: probe, presenter: presenter)
        guard_.handleDelivered(rawFlags: noModifiers, at: world.uptime)
        XCTAssertTrue(probe.isRunning)
        return guard_
    }

    /// A Right Option tap: the probe sees it; `delivered` says whether
    /// Whytap's shortcut monitors do too.
    private func tapRightOption(_ guard_: HotkeyInterceptionGuard, _ world: World, delivered: Bool) {
        let t = world.uptime
        guard_.handlePhysical(rawFlags: rightOptionDown, at: t)
        if delivered { guard_.handleDelivered(rawFlags: rightOptionDown, at: t + 0.001) }
        world.advance(to: t + 0.1)
        guard_.handlePhysical(rawFlags: noModifiers, at: t + 0.1)
        if delivered { guard_.handleDelivered(rawFlags: noModifiers, at: t + 0.101) }
        world.advance(to: t + 1)
    }

    func testPuntoSwallowingRightOptionShakesItsLogo() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { guard_.stopPollingForTesting() }

        tapRightOption(guard_, world, delivered: false)

        XCTAssertEqual(presenter.presented.count, 1)
        let shown = presenter.presented[0]
        XCTAssertEqual(shown.badge.app, punto)
        XCTAssertEqual(shown.badge.label, "Punto Switcher is intercepting Right Option — change the key in one of the apps")
        XCTAssertTrue(shown.shake)
        XCTAssertTrue(shown.persistent, "stays dimmed while Punto keeps its filter")
        XCTAssertTrue(guard_.isPolling)
    }

    func testDeliveredPressShowsNothing() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)

        tapRightOption(guard_, world, delivered: true)

        XCTAssertTrue(presenter.presented.isEmpty, "Punto is running but did not take this key")
        XCTAssertFalse(guard_.isPolling)
    }

    func testLostPressWithOnlyBenignTapsShowsNothing() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps
        let guard_ = started(world, probe, presenter)

        tapRightOption(guard_, world, delivered: false)

        XCTAssertTrue(presenter.presented.isEmpty, "never blame Whytap, Apple or a listen-only tap")
    }

    func testLockedSessionShowsNothing() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        world.interactive = false
        let guard_ = started(world, probe, presenter)

        tapRightOption(guard_, world, delivered: false)

        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testLogoLeavesWhenPuntoStopsFiltering() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { guard_.stopPollingForTesting() }
        tapRightOption(guard_, world, delivered: false)

        guard_.poll()
        XCTAssertEqual(presenter.dismissals, 0, "Punto still filters")

        world.taps = ordinaryTaps // Punto quit or disabled its tap
        guard_.poll()
        XCTAssertEqual(presenter.dismissals, 1)
        XCTAssertNil(guard_.blamed)
        XCTAssertFalse(guard_.isPolling)
    }

    func testLogoLeavesWhenTheKeyArrivesAgain() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { guard_.stopPollingForTesting() }
        tapRightOption(guard_, world, delivered: false)

        // The person moved Punto's switch key: Right Option reaches Whytap.
        tapRightOption(guard_, world, delivered: true)

        XCTAssertEqual(presenter.dismissals, 1)
        XCTAssertNil(guard_.blamed)
    }

    func testLogoLeavesWhenTheKeyIsNoLongerAShortcut() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { guard_.stopPollingForTesting() }
        tapRightOption(guard_, world, delivered: false)

        world.watched = [.rightCommand] // Google search switched off
        guard_.handleDelivered(rawFlags: noModifiers, at: world.uptime)

        XCTAssertEqual(presenter.dismissals, 1)
        XCTAssertTrue(probe.isRunning, "Right Command is still watched")

        world.watched = []
        guard_.handleDelivered(rawFlags: noModifiers, at: world.uptime)
        XCTAssertFalse(probe.isRunning, "no modifier shortcut, no probe")
    }

    func testUnwatchedKeyIsNeverJudged() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        world.watched = [.rightCommand]
        let guard_ = started(world, probe, presenter)

        tapRightOption(guard_, world, delivered: false)

        XCTAssertTrue(presenter.presented.isEmpty, "Punto may own Right Option when Whytap does not use it")
    }

    func testShakesAreThrottledButEachPressCanShake() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { guard_.stopPollingForTesting() }

        tapRightOption(guard_, world, delivered: false)
        tapRightOption(guard_, world, delivered: false)
        XCTAssertEqual(presenter.presented.count, 2, "presses 1 s apart both shake")

        // Two presses decided within 0.6 s.
        let t = world.uptime
        guard_.handlePhysical(rawFlags: rightOptionDown, at: t)
        guard_.handlePhysical(rawFlags: noModifiers, at: t + 0.05)
        guard_.handlePhysical(rawFlags: rightOptionDown, at: t + 0.1)
        guard_.handlePhysical(rawFlags: noModifiers, at: t + 0.15)
        world.advance(to: t + 1)
        XCTAssertEqual(presenter.presented.count, 3)
    }

    func testHoldIsReportedWithoutWaitingForTheRelease() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { guard_.stopPollingForTesting() }

        guard_.handlePhysical(rawFlags: rightOptionDown, at: world.uptime)
        world.advance(to: world.uptime + HotkeyInterceptionDetector.holdDecision + 0.01)

        XCTAssertEqual(presenter.presented.count, 1, "a voice hold that never started")
    }

    func testBusyMainThreadDefersTheVerdict() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        let t = world.uptime
        guard_.handlePhysical(rawFlags: rightOptionDown, at: t)
        guard_.handlePhysical(rawFlags: noModifiers, at: t + 0.1)

        // The main thread was stuck for a second: the decision runs late and
        // the delivered events are only now handled.
        world.uptime = t + 1.5
        let due = world.scheduled
        world.scheduled = []
        for item in due { item.work() }
        guard_.handleDelivered(rawFlags: rightOptionDown, at: t + 0.001)
        guard_.handleDelivered(rawFlags: noModifiers, at: t + 0.101)
        world.advance(to: t + 3)

        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testProbeIsRetriedLaterWithoutAccessibility() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        probe.allowStart = false
        let guard_ = makeGuard(world, probe: probe, presenter: presenter)
        guard_.handleDelivered(rawFlags: noModifiers, at: world.uptime)
        guard_.handleDelivered(rawFlags: noModifiers, at: world.uptime)
        XCTAssertEqual(probe.starts, 1, "not on every modifier press")

        probe.allowStart = true
        world.uptime += HotkeyInterceptionGuard.probeRetryInterval
        guard_.handleDelivered(rawFlags: noModifiers, at: world.uptime)
        XCTAssertEqual(probe.starts, 2)
        XCTAssertTrue(probe.isRunning)
    }

    func testProbeMovesBackToTheHeadWhenANewHIDFilterAppears() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps
        let guard_ = started(world, probe, presenter)
        XCTAssertEqual(probe.starts, 1)

        guard_.keepProbeAtHead()
        XCTAssertEqual(probe.starts, 1, "nothing new in front")

        world.taps.append(EventTapRecord(id: 30, location: .hid, isActiveFilter: true, enabled: true,
                                         tappingPID: puntoPID, eventsOfInterest: keysAndModifiers))
        guard_.keepProbeAtHead()
        XCTAssertEqual(probe.starts, 2)
        XCTAssertTrue(probe.isRunning)
        guard_.keepProbeAtHead()
        XCTAssertEqual(probe.starts, 2)
    }

    func testWatchedKeysFollowTheSwitchedOnFeatures() {
        let defaults = HotkeyConfiguration.defaults
        XCTAssertEqual(HotkeyInterceptionGuard.watchedKeys(in: defaults, agentEnabled: true, googleEnabled: true),
                       [.rightCommand, .rightOption])
        XCTAssertEqual(HotkeyInterceptionGuard.watchedKeys(in: defaults, agentEnabled: true, googleEnabled: false),
                       [.rightCommand])
        XCTAssertEqual(HotkeyInterceptionGuard.watchedKeys(in: defaults, agentEnabled: false, googleEnabled: false), [])
    }
}

/// Secure Input and an interceptor share the one badge beside the island.
@MainActor
final class HotkeyBlockerBadgeStackTests: XCTestCase {
    private final class FakeSurface: HotkeyBlockerBadgeSurface {
        var onSelfDismiss: (() -> Void)?
        var shown: SecureInputHolderBadge?
        var log: [String] = []
        var isShowing: Bool { shown != nil }

        func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool) {
            shown = badge
            log.append("present \(badge.app?.name ?? "-") shake=\(shake)")
        }

        func dismiss() {
            shown = nil
            log.append("dismiss")
        }

        func fadeByItself() {
            shown = nil
            onSelfDismiss?()
        }
    }

    private let dia = SecureInputHolderBadge(app: SecureInputApp(pid: 1, name: "Dia", bundleID: nil))
    private let punto = SecureInputHolderBadge(app: SecureInputApp(pid: 2, name: "Punto Switcher", bundleID: nil),
                                               message: "Punto Switcher is intercepting Right Option")

    func testNoWindowUntilTheFirstBadge() {
        var made = 0
        let stack = HotkeyBlockerBadgeStack(makeSurface: { made += 1; return FakeSurface() })
        _ = stack.presenter(for: .secureInput)
        _ = stack.presenter(for: .interception)
        XCTAssertEqual(made, 0)
    }

    func testLatestBadgeShowsAndTheOtherComesBackWhenItLeaves() {
        let surface = FakeSurface()
        let stack = HotkeyBlockerBadgeStack(makeSurface: { surface })
        let secure = stack.presenter(for: .secureInput)
        let interception = stack.presenter(for: .interception)

        secure.present(dia, shake: false, persistent: true)
        interception.present(punto, shake: true, persistent: true)
        XCTAssertEqual(surface.shown, punto)
        XCTAssertTrue(secure.isShowing, "still Secure Input's badge, only covered")

        interception.dismiss()
        XCTAssertEqual(surface.shown, dia, "Dia's dimmed logo returns")
        XCTAssertEqual(surface.log.last, "present Dia shake=false")
        XCTAssertFalse(interception.isShowing)
    }

    func testOneGuardNeverDismissesTheOthersBadge() {
        let surface = FakeSurface()
        let stack = HotkeyBlockerBadgeStack(makeSurface: { surface })
        let secure = stack.presenter(for: .secureInput)
        let interception = stack.presenter(for: .interception)

        secure.present(dia, shake: false, persistent: true)
        interception.present(punto, shake: true, persistent: true)
        secure.dismiss() // secure input ended
        XCTAssertEqual(surface.shown, punto)
        XCTAssertTrue(interception.isShowing)

        interception.dismiss()
        XCTAssertNil(surface.shown)
        XCTAssertNil(stack.displayed)
    }

    func testFadedShakeBringsBackThePersistentBadge() {
        let surface = FakeSurface()
        let stack = HotkeyBlockerBadgeStack(makeSurface: { surface })
        let secure = stack.presenter(for: .secureInput)
        let interception = stack.presenter(for: .interception)

        interception.present(punto, shake: true, persistent: true)
        secure.present(SecureInputHolderBadge(app: nil), shake: true, persistent: false) // unknown holder
        surface.fadeByItself()

        XCTAssertEqual(surface.shown, punto)
        XCTAssertFalse(secure.isShowing)
        XCTAssertTrue(interception.isShowing)
    }

    func testInterceptorBadgeFallsBackToAKeyboardSymbol() {
        XCTAssertEqual(punto.fallbackSymbol, "keyboard")
        XCTAssertEqual(dia.fallbackSymbol, "lock.fill")
        XCTAssertEqual(punto.label, "Punto Switcher is intercepting Right Option")
    }
}
