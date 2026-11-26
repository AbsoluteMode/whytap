import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Sidekey

/// Scenarios for the Secure Input holder badge: nobody holds secure input,
/// a background app keeps it after Cmd-Tab, the holder lets go or quits,
/// and the presses that must never be blamed on anyone.
@MainActor
final class SecureInputGuardTests: XCTestCase {
    private let ownPID: pid_t = 100
    private let dia = SecureInputApp(pid: 200, name: "Dia", bundleID: "company.thebrowser.dia")
    private let telegram = SecureInputApp(pid: 300, name: "Telegram", bundleID: "ru.keepcoder.Telegram")
    private let onePassword = SecureInputApp(pid: 400, name: "1Password", bundleID: "com.1password.1password")
    private var whytap: SecureInputApp { SecureInputApp(pid: ownPID, name: "Whytap", bundleID: "com.rootwise.sidekey") }

    private final class World {
        var secureOn = false
        var front: SecureInputApp?
        var secureFieldPIDs = Set<pid_t>()
        var running = Set<pid_t>()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        var lastFire: Date?
        var blocked: Set<ModifierChord> = [.option]
        var pendingSettle: [@MainActor () -> Void] = []
        var axQueries: [pid_t] = []
    }

    private final class FakePresenter: SecureInputHolderPresenting {
        struct Call: Equatable { let badge: SecureInputHolderBadge; let shake: Bool; let persistent: Bool }
        var presented: [Call] = []
        var dismissals = 0
        var isShowing = false
        func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool) {
            presented.append(Call(badge: badge, shake: shake, persistent: persistent))
            isShowing = true
        }
        func dismiss() { dismissals += 1; isShowing = false }
    }

    private var world: World!
    private var presenter: FakePresenter!
    private var guardian: SecureInputGuard!

    override func setUp() {
        super.setUp()
        world = World()
        world.running = [ownPID, dia.pid, telegram.pid, onePassword.pid]
        presenter = FakePresenter()
        let world = world!
        let presenter = presenter!
        let system = SecureInputGuard.System(
            isSecureInputEnabled: { world.secureOn },
            frontmostApp: { world.front },
            focusedElementIsSecure: { pid in world.axQueries.append(pid); return world.secureFieldPIDs.contains(pid) },
            isRunning: { world.running.contains($0) },
            ownPID: ownPID,
            blockedChords: { world.blocked },
            lastHotkeyFire: { world.lastFire },
            now: { world.now },
            afterSwitchSettles: { world.pendingSettle.append($0) }
        )
        guardian = SecureInputGuard(system: system, makePresenter: { presenter })
    }

    override func tearDown() {
        guardian.stopPollingForTesting()
        guardian = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func switchApp(to app: SecureInputApp?) {
        world.front = app
        guardian.handleActivation(app)
    }

    private func settle() {
        let work = world.pendingSettle
        world.pendingSettle = []
        work.forEach { $0() }
    }

    /// Hold `chord` for `seconds`, as a person pressing ⌥F would; the letter
    /// itself is invisible under secure input.
    private func press(_ chord: ModifierChord, for seconds: TimeInterval = 0.2, hotkeyFires: Bool = false) {
        guardian.handleFlagsChanged(chord)
        world.now += seconds / 2
        if hotkeyFires { world.lastFire = world.now }
        world.now += seconds / 2
        guardian.handleFlagsChanged([])
        world.now += 1
    }

    /// Cmd-Tab as macOS delivers it: ⌘ goes down while the old app is still
    /// in front, the new app activates, ⌘ comes up.
    private func cmdTab(to app: SecureInputApp, newAppTurnsSecureInputOn: Bool = false) {
        guardian.handleFlagsChanged(.command)
        world.now += 0.2
        if newAppTurnsSecureInputOn { world.secureOn = true }
        switchApp(to: app)
        guardian.handleFlagsChanged([])
        world.now += 0.1
    }

    /// Dia focuses a password field, then the person Cmd-Tabs to Telegram
    /// and Dia never releases secure input.
    private func stickDiaBehindTelegram() {
        world.front = dia
        guardian.handleActivation(dia)
        settle()
        world.secureOn = true
        cmdTab(to: telegram)
        settle()
    }

    // MARK: - No holder

    func testNoSecureInputShowsNothingWhateverIsPressed() {
        world.front = telegram
        press(.option)
        press([.option, .shift])
        switchApp(to: dia)
        settle()
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(presenter.dismissals, 0)
        XCTAssertFalse(guardian.isPolling)
    }

    // MARK: - Holder found

    func testBackgroundHolderAfterSwitchShowsDimLogoThenShakesOnBlockedShortcut() {
        stickDiaBehindTelegram()

        XCTAssertEqual(presenter.presented, [
            .init(badge: SecureInputHolderBadge(app: dia), shake: false, persistent: true)
        ])
        XCTAssertTrue(guardian.isPolling, "the dim logo must leave when secure input does")

        press(.option) // ⌥F for Shot, never delivered
        XCTAssertEqual(presenter.presented.last,
                       .init(badge: SecureInputHolderBadge(app: dia), shake: true, persistent: true))
        XCTAssertEqual(SecureInputHolderBadge(app: dia).label,
                       "Dia holds secure input — close its password field")
    }

    func testFrontmostHolderNeverShakesBecauseAChordThereMayBeTyping() {
        world.front = dia
        world.secureOn = true // Dia's password field, Dia in front, no AX tree
        press(.option)        // ⌥F, a bare ⌥ tap or an ⌥ letter: all look alike
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertFalse(guardian.isPolling)
    }

    func testBareOptionTapWhileTheKeyboardIsStuckShakesTheAlreadyVisibleLogo() {
        // The disclosed approximation: the key is never seen, so a bare ⌥ tap
        // counts as an attempt, but only while a background app holds the
        // keyboard and its logo is already up.
        stickDiaBehindTelegram()
        guardian.handleFlagsChanged(.option)
        world.now += 0.08
        guardian.handleFlagsChanged([])
        XCTAssertEqual(presenter.presented.last,
                       .init(badge: SecureInputHolderBadge(app: dia), shake: true, persistent: true))
    }

    func testFrontmostPasswordFieldWinsAndTheOneSecondCheckKeepsThatVerdict() {
        stickDiaBehindTelegram()
        world.front = onePassword
        world.secureFieldPIDs = [onePassword.pid]
        press(.option) // ⌥ while typing a 1Password password
        XCTAssertEqual(presenter.presented.count, 1, "typing in a password field is not a failed shortcut")
        XCTAssertEqual(presenter.dismissals, 1, "Dia is no longer blamed")
        XCTAssertNil(guardian.persistentBadge)

        guardian.refresh(askAccessibility: false)
        guardian.refresh(askAccessibility: false)
        XCTAssertEqual(presenter.presented.count, 1, "the 1 s check must not bring Dia back")
        XCTAssertFalse(guardian.isPolling)
    }

    func testTypingInTheFrontAppsPasswordFieldNeverShakes() {
        world.front = dia
        world.secureOn = true
        world.secureFieldPIDs = [dia.pid]
        press(.option)
        press([.option, .shift])
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testAccessibilityIsNotAskedWithoutAnAttemptOrASwitch() {
        world.front = dia
        world.secureOn = true
        press(.command)
        press(.option)
        XCTAssertTrue(world.axQueries.isEmpty, "no remembered app, nothing for Accessibility to decide")
    }

    func testAppTurningSecureInputOnAsItComesForwardDoesNotBlameTheAppLeft() {
        let safari = SecureInputApp(pid: 500, name: "Safari", bundleID: "com.apple.Safari")
        world.running.insert(safari.pid)
        let terminal = SecureInputApp(pid: 600, name: "Terminal", bundleID: "com.apple.Terminal")
        world.running.insert(terminal.pid)
        switchApp(to: safari)
        settle()
        cmdTab(to: terminal, newAppTurnsSecureInputOn: true) // Secure Keyboard Entry
        settle()
        XCTAssertTrue(presenter.presented.isEmpty, "no dimmed Safari logo")
        XCTAssertNil(guardian.persistentBadge)

        press(.option)
        XCTAssertTrue(presenter.presented.isEmpty, "Terminal holds it in front: nobody is blamed")
    }

    func testMouseSwitchWithoutAReadingBeforeItNamesNobody() {
        switchApp(to: dia)
        settle()
        world.secureOn = true
        switchApp(to: telegram) // a click: no modifier change before the switch
        settle()
        XCTAssertTrue(presenter.presented.isEmpty, "no named, dimmed logo without evidence")

        press(.option)
        XCTAssertEqual(presenter.presented, [
            .init(badge: SecureInputHolderBadge(app: nil), shake: true, persistent: false)
        ])
    }

    func testOffSeenWhileAModifierIsDownForgetsTheRememberedApp() {
        stickDiaBehindTelegram()
        world.secureOn = false
        guardian.handleFlagsChanged(.command) // OFF read on a press
        XCTAssertEqual(presenter.dismissals, 1)
        world.secureOn = true                 // something else turns it on
        guardian.handleFlagsChanged([])
        world.now += 1
        press(.option)
        XCTAssertEqual(presenter.presented.count, 1, "Dia is not named again")
    }

    func testOneSecondCheckNeverQueriesAccessibility() {
        stickDiaBehindTelegram()
        world.front = onePassword
        let queries = world.axQueries.count
        guardian.refresh(askAccessibility: false)
        guardian.refresh(askAccessibility: false)
        XCTAssertEqual(world.axQueries.count, queries)
        XCTAssertEqual(guardian.persistentBadge, SecureInputHolderBadge(app: dia))
    }

    // MARK: - Holder gone

    func testHolderReleasingSecureInputRemovesTheLogo() {
        stickDiaBehindTelegram()
        world.secureOn = false
        guardian.refresh() // the 1 s check
        XCTAssertEqual(presenter.dismissals, 1)
        XCTAssertNil(guardian.persistentBadge)
        XCTAssertFalse(guardian.isPolling)

        press(.option)
        XCTAssertEqual(presenter.presented.count, 1, "nothing new once the keyboard is free")
    }

    func testReleaseNoticedOnModifierPressAlsoRemovesTheLogo() {
        stickDiaBehindTelegram()
        world.secureOn = false
        press(.command)
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testConfirmedOffRemovesAShakenLockAtOnceAndItIsWatchedMeanwhile() {
        switchApp(to: dia)
        settle()
        world.secureOn = true
        switchApp(to: telegram)
        settle()
        press(.option)
        XCTAssertEqual(presenter.presented.last?.badge, SecureInputHolderBadge(app: nil))
        XCTAssertTrue(guardian.isPolling, "a shaken badge is watched until it leaves")

        world.secureOn = false
        guardian.refresh(askAccessibility: false) // the 1 s check
        XCTAssertEqual(presenter.dismissals, 1, "no badge may claim secure input once it is off")
        XCTAssertFalse(guardian.isPolling)
    }

    func testPollingStopsOnceAShakenBadgeHasFadedOnItsOwn() {
        switchApp(to: dia)
        settle()
        world.secureOn = true
        switchApp(to: telegram)
        settle()
        press(.option)
        presenter.isShowing = false // the panel's own 2.8 s fade
        guardian.refresh(askAccessibility: false)
        XCTAssertFalse(guardian.isPolling)
    }

    func testHolderQuitWhileSecureInputStaysOnShowsLockInsteadOfAName() {
        stickDiaBehindTelegram()
        world.running.remove(dia.pid)
        guardian.refresh()
        XCTAssertEqual(presenter.dismissals, 1, "no dim logo for an app that is gone")

        XCTAssertFalse(guardian.isPolling, "no 1 s check for an app that is gone")

        press(.option)
        XCTAssertEqual(presenter.presented.last,
                       .init(badge: SecureInputHolderBadge(app: nil), shake: true, persistent: false))
        XCTAssertEqual(SecureInputHolderBadge(app: nil).label,
                       "Another app holds secure input — close its password field")
    }

    func testAppThatReleasesWhenLeftIsNeverBlamed() {
        switchApp(to: dia)
        settle()
        world.secureOn = true
        switchApp(to: telegram)
        world.secureOn = false // Dia let go while losing focus
        settle()
        world.secureOn = true // later Telegram turns secure input on itself
        press(.option)
        XCTAssertTrue(presenter.presented.isEmpty, "Dia is never blamed, Telegram is in front")
    }

    func testSwitchingBackToTheHolderTurnsTheDimLogoOff() {
        stickDiaBehindTelegram()
        switchApp(to: dia)
        settle()
        XCTAssertEqual(presenter.dismissals, 1)
        XCTAssertNil(guardian.persistentBadge)
    }

    // MARK: - Whytap itself

    func testWhytapsOwnPasswordFieldShowsNothing() {
        world.front = whytap
        world.secureOn = true
        press(.option)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testWhytapRememberedAsBackgroundHolderShowsNothing() {
        world.front = whytap
        guardian.handleActivation(whytap)
        settle()
        world.secureOn = true
        cmdTab(to: telegram)
        settle()
        press(.option)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    // MARK: - Presses that are not failed attempts

    func testShortcutThatArrivedIsNotBlamed() {
        stickDiaBehindTelegram()
        press(.option, hotkeyFires: true)
        XCTAssertEqual(presenter.presented.count, 1, "only the dim logo, no shake")
    }

    func testCommandAndControlChordsStillWorkAndNeverShake() {
        world.front = dia
        world.secureOn = true
        press(.command)
        press(.control)
        press([.command, .option])
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testLongModifierHoldIsNotAShortcutAttempt() {
        world.front = dia
        world.secureOn = true
        press(.option, for: SecureInputAttemptDetector.maximumHold + 1)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testRepeatedAttemptsShakeAtMostEveryMinimumInterval() {
        stickDiaBehindTelegram()
        world.now += 1
        guardian.handleFlagsChanged(.option); guardian.handleFlagsChanged([])
        world.now += 0.1
        guardian.handleFlagsChanged(.option); guardian.handleFlagsChanged([])
        XCTAssertEqual(presenter.presented.count, 2)
        world.now += SecureInputGuard.minimumShakeInterval
        guardian.handleFlagsChanged(.option); guardian.handleFlagsChanged([])
        XCTAssertEqual(presenter.presented.count, 3)
    }

    // MARK: - Which shortcuts secure input blocks

    func testBlockedChordsComeFromOptionAndShiftOnlyCombos() {
        var configuration = HotkeyConfiguration.defaults
        configuration.toolShortcuts[.screenshot] = .combo(HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey), keyTitle: "F"))
        configuration.toolShortcuts[.clipboard] = .combo(HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey | optionKey), keyTitle: "X"))
        configuration.meetingRecordShortcut = .combo(HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey | shiftKey), keyTitle: "M"))
        let chords = SecureInputBlockedShortcuts.chords(in: configuration)
        XCTAssertTrue(chords.contains(.option))
        XCTAssertTrue(chords.contains([.option, .shift]))
        XCTAssertFalse(chords.contains([.option, .control]))
        XCTAssertFalse(chords.contains([]), "a bare key leaves no signal to notice")
    }

    func testHoldComboDropOnTheEventTapIsBlockedEvenWithCommand() {
        var configuration = HotkeyConfiguration.defaults
        configuration.dropVoiceShortcut = .combo(HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey), keyTitle: "D"))
        configuration.dropVoiceGesture = .hold
        XCTAssertTrue(SecureInputBlockedShortcuts.chords(in: configuration).contains(.command))

        configuration.dropVoiceGesture = .tap // Carbon: ⌘ combos still fire
        XCTAssertFalse(SecureInputBlockedShortcuts.chords(in: configuration).contains(.command))
    }

    func testModifierChordConversions() {
        XCTAssertEqual(ModifierChord(carbon: UInt32(optionKey | shiftKey)), [.option, .shift])
        XCTAssertEqual(ModifierChord(carbon: UInt32(cmdKey | controlKey)), [.command, .control])
        XCTAssertEqual(ModifierChord(cgFlags: [.maskAlternate, .maskSecondaryFn]), .option)
        XCTAssertEqual(ModifierChord(eventFlags: [.option, .capsLock]), .option)
        XCTAssertTrue(SecureInputBlockedShortcuts.isCarbonBlocked(.option))
        XCTAssertFalse(SecureInputBlockedShortcuts.isCarbonBlocked([.option, .command]))
        XCTAssertFalse(SecureInputBlockedShortcuts.isCarbonBlocked([]))
    }

    // MARK: - Fire recording

    func testCarbonHotkeyRecordsItsArrivalEvenWhenSuppressed() {
        HotkeyFireRecorder.resetForTesting()
        let monitor = CarbonHotkeyMonitor(
            keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey), hotKeyIDValue: 900,
            onHotkey: {}, registerHotKey: { _, _, _, _, _, _ in noErr }, unregisterHotKey: { _ in noErr },
            installHandler: { _, _, _, _, _, _ in noErr }, removeHandler: { _ in noErr },
            dispatchOnMain: { $0() }, shouldSuppress: { true })
        monitor.handleHotKeyEvent()
        XCTAssertNotNil(HotkeyFireRecorder.lastFire)
        HotkeyFireRecorder.resetForTesting()
    }
}
