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

    func testMessageNamesEveryOwnerAsAPossibleInterceptor() {
        XCTAssertEqual(HotkeyInterceptorClassifier.message(for: [punto], key: .rightOption),
                       "Punto Switcher may be intercepting Right Option")
        XCTAssertEqual(HotkeyInterceptorClassifier.message(for: [punto, btt], key: .rightCommand),
                       "Punto Switcher or BetterTouchTool may be intercepting Right Command")
        let third = SecureInputApp(pid: 1, name: "Karabiner", bundleID: nil)
        XCTAssertEqual(HotkeyInterceptorClassifier.message(for: [punto, btt, third], key: .rightOption),
                       "Punto Switcher or another app may be intercepting Right Option")
    }

    func testVerdictCandidatesNeedTheContextThePressBeganIn() {
        let taps = ordinaryTaps + [puntoTap]
        let context = HotkeyPressContext(
            frontmostPID: frontPID,
            filterIDs: HotkeyInterceptorClassifier.filterIDs(in: taps, ownPID: ownPID, frontmostPID: frontPID))
        XCTAssertEqual(HotkeyInterceptorClassifier.candidates(in: taps, context: context, frontmostPID: frontPID,
                                                             ownPID: ownPID, process: process), [punto])
        XCTAssertEqual(HotkeyInterceptorClassifier.candidates(in: taps, context: context, frontmostPID: 777,
                                                             ownPID: ownPID, process: process), [],
                       "another app came to front before the verdict")
        let before = HotkeyPressContext(
            frontmostPID: frontPID,
            filterIDs: HotkeyInterceptorClassifier.filterIDs(in: ordinaryTaps, ownPID: ownPID, frontmostPID: frontPID))
        XCTAssertEqual(HotkeyInterceptorClassifier.candidates(in: taps, context: before, frontmostPID: frontPID,
                                                             ownPID: ownPID, process: process), [],
                       "a filter that appeared after the press began cannot have taken it")
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

    private let shift: UInt64 = 0x020000
    private let watchedBoth: Set<HotkeyModifierKey> = [.rightOption, .rightCommand]

    /// One physical change, with event time and main-thread time equal.
    @discardableResult
    private func phys(_ d: inout HotkeyInterceptionDetector, _ flags: UInt64, _ t: TimeInterval,
                      watched: Set<HotkeyModifierKey>? = nil) -> [HotkeyInterceptionDetector.Change] {
        d.physical(rawFlags: flags, eventTime: t, seenAt: t, watched: watched ?? watchedBoth)
    }

    private func firstID(_ changes: [HotkeyInterceptionDetector.Change]) -> Int? {
        for change in changes { if case .began(let id, _) = change { return id } }
        return nil
    }

    func testDeliveredPressIsNotBlocked() {
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        _ = d.delivered(rawFlags: rightOptionDown, eventTime: 10)
        phys(&d, noModifiers, 10.1)
        _ = d.delivered(rawFlags: noModifiers, eventTime: 10.1)
        XCTAssertEqual(d.decide(id, now: 10.4), .delivered(.rightOption))
        XCTAssertNil(d.decide(id, now: 10.6), "one verdict per press")
    }

    func testSwallowedPressIsBlocked() {
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        phys(&d, noModifiers, 10.1)
        XCTAssertEqual(d.decide(id, now: 10.4), .blocked(.rightOption))
    }

    func testRewrittenFlagsAreBlocked() {
        // The interceptor lets the event through but clears the right-side bit.
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        _ = d.delivered(rawFlags: leftOptionDown, eventTime: 10)
        phys(&d, noModifiers, 10.1)
        _ = d.delivered(rawFlags: noModifiers, eventTime: 10.1)
        XCTAssertEqual(d.decide(id, now: 10.4), .blocked(.rightOption))
    }

    func testDeliveryHandledBeforeThePhysicalPressStillCounts() {
        var d = HotkeyInterceptionDetector()
        _ = d.delivered(rawFlags: rightOptionDown, eventTime: 10)
        let id = firstID(phys(&d, rightOptionDown, 10))!
        phys(&d, noModifiers, 10.1)
        XCTAssertEqual(d.decide(id, now: 10.4), .delivered(.rightOption))
    }

    func testReleasedPressWaitsForItsOwnReleaseGrace() {
        // Released just before the 0.5 s hold deadline: judged only after
        // the release grace, never by the hold callback.
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        phys(&d, noModifiers, 10.45)
        XCTAssertNil(d.decide(id, now: 10.5), "hold deadline of a released press")
        XCTAssertNil(d.decide(id, now: 10.7))
        XCTAssertEqual(d.decide(id, now: 10.75), .blocked(.rightOption))
    }

    func testDeliveryDuringTheReleaseGraceResolvesThePress() {
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        phys(&d, noModifiers, 10.45)
        XCTAssertNil(d.decide(id, now: 10.5))
        _ = d.delivered(rawFlags: rightOptionDown, eventTime: 10) // a busy main thread hands it over late
        _ = d.delivered(rawFlags: noModifiers, eventTime: 10.45)
        XCTAssertEqual(d.decide(id, now: 10.75), .delivered(.rightOption))
    }

    func testALaterDeliveredPressNeverCoversAnEarlierLostOne() {
        var d = HotkeyInterceptionDetector()
        let lost = firstID(phys(&d, rightOptionDown, 10))!
        phys(&d, noModifiers, 10.1)
        let ordinary = firstID(phys(&d, rightOptionDown, 10.2))!
        _ = d.delivered(rawFlags: rightOptionDown, eventTime: 10.2)
        phys(&d, noModifiers, 10.3)
        _ = d.delivered(rawFlags: noModifiers, eventTime: 10.3)
        XCTAssertEqual(d.decide(lost, now: 10.6), .blocked(.rightOption))
        XCTAssertEqual(d.decide(ordinary, now: 10.6), .delivered(.rightOption))
    }

    func testAReconstructedPressInsideTheSameHoldCounts() {
        // An app that swallows the press and posts its own while the key is held.
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        _ = d.delivered(rawFlags: rightOptionDown, eventTime: 10.05)
        phys(&d, noModifiers, 10.1)
        XCTAssertEqual(d.decide(id, now: 10.4), .delivered(.rightOption))
    }

    func testADeliveryAfterABlockedVerdictTakesItBack() {
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        phys(&d, noModifiers, 10.1)
        XCTAssertEqual(d.decide(id, now: 10.4), .blocked(.rightOption))
        XCTAssertEqual(d.delivered(rawFlags: rightOptionDown, eventTime: 10), [id])
    }

    func testOptionWithShiftIsNotAnOptionOnlyShortcut() {
        var d = HotkeyInterceptionDetector()
        XCTAssertTrue(phys(&d, rightOptionDown | shift, 10).isEmpty, "down together with Shift")
        phys(&d, rightOptionDown, 10.05) // Shift released, Right ⌥ still held: no new press
        phys(&d, noModifiers, 10.1)
        XCTAssertTrue(d.presses.isEmpty)

        let both = firstID(phys(&d, rightOptionDown, 11))!
        phys(&d, rightOptionDown | shift, 11.05) // Shift added during the gesture: cancelled
        let ended = phys(&d, noModifiers, 11.1)
        XCTAssertTrue(ended.isEmpty)
        XCTAssertNil(d.decide(both, now: 12))

        XCTAssertTrue(phys(&d, rightOptionDown | leftOptionDown, 13).isEmpty, "both Options")
    }

    func testLongHoldIsJudgedWhileHeld() {
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        XCTAssertNil(d.decide(id, now: 10.2), "too young")
        XCTAssertEqual(d.decide(id, now: 10.5), .blocked(.rightOption))
        phys(&d, noModifiers, 12)
        XCTAssertNil(d.decide(id, now: 12.3), "already reported")
    }

    func testUnwatchedKeyIsIgnored() {
        var d = HotkeyInterceptionDetector()
        XCTAssertTrue(phys(&d, rightCommandDown, 10, watched: [.rightOption]).isEmpty)
    }

    func testResetRetiresReleasedPressesToo() {
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        phys(&d, noModifiers, 10.1)
        d.reset()
        XCTAssertNil(d.decide(id, now: 10.4))
    }

    // MARK: - Guard

    private final class FakeProbe: HotkeyPressProbing {
        var isRunning = false
        var allowStart = true
        var starts = 0
        var deliver: (@MainActor (UInt64, TimeInterval, TimeInterval) -> Void)?
        var onFailure: (@MainActor () -> Void)?

        func start(deliver: @escaping @MainActor (UInt64, TimeInterval, TimeInterval) -> Void,
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
        var front: pid_t? = 600
        var uptime: TimeInterval = 100
        var scheduled: [(at: TimeInterval, work: @MainActor () -> Void)] = []

        /// Runs every scheduled work due by `time`, in order.
        @MainActor func advance(to time: TimeInterval) {
            while let next = scheduled.enumerated().filter({ $0.element.at <= time })
                .min(by: { $0.element.at < $1.element.at }) {
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
            frontmostPID: { world.front },
            ownPID: ownPID,
            isSessionInteractive: { world.interactive },
            uptime: { world.uptime },
            after: { delay, work in world.scheduled.append((world.uptime + delay, work)) }
        )
        return HotkeyInterceptionGuard(system: system, probe: probe, makePresenter: { presenter })
    }

    private func started(_ world: World, _ probe: FakeProbe, _ presenter: FakePresenter) -> HotkeyInterceptionGuard {
        let guard_ = makeGuard(world, probe: probe, presenter: presenter)
        guard_.bindingsOrSessionChanged()
        XCTAssertTrue(probe.isRunning)
        return guard_
    }

    /// The probe reports a change now (event time = main-thread time).
    private func probeSees(_ probe: FakeProbe, _ world: World, _ flags: UInt64) {
        probe.deliver?(flags, world.uptime, world.uptime)
    }

    /// A Right Option tap: the probe sees it; `delivered` says whether
    /// Whytap's shortcut monitors do too.
    private func tapRightOption(_ guard_: HotkeyInterceptionGuard, _ probe: FakeProbe, _ world: World,
                                delivered: Bool) {
        let t = world.uptime
        probeSees(probe, world, rightOptionDown)
        if delivered { guard_.handleDelivered(rawFlags: rightOptionDown, eventTime: t) }
        world.advance(to: t + 0.1)
        probeSees(probe, world, noModifiers)
        if delivered { guard_.handleDelivered(rawFlags: noModifiers, eventTime: t + 0.1) }
        world.advance(to: t + 1)
    }

    func testPuntoSwallowingRightOptionShakesItsLogoBriefly() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)

        tapRightOption(guard_, probe, world, delivered: false)

        XCTAssertEqual(presenter.presented.count, 1)
        let shown = presenter.presented[0]
        XCTAssertEqual(shown.badge.app, punto)
        XCTAssertEqual(shown.badge.label, "Punto Switcher may be intercepting Right Option")
        XCTAssertTrue(shown.shake)
        XCTAssertFalse(shown.persistent, "REV 1: shown about 3 s, then hidden; never left dimmed")
    }

    func testDeliveredPressShowsNothing() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        tapRightOption(guard_, probe, world, delivered: true)
        XCTAssertTrue(presenter.presented.isEmpty, "Punto is running but did not take this key")
    }

    func testLostPressWithOnlyBenignTapsShowsNothing() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps
        let guard_ = started(world, probe, presenter)
        tapRightOption(guard_, probe, world, delivered: false)
        XCTAssertTrue(presenter.presented.isEmpty, "never blame Whytap, Apple or a listen-only tap")
    }

    func testShiftRightOptionNeverShakes() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} } // callbacks hold it weakly
        let t = world.uptime
        probeSees(probe, world, rightOptionDown | shift)
        world.advance(to: t + 0.1)
        probeSees(probe, world, noModifiers)
        world.advance(to: t + 1)
        XCTAssertTrue(presenter.presented.isEmpty, "Whytap's monitors would not take Shift+Right Option either")
    }

    func testLockedSessionHasNoProbe() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.interactive = false
        let guard_ = makeGuard(world, probe: probe, presenter: presenter)
        guard_.bindingsOrSessionChanged()
        XCTAssertFalse(probe.isRunning)

        world.interactive = true
        guard_.bindingsOrSessionChanged()
        XCTAssertTrue(probe.isRunning)
        world.interactive = false // locked mid-press
        world.taps = ordinaryTaps + [puntoTap]
        probeSees(probe, world, rightOptionDown)
        guard_.bindingsOrSessionChanged()
        XCTAssertFalse(probe.isRunning)
        world.advance(to: world.uptime + 2)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testCallbackFromAStoppedProbeIsDiscarded() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        let oldDeliver = probe.deliver!

        // A press released just before the probe is reinstalled.
        probeSees(probe, world, rightOptionDown)
        world.advance(to: world.uptime + 0.1)
        probeSees(probe, world, noModifiers)
        world.taps.append(EventTapRecord(id: 40, location: .hid, isActiveFilter: true, enabled: true,
                                         tappingPID: bttPID, eventsOfInterest: 1 << 12))
        guard_.keepProbeAtHead()
        XCTAssertEqual(probe.starts, 2)
        // An event the old tap had already dispatched arrives afterwards.
        oldDeliver(rightOptionDown, world.uptime, world.uptime)
        oldDeliver(noModifiers, world.uptime + 0.1, world.uptime + 0.1)
        world.advance(to: world.uptime + 2)

        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testFirstModifierBindingInstallsTheProbeAndTheLastRemovesIt() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.watched = []
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = makeGuard(world, probe: probe, presenter: presenter)
        guard_.bindingsOrSessionChanged()
        XCTAssertFalse(probe.isRunning)

        world.watched = [.rightOption] // Google search switched on in Settings
        guard_.bindingsOrSessionChanged()
        XCTAssertTrue(probe.isRunning, "no modifier press needed first")
        tapRightOption(guard_, probe, world, delivered: false)
        XCTAssertEqual(presenter.presented.count, 1, "the very first press is caught")

        world.watched = []
        guard_.bindingsOrSessionChanged()
        XCTAssertFalse(probe.isRunning)
    }

    func testFrontmostChangeBeforeTheVerdictShowsNothing() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} } // callbacks hold it weakly
        let t = world.uptime
        probeSees(probe, world, rightOptionDown)
        world.advance(to: t + 0.1)
        probeSees(probe, world, noModifiers)
        world.front = 777
        world.advance(to: t + 1)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testFilterInstalledAfterThePressIsNotNamed() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} } // callbacks hold it weakly
        let t = world.uptime
        probeSees(probe, world, rightOptionDown)
        world.taps.append(puntoTap)
        world.advance(to: t + 0.1)
        probeSees(probe, world, noModifiers)
        world.advance(to: t + 1)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testLateDeliveryTakesTheBadgeBack() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        let t = world.uptime
        tapRightOption(guard_, probe, world, delivered: false)
        XCTAssertEqual(presenter.presented.count, 1)
        guard_.handleDelivered(rawFlags: rightOptionDown, eventTime: t)
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testEveryLostPressShowsTheLogoAgain() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        tapRightOption(guard_, probe, world, delivered: false)
        tapRightOption(guard_, probe, world, delivered: false)
        tapRightOption(guard_, probe, world, delivered: false)
        XCTAssertEqual(presenter.presented.count, 3)
        XCTAssertTrue(presenter.presented.allSatisfy { $0.shake && !$0.persistent })
        XCTAssertEqual(guard_.lastBadge?.app, punto)
    }

    func testHoldIsReportedWithoutWaitingForTheRelease() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} } // callbacks hold it weakly
        probeSees(probe, world, rightOptionDown)
        world.advance(to: world.uptime + HotkeyInterceptionDetector.holdDecision + 0.01)
        XCTAssertEqual(presenter.presented.count, 1, "a voice hold that never started")
    }

    func testBusyMainThreadDefersTheVerdict() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        let t = world.uptime
        probeSees(probe, world, rightOptionDown)
        world.uptime = t + 0.1
        probeSees(probe, world, noModifiers)

        // The main thread was stuck for a second: the decision runs late and
        // the delivered events are only now handled.
        world.uptime = t + 1.5
        let due = world.scheduled
        world.scheduled = []
        for item in due { item.work() }
        guard_.handleDelivered(rawFlags: rightOptionDown, eventTime: t)
        guard_.handleDelivered(rawFlags: noModifiers, eventTime: t + 0.1)
        world.advance(to: t + 3)

        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testProbeIsRetriedLaterWithoutAccessibility() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        probe.allowStart = false
        let guard_ = makeGuard(world, probe: probe, presenter: presenter)
        guard_.bindingsOrSessionChanged()
        guard_.handleDelivered(rawFlags: noModifiers, eventTime: world.uptime)
        XCTAssertEqual(probe.starts, 1, "not on every modifier press")

        probe.allowStart = true
        world.uptime += HotkeyInterceptionGuard.probeRetryInterval
        guard_.handleDelivered(rawFlags: noModifiers, eventTime: world.uptime)
        XCTAssertEqual(probe.starts, 2)
        XCTAssertTrue(probe.isRunning)
    }

    func testAccessibilityGrantRetriesAtOnce() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        probe.allowStart = false
        let guard_ = makeGuard(world, probe: probe, presenter: presenter)
        guard_.bindingsOrSessionChanged()
        probe.allowStart = true
        guard_.bindingsOrSessionChanged(retryNow: true)
        XCTAssertTrue(probe.isRunning)
    }

    func testProbeMovesBackToTheHeadWhenANewHIDFilterAppears() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps
        let guard_ = started(world, probe, presenter)
        guard_.keepProbeAtHead()
        XCTAssertEqual(probe.starts, 1, "nothing new in front")

        world.taps.append(EventTapRecord(id: 30, location: .hid, isActiveFilter: true, enabled: true,
                                         tappingPID: puntoPID, eventsOfInterest: keysAndModifiers))
        guard_.keepProbeAtHead()
        XCTAssertEqual(probe.starts, 2)
        guard_.keepProbeAtHead()
        XCTAssertEqual(probe.starts, 2)
    }

    func testProbeHeadCheckRunsFromDeliveredChangesAtMostEveryTenSeconds() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps
        let guard_ = started(world, probe, presenter)
        guard_.handleDelivered(rawFlags: noModifiers, eventTime: world.uptime)
        world.taps.append(EventTapRecord(id: 31, location: .hid, isActiveFilter: true, enabled: true,
                                         tappingPID: puntoPID, eventsOfInterest: keysAndModifiers))
        guard_.handleDelivered(rawFlags: noModifiers, eventTime: world.uptime)
        XCTAssertEqual(probe.starts, 1, "checked at the first change, before Punto's tap")

        world.uptime += HotkeyInterceptionGuard.headCheckInterval
        guard_.handleDelivered(rawFlags: noModifiers, eventTime: world.uptime)
        XCTAssertEqual(probe.starts, 2, "moved back in front of Punto's new HID filter")
    }

    func testWatchedKeysFollowTheSwitchedOnFeatures() {
        let defaults = HotkeyConfiguration.defaults
        XCTAssertEqual(HotkeyInterceptionGuard.watchedKeys(in: defaults, agentEnabled: true, googleEnabled: true),
                       [.rightCommand, .rightOption])
        XCTAssertEqual(HotkeyInterceptionGuard.watchedKeys(in: defaults, agentEnabled: true, googleEnabled: false),
                       [.rightCommand])
        XCTAssertEqual(HotkeyInterceptionGuard.watchedKeys(in: defaults, agentEnabled: false, googleEnabled: false), [])
    }

    // MARK: - Hover text

    func testTwoCandidateLabelWrapsInsteadOfRunningOffASmallScreen() {
        let label = HotkeyInterceptorClassifier.message(
            for: [SecureInputApp(pid: 1, name: "Punto Switcher", bundleID: nil),
                  SecureInputApp(pid: 2, name: "BetterTouchTool", bundleID: nil)], key: .rightCommand)
        let height: CGFloat = 32
        let oneLine = SecureInputHolderMetrics.layout(label: label, height: height, maxWidth: 2_000)
        XCTAssertNil(oneLine.wrapWidth, "one line where it fits")
        XCTAssertEqual(oneLine.size.height, height)

        let narrow: CGFloat = 260
        let wrapped = SecureInputHolderMetrics.layout(label: label, height: height, maxWidth: narrow)
        XCTAssertLessThanOrEqual(wrapped.size.width, narrow)
        let wrap = try! XCTUnwrap(wrapped.wrapWidth)
        let needed = (label as NSString).boundingRect(
            with: CGSize(width: wrap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: SecureInputHolderMetrics.labelFont]).height
        XCTAssertGreaterThan(needed, SecureInputHolderMetrics.labelFont.pointSize * 1.5, "really two lines or more")
        XCTAssertGreaterThanOrEqual(wrapped.size.height, needed + 2 * SecureInputHolderMetrics.wrappedVerticalPadding - 0.5,
                                    "the pill is tall enough for every line")
        XCTAssertEqual(SecureInputHolderBadge(app: nil, message: label).label, label,
                       "the accessibility label carries the full text")
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

    func testTransientInterceptorOverSecureInputThenDimmedLogoReturns() {
        let surface = FakeSurface()
        let stack = HotkeyBlockerBadgeStack(makeSurface: { surface })
        let secure = stack.presenter(for: .secureInput)
        let interception = stack.presenter(for: .interception)

        secure.present(dia, shake: false, persistent: true)
        interception.present(punto, shake: true, persistent: false)
        XCTAssertEqual(surface.shown, punto)
        surface.fadeByItself() // ~3 s later
        XCTAssertEqual(surface.shown, dia, "#488's dimmed logo is unchanged")
        XCTAssertFalse(interception.isShowing)
    }

    func testCoveredTransientBadgeNeverComesBack() {
        let surface = FakeSurface()
        let stack = HotkeyBlockerBadgeStack(makeSurface: { surface })
        let secure = stack.presenter(for: .secureInput)
        let interception = stack.presenter(for: .interception)

        interception.present(punto, shake: true, persistent: false)
        secure.present(dia, shake: true, persistent: true)
        XCTAssertFalse(interception.isShowing)
        secure.dismiss()
        XCTAssertNil(surface.shown)
    }

    func testInterceptorBadgeFallsBackToAKeyboardSymbol() {
        XCTAssertEqual(punto.fallbackSymbol, "keyboard")
        XCTAssertEqual(dia.fallbackSymbol, "lock.fill")
        XCTAssertEqual(punto.label, "Punto Switcher is intercepting Right Option")
    }
}

