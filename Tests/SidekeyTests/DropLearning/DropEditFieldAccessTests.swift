import ApplicationServices
import XCTest
@testable import Sidekey

/// The Accessibility side of learning from edits, with the system calls
/// replaced: which element counts as focused, and how much text is ever
/// transferred.
@MainActor
final class DropEditFieldAccessTests: XCTestCase {
    private let targetPID: pid_t = 4242
    private let otherPID: pid_t = 4343
    private lazy var field = AXUIElementCreateApplication(4242)
    private lazy var otherField = AXUIElementCreateApplication(4343)

    private var exposureFocusQueryShouldMoveFrontmost = false
    private var frontmost: pid_t?
    private var focused: AXUIElement?
    private var count: Int?
    private var duringLength: (() -> Void)?
    private var duringTransfer: (() -> Void)?
    private var duringFacts: (() -> Void)?
    private var requestedRanges: [CFRange] = []
    private var text = "Скачай Whytap с сайта"
    private var role = "AXTextArea"
    private var bundleID = "com.apple.Notes"
    private var secureInput = false
    /// The app element's Boolean attributes (nil = cannot be read).
    private var flags: [String: Bool] = [:]
    private var settable: Set<String> = []
    private var flagWrites: [(String, Bool)] = []
    /// The target process's identity (bundle and launch); nil once it quit.
    private var identity: String? = "app@1"

    override func setUp() {
        super.setUp()
        frontmost = targetPID
        focused = field
        count = (text as NSString).length
        requestedRanges = []
        duringLength = nil
        duringTransfer = nil
        duringFacts = nil
        role = "AXTextArea"
        bundleID = "com.apple.Notes"
        secureInput = false
        flags = [:]
        settable = []
        flagWrites = []
        identity = "app@1"
    }

    private func access() -> AXDropEditFieldAccess {
        AXDropEditFieldAccess(system: .init(
            frontmostPID: { [unowned self] in frontmost },
            focusedElement: { [unowned self] in focused },
            elementPID: { [unowned self] element in CFEqual(element, field) ? targetPID : otherPID },
            isRunning: { _ in true },
            facts: { [unowned self] _, _ in
                duringFacts?()
                return DropEditFieldFacts(bundleID: bundleID, isOwnProcess: false, role: role,
                                   subrole: nil, secureEventInput: secureInput, accessibilityError: false)
            },
            characterCount: { [unowned self] _ in
                duringLength?()
                return count
            },
            string: { [unowned self] _, range in
                requestedRanges.append(range)
                duringTransfer?()
                return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            },
            appFlag: { [unowned self] _, name in flags[name] },
            setAppFlag: { [unowned self] _, name, value in
                guard flags[name] != nil || settable.contains(name) else { return false }
                flagWrites.append((name, value))
                flags[name] = value
                return true
            },
            processIdentity: { [unowned self] _ in identity },
            watch: { _, _ in nil }
        ))
    }

