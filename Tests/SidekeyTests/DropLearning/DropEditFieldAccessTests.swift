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
            appFlagSettable: { [unowned self] _, name in settable.contains(name) },
            watch: { _, _ in nil }
        ))
    }

    func testTheFocusedFieldOfTheFrontmostAppIsReadAsOneBoundedRange() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        XCTAssertEqual(access.read(handle), text)
        XCTAssertEqual(requestedRanges.count, 1)
        XCTAssertEqual(requestedRanges.first?.location, 0)
        XCTAssertEqual(requestedRanges.first?.length, (text as NSString).length)
    }

    func testNothingIsCapturedWhenTheTargetIsNotFrontmost() {
        frontmost = otherPID
        XCTAssertNil(access().capture(pid: targetPID))
    }

    /// The target app keeps its own focused element while the user works in
    /// another app; that is not keyboard focus, and the field is not read.
    func testSwitchingToAnotherAppStopsTheRead() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        frontmost = otherPID
        focused = otherField
        XCTAssertFalse(access.isStillFocused(handle))
        XCTAssertNil(access.read(handle))
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testAnotherFieldWithFocusInTheSameAppIsNotRead() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        focused = otherField
        XCTAssertNil(access.read(handle))
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    /// A field that does not report its length is never transferred: there
    /// is no bound to request.
    func testAFieldWithoutALengthIsNotReadAtAll() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        count = nil
        XCTAssertNil(access.read(handle))
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
        XCTAssertNil(access.read(handle))
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
        XCTAssertNil(access.read(handle))
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testFocusMovingDuringTheTransferDiscardsTheText() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        duringTransfer = { [unowned self] in focused = otherField }
        XCTAssertNil(access.read(handle))
    }

    func testAFieldLongerThanTheLimitIsNotTransferred() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        count = DropEditFieldLimits.maxFieldLength + 1
        XCTAssertNil(access.read(handle))
        XCTAssertTrue(requestedRanges.isEmpty)
    }

    func testAnEmptiedFieldReadsAsEmptyWithoutATransfer() throws {
        let access = access()
        let handle = try XCTUnwrap(access.capture(pid: targetPID))
        count = 0
        XCTAssertEqual(access.read(handle), "")
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
        settable = ["AXEnhancedUserInterface"]
        let lease = try XCTUnwrap(access().exposeFields(pid: targetPID))
        XCTAssertEqual(flags["AXEnhancedUserInterface"], true)
        lease.release()
        XCTAssertEqual(flags["AXEnhancedUserInterface"], false)
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
}