/// Regressions from the builder's review of queue ticket 686.
extension HotkeyInterceptionTests {
    func testQueueReviewMatchesExactDownWhenPreviousReleaseWasNotDelivered() {
        var detector = HotkeyInterceptionDetector()
        let first = firstID(phys(&detector, rightOptionDown, 10))!
        _ = detector.delivered(rawFlags: rightOptionDown, eventTime: 10)
        phys(&detector, noModifiers, 10.1)
        XCTAssertEqual(detector.decide(first, now: 10.4), .delivered(.rightOption))

        let second = firstID(phys(&detector, rightOptionDown, 10.6))!
        _ = detector.delivered(rawFlags: rightOptionDown, eventTime: 10.6)
        phys(&detector, noModifiers, 10.7)
        _ = detector.delivered(rawFlags: noModifiers, eventTime: 10.7)
        XCTAssertEqual(detector.decide(second, now: 11.1), .delivered(.rightOption))
    }

    func testQueueReviewDisablingOneWatchedModifierRetiresItsPendingPress() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} }
        probeSees(probe, world, rightOptionDown)
        world.advance(to: 100.1)
        probeSees(probe, world, noModifiers)
        world.watched = [.rightCommand]
        guard_.bindingsOrSessionChanged()
        world.advance(to: 100.2)
        world.watched = [.rightCommand, .rightOption]
        guard_.bindingsOrSessionChanged()
        world.advance(to: 100.5)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testQueueReviewReplacementTapDoesNotInheritPressContext() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} }
        probeSees(probe, world, rightOptionDown)
        world.advance(to: 100.1)
        probeSees(probe, world, noModifiers)
        let replacement = EventTapRecord(id: 89, location: .session, isActiveFilter: true, enabled: true,
                                         tappingPID: puntoPID, tappedPID: frontPID, eventsOfInterest: keysAndModifiers)
        world.taps = ordinaryTaps + [replacement]
        world.advance(to: 100.5)
        XCTAssertTrue(presenter.presented.isEmpty)
    }
}