    func testTheFocusedFieldOfTheFrontmostAppIsReadAsOneBoundedRange() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        XCTAssertEqual(access.read(handle), .text(text))
        XCTAssertEqual(requestedRanges.count, 1)
        XCTAssertEqual(requestedRanges.first?.location, 0)
        XCTAssertEqual(requestedRanges.first?.length, (text as NSString).length)
    }

    func testNothingIsCapturedWhenTheTargetIsNotFrontmost() {
        frontmost = otherPID
        let access = access()
        XCTAssertNil(access.capture(pid: targetPID))
        XCTAssertEqual(access.lastRefusal, "notFrontmost")
    }

    /// The developer journal and the counters name why a field was refused.
    func testARefusedCaptureNamesItsReason() throws {
        let access = access()
        for (setup, reason) in [({ self.role = "AXWebArea" }, "notTextRole"),
                                ({ self.role = "AXTextField"; self.secureInput = true }, "secureInput"),
                                ({ self.secureInput = false; self.bundleID = "com.apple.Terminal" }, "deniedApp"),
                                ({ self.bundleID = "com.apple.Notes"; self.focused = nil }, "noFocusedElement")] {
            setup()
            XCTAssertNil(access.capture(pid: targetPID), reason)
            XCTAssertEqual(access.lastRefusal, reason)
        }
        focused = field
        XCTAssertNotNil(access.capture(pid: targetPID))
        XCTAssertNil(access.lastRefusal)
    }

    /// The target app keeps its own focused element while the user works in
    /// another app; that is not keyboard focus, and the field is not read.
    func testSwitchingToAnotherAppStopsTheRead() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        frontmost = otherPID
        focused = otherField
        XCTAssertFalse(access.isStillFocused(handle))
        XCTAssertEqual(access.read(handle), .focusLeft)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testAnotherFieldWithFocusInTheSameAppIsNotRead() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        focused = otherField
        XCTAssertEqual(access.read(handle), .focusLeft)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    /// A field that does not report its length is never transferred: there
    /// is no bound to request.
    func testAFieldWithoutALengthIsNotReadAtAll() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        count = nil
        XCTAssertEqual(access.read(handle), .unreadable, "still focused: the watch must not trust old text")
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    /// The length query blocks; focus moving to another app meanwhile stops
    /// the read before any text is requested.
    func testFocusMovingDuringTheLengthQueryStopsBeforeTheTransfer() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        duringLength = { [unowned self] in
            frontmost = otherPID
            focused = otherField
        }
        XCTAssertEqual(access.read(handle), .focusLeft)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    /// The gate's metadata calls block too: focus moving during them, after
    /// the length query, stops the read before any text is requested.
    func testFocusMovingDuringTheFinalMetadataCheckStopsBeforeTheTransfer() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        duringLength = { [unowned self] in
            duringFacts = { [unowned self] in
                frontmost = otherPID
                focused = otherField
            }
        }
        XCTAssertEqual(access.read(handle), .focusLeft)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testFocusMovingDuringTheTransferDiscardsTheText() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        duringTransfer = { [unowned self] in focused = otherField }
        XCTAssertEqual(access.read(handle), .focusLeft)
    }

    func testAFieldLongerThanTheLimitIsNotTransferred() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        count = DropEditFieldLimits.maxFieldLength + 1
        XCTAssertEqual(access.read(handle), .unreadable)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testAnEmptiedFieldReadsAsEmptyWithoutATransfer() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        count = 0
        XCTAssertEqual(access.read(handle), .text(""))
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    // MARK: - Electron and web views

    /// Claude desktop, Slack: Electron shows only a web area until asked;
    /// `AXManualAccessibility` turns its tree on, and the lease turns it off.
    func testAnElectronAppIsAskedToExposeItsFieldsAndRestoredAfter() throws {
        role = "AXWebArea"
        bundleID = "com.anthropic.claudefordesktop"
        flags = ["AXManualAccessibility": false]
        let lease = try XCTUnwrap(access().exposeFields(pid: targetPID))
        XCTAssertEqual(flags["AXManualAccessibility"], true)
        lease.release()
        lease.release()
        XCTAssertEqual(flags["AXManualAccessibility"], false)
        XCTAssertEqual(flagWrites.map(\.0), ["AXManualAccessibility", "AXManualAccessibility"], "set once, undone once")
        XCTAssertNil(flags["AXEnhancedUserInterface"])
    }

    /// Before its tree is on, Electron may report no focused element at all.
    func testAnElectronAppWithNoFocusedElementIsStillExposed() throws {
        focused = nil
        role = "AXApplication"
        bundleID = "com.tinyspeck.slackmacgap"
        flags = ["AXManualAccessibility": false]
        XCTAssertNotNil(access().exposeFields(pid: targetPID))
        XCTAssertEqual(flags["AXManualAccessibility"], true)
    }

    /// A Chromium browser that does not answer `AXManualAccessibility` but
    /// lets `AXEnhancedUserInterface` be set.
    func testABrowserGetsEnhancedUserInterfaceInstead() throws {
        role = "AXGroup"
        bundleID = "com.google.Chrome"
        flags = ["AXEnhancedUserInterface": false]
        let lease = try XCTUnwrap(access().exposeFields(pid: targetPID))
        XCTAssertEqual(flags["AXEnhancedUserInterface"], true)
        lease.release()
        XCTAssertEqual(flags["AXEnhancedUserInterface"], false)
    }

    /// The gate now refuses the same, still focused field (it became a
    /// password field): the kept text must not be trusted.
    func testAFieldTheGateNowRefusesIsUnreadableNotFocusLeft() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        role = "AXSecureTextField"
        XCTAssertEqual(access.read(handle), .unreadable)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    /// The metadata calls block: another app coming to the front meanwhile
    /// stops the write.
    func testExposureKeepsForegroundThroughTheBlockingMetadataRead() {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        duringFacts = { [unowned self] in
            frontmost = otherPID
            focused = otherField
        }
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    /// Focus moved to another element of the same app during the metadata
    /// read: the gate judged a different element, nothing is written.
    func testExposureStopsWhenFocusMovesWithinTheApp() {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        duringFacts = { [unowned self] in focused = AXUIElementCreateApplication(4444) }
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    /// An attribute that cannot be read is never written, even if setting
    /// it would succeed: there is no known value to restore.
    func testExposureDoesNotChangeAnAttributeWhoseValueIsUnknown() {
        role = "AXGroup"
        bundleID = "com.google.Chrome"
        settable = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    /// The value became unreadable while watching: release writes nothing.
    func testReleaseDoesNotRestoreWithoutConfirmingWhytapStillOwnsTheValue() throws {
        role = "AXGroup"
        flags = ["AXEnhancedUserInterface": false]
        let lease = try XCTUnwrap(access().exposeFields(pid: targetPID))
        flags.removeValue(forKey: "AXEnhancedUserInterface")
        lease.release()
        XCTAssertEqual(flagWrites.map(\.1), [true])
    }

    /// The app quit and its pid was reused: the new process is never touched.
    func testReleaseLeavesANewProcessWithTheSamePidAlone() throws {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        let lease = try XCTUnwrap(access().exposeFields(pid: targetPID))
        identity = "other@2"
        lease.release()
        XCTAssertEqual(flagWrites.count, 1)
        identity = nil
        lease.release()
        XCTAssertEqual(flagWrites.count, 1)
    }

    func testAProcessWithoutIdentityIsNeverExposed() {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        identity = nil
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    func testANativeTextFieldNeedsNothing() {
        flags = ["AXManualAccessibility": false]
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    /// VoiceOver, the user or another tool already turned it on: it stays
    /// theirs and is never turned off by Whytap.
    func testAnAppWithItsTreeAlreadyOnIsLeftAlone() {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": true, "AXEnhancedUserInterface": true]
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    /// Turned off while watching by someone else: not turned on or off again.
    func testTheLeaveDoesNotFightAnotherToolThatChangedIt() throws {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        let lease = try XCTUnwrap(access().exposeFields(pid: targetPID))
        flags["AXManualAccessibility"] = false
        lease.release()
        XCTAssertEqual(flagWrites.count, 1)
    }

    /// Terminals, password managers, secure input: never exposed.
    func testRefusedAppsAndSecureInputAreNeverExposed() {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        bundleID = "com.1password.1password"
        XCTAssertNil(access().exposeFields(pid: targetPID))
        bundleID = "com.tinyspeck.slackmacgap"
        secureInput = true
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    func testAnAppInTheBackgroundIsNeverExposed() {
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        frontmost = otherPID
        XCTAssertNil(access().exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    // MARK: - Builder review #437 scenarios

    func testAFailedFocusLookupIsUnreadableNotFocusLeft() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        // Same frontmost process. AX failed to return its focused element.
        focused = nil
        XCTAssertEqual(access.read(handle), .unreadable)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testExposureRechecksTheFrontAppWhenThereWasNoFocusedElement() {
        let system = AXDropEditFieldAccess.System(
            frontmostPID: { [unowned self] in frontmost },
            focusedElement: { [unowned self] in
                if exposureFocusQueryShouldMoveFrontmost {
                    frontmost = otherPID
                    return otherField
                }
                return nil
            },
            elementPID: { [unowned self] _ in otherPID },
            isRunning: { _ in true },
            facts: { _, _ in
                DropEditFieldFacts(bundleID: "com.tinyspeck.slackmacgap", isOwnProcess: false,
                                   role: "AXApplication", subrole: nil,
                                   secureEventInput: false, accessibilityError: false)
            },
            characterCount: { _ in nil },
            string: { _, _ in nil },
            appFlag: { [unowned self] _, _ in
                exposureFocusQueryShouldMoveFrontmost = true
                return false
            },
            setAppFlag: { [unowned self] _, attribute, value in
                flagWrites.append((attribute, value))
                return true
            },
            processIdentity: { _ in "app@1" },
            watch: { _, _ in nil }
        )
        XCTAssertNil(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        XCTAssertEqual(frontmost, otherPID)
        XCTAssertTrue(flagWrites.isEmpty)
    }

    func testReleaseRechecksTheProcessAfterTheBlockingFlagRead() throws {
        let system = AXDropEditFieldAccess.System(
            frontmostPID: { [unowned self] in frontmost },
            focusedElement: { [unowned self] in focused },
            elementPID: { [unowned self] _ in targetPID },
            isRunning: { _ in true },
            facts: { _, _ in
                DropEditFieldFacts(bundleID: "com.tinyspeck.slackmacgap", isOwnProcess: false,
                                   role: "AXWebArea", subrole: nil,
                                   secureEventInput: false, accessibilityError: false)
            },
            characterCount: { _ in nil },
            string: { _, _ in nil },
            appFlag: { [unowned self] _, _ in
                // The flag query returns a value from the old process just
                // as it exits and a new process is assigned the PID.
                if !flagWrites.isEmpty {
                    identity = "app@2"
                    return true
                }
                return false
            },
            setAppFlag: { [unowned self] _, attribute, value in
                flagWrites.append((attribute, value))
                return true
            },
            processIdentity: { [unowned self] _ in identity },
            watch: { _, _ in nil }
        )
        let lease = try XCTUnwrap(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        lease.release()
        XCTAssertEqual(identity, "app@2")
        XCTAssertEqual(flagWrites.map(\.1), [true])
    }

    func testReleaseCancelsAnAcceptedEnableThatIsStillPending() throws {
        var flagIsOn = false
        var pendingEnable = false
        let system = AXDropEditFieldAccess.System(
            frontmostPID: { [unowned self] in frontmost },
            focusedElement: { [unowned self] in focused },
            elementPID: { [unowned self] _ in targetPID },
            isRunning: { _ in true },
            facts: { _, _ in
                DropEditFieldFacts(bundleID: "com.tinyspeck.slackmacgap", isOwnProcess: false,
                                   role: "AXWebArea", subrole: nil,
                                   secureEventInput: false, accessibilityError: false)
            },
            characterCount: { _ in nil },
            string: { _, _ in nil },
            appFlag: { _, _ in flagIsOn },
            setAppFlag: { _, _, value in
                pendingEnable = value
                if !value { flagIsOn = false }
                return true
            },
            processIdentity: { _ in "app@1" },
            watch: { _, _ in nil }
        )
        let lease = try XCTUnwrap(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        XCTAssertTrue(pendingEnable)
        XCTAssertFalse(flagIsOn)
        // Opt-out while Electron has accepted the request but has yet to
        // apply it. Its debounced enable becomes visible later.
        lease.release()
        if pendingEnable { flagIsOn = true }
        XCTAssertFalse(flagIsOn)
    }

    func testExposureRechecksSecureInputAfterTheFlagRead() {
        let system = AXDropEditFieldAccess.System(
            frontmostPID: { [unowned self] in frontmost },
            focusedElement: { [unowned self] in focused },
            elementPID: { [unowned self] _ in targetPID },
            isRunning: { _ in true },
            facts: { [unowned self] _, _ in
                DropEditFieldFacts(bundleID: "com.tinyspeck.slackmacgap", isOwnProcess: false,
                                   role: "AXWebArea", subrole: nil,
                                   secureEventInput: secureInput, accessibilityError: false)
            },
            characterCount: { _ in nil },
            string: { _, _ in nil },
            appFlag: { [unowned self] _, _ in
                // Focus is unchanged. A secure input session began during AX IPC.
                secureInput = true
                return false
            },
            setAppFlag: { [unowned self] _, attribute, value in
                flagWrites.append((attribute, value))
                return true
            },
            processIdentity: { _ in "app@1" },
            watch: { _, _ in nil }
        )
        XCTAssertNil(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    /// A focus query that fails is not "no field": nothing is exposed.
    func testAFailedFocusLookupNeverExposes() {
        role = "AXApplication"
        flags = ["AXManualAccessibility": false]
        var system = systemForFocus { .failed }
        system.facts = { [unowned self] _, _ in
            DropEditFieldFacts(bundleID: "com.tinyspeck.slackmacgap", isOwnProcess: false, role: role,
                               subrole: nil, secureEventInput: false, accessibilityError: false)
        }
        XCTAssertNil(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }

    /// A confirmed absence of a focused element (Electron before its tree is
    /// on) still lets the app be exposed.
    func testAConfirmedAbsentFocusStillExposesTheApp() {
        role = "AXApplication"
        flags = ["AXManualAccessibility": false]
        let system = systemForFocus { .none }
        XCTAssertNotNil(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        XCTAssertEqual(flagWrites.map(\.1), [true])
    }

    /// Same app in front, the field's focus query reports nothing: unknown,
    /// so the watch must drop its kept text rather than count it.
    func testNoFocusedElementReportedIsUnreadableNotFocusLeft() throws {
        var lookup: DropEditFocus = .element(field)
        let access = AXDropEditFieldAccess(system: systemForFocus { lookup })
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        lookup = .none
        XCTAssertEqual(access.read(handle), .unreadable)
        lookup = .failed
        XCTAssertEqual(access.read(handle), .unreadable)
        lookup = .element(otherField)
        XCTAssertEqual(access.read(handle), .focusLeft)
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    private func systemForFocus(_ focus: @escaping () -> DropEditFocus) -> AXDropEditFieldAccess.System {
        AXDropEditFieldAccess.System(
            frontmostPID: { [unowned self] in frontmost },
            focusedElement: { nil },
            elementPID: { [unowned self] element in CFEqual(element, field) ? targetPID : otherPID },
            isRunning: { _ in true },
            facts: { [unowned self] _, _ in
                DropEditFieldFacts(bundleID: bundleID, isOwnProcess: false, role: role,
                                   subrole: nil, secureEventInput: secureInput, accessibilityError: false)
            },
            characterCount: { [unowned self] _ in count },
            string: { [unowned self] _, range in
                requestedRanges.append(range)
                return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            },
            appFlag: { [unowned self] _, name in flags[name] },
            setAppFlag: { [unowned self] _, name, value in
                flagWrites.append((name, value))
                flags[name] = value
                return true
            },
            processIdentity: { [unowned self] _ in identity },
            watch: { _, _ in nil },
            focus: focus
        )
    }

    // MARK: - Builder review #440 scenarios

    /// During the second, blocking metadata read focus moves to another
    /// element of the same app, or another client turns the flag on. Either
    /// way nothing is written, at acquisition or at release.
    func testTheSecondMetadataReadChangingFocusOrTheFlagWritesNothing() {
        for attribute in AXDropEditFieldAccess.exposeAttributes {
            for change in ["focus moves within the app", "another client turns it on"] {
                let pid = targetPID
                let original = AXUIElementCreateApplication(pid)
                let replacement = AXUIElementCreateApplication(4243)
                var focusedNow = original
                var flag = false
                var metadataReads = 0
                var writes: [Bool] = []
                let access = AXDropEditFieldAccess(system: .init(
                    frontmostPID: { pid },
                    focusedElement: { focusedNow },
                    elementPID: { _ in pid },
                    isRunning: { _ in true },
                    facts: { element, _ in
                        metadataReads += 1
                        if metadataReads == 2 {
                            if change == "focus moves within the app" { focusedNow = replacement } else { flag = true }
                        }
                        let isOriginal = CFEqual(element, original)
                        return DropEditFieldFacts(bundleID: "com.example.SyntheticHost", isOwnProcess: false,
                                                  role: isOriginal ? "AXWebArea" : "AXTextField",
                                                  subrole: isOriginal ? nil : "AXSecureTextField",
                                                  secureEventInput: false, accessibilityError: false)
                    },
                    characterCount: { _ in nil },
                    string: { _, _ in nil },
                    appFlag: { _, name in name == attribute ? flag : nil },
                    setAppFlag: { _, _, value in
                        writes.append(value)
                        flag = value
                        return true
                    },
                    processIdentity: { _ in "synthetic@1" },
                    watch: { _, _ in nil },
                    focus: { .element(focusedNow) }
                ))
                let lease = access.exposeFields(pid: pid)
                lease?.release()
                XCTAssertNil(lease, "\(attribute): \(change)")
                XCTAssertEqual(writes, [], "\(attribute): \(change)")
            }
        }
    }

    /// With nothing changing during the reads the same setup is exposed and
    /// restored, so the test above fails only for the race.
    func testTheSameSetupWithoutARaceIsExposedAndRestored() throws {
        for attribute in AXDropEditFieldAccess.exposeAttributes {
            let pid = targetPID
            let original = AXUIElementCreateApplication(pid)
            var flag = false
            var writes: [Bool] = []
            let access = AXDropEditFieldAccess(system: .init(
                frontmostPID: { pid },
                focusedElement: { original },
                elementPID: { _ in pid },
                isRunning: { _ in true },
                facts: { _, _ in
                    DropEditFieldFacts(bundleID: "com.example.SyntheticHost", isOwnProcess: false, role: "AXWebArea",
                                       subrole: nil, secureEventInput: false, accessibilityError: false)
                },
                characterCount: { _ in nil },
                string: { _, _ in nil },
                appFlag: { _, name in name == attribute ? flag : nil },
                setAppFlag: { _, _, value in
                    writes.append(value)
                    flag = value
                    return true
                },
                processIdentity: { _ in "synthetic@1" },
                watch: { _, _ in nil },
                focus: { .element(original) }
            ))
            let lease = try XCTUnwrap(access.exposeFields(pid: pid), attribute)
            lease.release()
            XCTAssertEqual(writes, [true, false], attribute)
        }
    }

    // MARK: - Builder review #442 scenarios

    /// Secure input starting during the final flag read or the final focus
    /// lookup: nothing is written. A stable target is exposed and restored.
    func testSecureInputStartingDuringTheFinalQueriesWritesNothing() {
        let pid = targetPID
        let field = AXUIElementCreateApplication(pid)
        for attribute in AXDropEditFieldAccess.exposeAttributes {
            for transition in ["stable", "flag read", "focus lookup"] {
                var secure = false
                var flagReads = 0
                var flag = false
                var writes: [Bool] = []
                let access = AXDropEditFieldAccess(system: .init(
                    frontmostPID: { pid },
                    focusedElement: { field },
                    elementPID: { _ in pid },
                    isRunning: { _ in true },
                    facts: { _, _ in
                        DropEditFieldFacts(bundleID: "com.example.SyntheticHost", isOwnProcess: false, role: "AXWebArea",
                                           subrole: nil, secureEventInput: secure, accessibilityError: false)
                    },
                    characterCount: { _ in nil },
                    string: { _, _ in nil },
                    appFlag: { _, name in
                        guard name == attribute else { return nil }
                        flagReads += 1
                        if transition == "flag read", flagReads == 2, writes.isEmpty { secure = true }
                        return flag
                    },
                    setAppFlag: { _, _, value in
                        writes.append(value)
                        flag = value
                        return true
                    },
                    processIdentity: { _ in "synthetic@1" },
                    watch: { _, _ in nil },
                    focus: {
                        if transition == "focus lookup", flagReads == 2, writes.isEmpty { secure = true }
                        return .element(field)
                    }
                ))
                let lease = access.exposeFields(pid: pid)
                lease?.release()
                if transition == "stable" {
                    XCTAssertNotNil(lease, attribute)
                    XCTAssertEqual(writes, [true, false], attribute)
                } else {
                    XCTAssertNil(lease, "\(attribute): \(transition)")
                    XCTAssertEqual(writes, [], "\(attribute): \(transition)")
                }
            }
        }
    }

    /// The live check is the non-blocking secure input query, taken last.
    func testTheSecureInputQueryIsTakenAfterTheLastFocusLookup() {
        var events: [String] = []
        var secure = false
        var system = systemForFocus { events.append("focus"); return .element(self.field) }
        system.focusedElement = { nil }
        system.secureInput = { events.append("secure"); return secure }
        role = "AXWebArea"
        flags = ["AXManualAccessibility": false]
        XCTAssertNotNil(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        XCTAssertEqual(events.last, "secure")
        flags = ["AXManualAccessibility": false]
        flagWrites = []
        secure = true
        XCTAssertNil(AXDropEditFieldAccess(system: system).exposeFields(pid: targetPID))
        XCTAssertTrue(flagWrites.isEmpty)
    }
}
