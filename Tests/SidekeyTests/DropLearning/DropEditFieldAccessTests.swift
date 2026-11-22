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
    private var requestedRanges: [CFRange] = []
    private var text = "Скачай Whytap с сайта"

    override func setUp() {
        super.setUp()
        frontmost = targetPID
        focused = field
        count = (text as NSString).length
        requestedRanges = []
        duringLength = nil
        duringTransfer = nil
    }

    private func access() -> AXDropEditFieldAccess {
        AXDropEditFieldAccess(system: .init(
            frontmostPID: { [unowned self] in frontmost },
            focusedElement: { [unowned self] in focused },
            elementPID: { [unowned self] element in CFEqual(element, field) ? targetPID : otherPID },
            isRunning: { _ in true },
            facts: { _, _ in
                DropEditFieldFacts(bundleID: "com.apple.Notes", isOwnProcess: false, role: "AXTextArea",
                                   subrole: nil, secureEventInput: false, accessibilityError: false)
            },
            characterCount: { [unowned self] _ in
                duringLength?()
                return count
            },
            string: { [unowned self] _, range in
                requestedRanges.append(range)
                duringTransfer?()
                return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            }
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
}