extension HotkeyInterceptionTests {
    func testQueueReviewLateCallbackCannotUseATapFromAfterThePress() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} }

        // The HID probe observed the press at 100. The main-thread callback
        // runs after a different app and filter have arrived.
        world.advance(to: 100.2)
        world.front = 777
        world.taps.append(puntoTap)
        probe.deliver?(rightOptionDown, 100, 100)
        probe.deliver?(noModifiers, 100.1, 100.1)
        world.advance(to: 100.6)
        XCTAssertTrue(presenter.presented.isEmpty)
    }
}

/// The same three classes, beyond the builder's exact cases.
extension HotkeyInterceptionTests {
    func testNoDeliveredReleasesAtAllStillMatchesEachPressByItsOwnBoundaries() {
        var d = HotkeyInterceptionDetector()
        let a = firstID(phys(&d, rightOptionDown, 10))!
        _ = d.delivered(rawFlags: rightOptionDown, eventTime: 10)
        phys(&d, noModifiers, 10.1)
        let lost = firstID(phys(&d, rightOptionDown, 10.5))!
        phys(&d, noModifiers, 10.6)
        let c = firstID(phys(&d, rightOptionDown, 11))!
        _ = d.delivered(rawFlags: rightOptionDown, eventTime: 11)
        phys(&d, noModifiers, 11.1)
        XCTAssertEqual(d.decide(a, now: 12), .delivered(.rightOption))
        XCTAssertEqual(d.decide(lost, now: 12), .blocked(.rightOption), "between two arrivals, with no releases delivered")
        XCTAssertEqual(d.decide(c, now: 12), .delivered(.rightOption))
    }

    func testADeliveredChordWithShiftDoesNotCountAsTheShortcut() {
        var d = HotkeyInterceptionDetector()
        let id = firstID(phys(&d, rightOptionDown, 10))!
        _ = d.delivered(rawFlags: rightOptionDown | shift, eventTime: 10) // rewritten on the way
        phys(&d, noModifiers, 10.1)
        XCTAssertEqual(d.decide(id, now: 10.4), .blocked(.rightOption))
    }

    func testUnbindingWhileHeldAndRebindingBeforeReleaseJudgesNothing() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} }
        probeSees(probe, world, rightOptionDown)
        world.watched = [.rightCommand]
        guard_.bindingsOrSessionChanged()
        world.watched = [.rightCommand, .rightOption]
        guard_.bindingsOrSessionChanged()
        world.advance(to: world.uptime + 0.1)
        probeSees(probe, world, noModifiers)
        world.advance(to: world.uptime + 1)
        XCTAssertTrue(presenter.presented.isEmpty, "the press began while it was a shortcut that was then removed")

        tapRightOption(guard_, probe, world, delivered: false)
        XCTAssertEqual(presenter.presented.count, 1, "the next press is judged again")
    }

    func testLateCallbackOfAHoldIsNotAttributed() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} }
        let t = world.uptime
        world.uptime = t + HotkeyInterceptionGuard.maximumContextLag + 0.05
        probe.deliver?(rightOptionDown, t, t)
        world.advance(to: t + 2)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testTheSameTapSurvivingTheVerdictIsNamed() {
        let world = World(), probe = FakeProbe(), presenter = FakePresenter()
        world.taps = ordinaryTaps + [puntoTap]
        let guard_ = started(world, probe, presenter)
        defer { withExtendedLifetime(guard_) {} }
        probeSees(probe, world, rightOptionDown)
        world.advance(to: world.uptime + 0.1)
        probeSees(probe, world, noModifiers)
        world.taps = [puntoTap] + ordinaryTaps // reordered list, same tap id
        world.advance(to: world.uptime + 1)
        XCTAssertEqual(presenter.presented.first?.badge.app, punto)
    }
}
