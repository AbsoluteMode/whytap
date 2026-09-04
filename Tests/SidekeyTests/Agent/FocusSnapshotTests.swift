import ApplicationServices
import XCTest
@testable import Sidekey

final class FocusSnapshotTests: XCTestCase {
    override func tearDown() {
        FocusSnapshot.resetDependencies()
        super.tearDown()
    }

    func testCaptureReadsFrontmostAppAndFocusedAXElement() throws {
        let appProvider = MockFocusSnapshotApplicationProvider(
            frontmost: FocusSnapshotApplication(
                processIdentifier: 4242,
                bundleIdentifier: "com.apple.TextEdit",
                localizedName: "TextEdit"
            )
        )
        FocusSnapshot.applicationProvider = appProvider
        FocusSnapshot.axReader = MockFocusSnapshotAXReader(
            element: FocusSnapshotAXElement(
                selectionText: "selected text",
                role: kAXTextAreaRole as String
            )
        )
        let capturedAt = Date(timeIntervalSince1970: 123)
        FocusSnapshot.dateProvider = { capturedAt }

        let snapshot = try XCTUnwrap(FocusSnapshot.capture())

        XCTAssertEqual(snapshot.targetPID, 4242)
        XCTAssertEqual(snapshot.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(snapshot.appName, "TextEdit")
        XCTAssertEqual(snapshot.selectionText, "selected text")
        XCTAssertTrue(snapshot.isEditable)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
    }

    func testCaptureReturnsNilWithoutFrontmostApp() {
        FocusSnapshot.applicationProvider = MockFocusSnapshotApplicationProvider(frontmost: nil)
        FocusSnapshot.axReader = MockFocusSnapshotAXReader(
            element: FocusSnapshotAXElement(selectionText: "ignored", role: kAXTextAreaRole as String)
        )

        XCTAssertNil(FocusSnapshot.capture())
    }

    func testNonTextAXRoleIsNotEditable() throws {
        FocusSnapshot.applicationProvider = MockFocusSnapshotApplicationProvider(
            frontmost: FocusSnapshotApplication(
                processIdentifier: 7,
                bundleIdentifier: "com.apple.finder",
                localizedName: "Finder"
            )
        )
        FocusSnapshot.axReader = MockFocusSnapshotAXReader(
            element: FocusSnapshotAXElement(selectionText: nil, role: kAXButtonRole as String)
        )

        let snapshot = try XCTUnwrap(FocusSnapshot.capture())

        XCTAssertFalse(snapshot.isEditable)
        XCTAssertNil(snapshot.selectionText)
    }

    func testWithSelectionTextReturnsCopyWithUpdatedSelectionOnly() {
        let original = FocusSnapshot(
            targetPID: 42,
            bundleID: "com.example.Target",
            appName: "Target",
            selectionText: nil,
            isEditable: true,
            capturedAt: Date(timeIntervalSince1970: 5)
        )

        let updated = original.withSelectionText("captured via Cmd+C")

        XCTAssertEqual(updated.selectionText, "captured via Cmd+C")
        XCTAssertEqual(updated.targetPID, original.targetPID)
        XCTAssertEqual(updated.bundleID, original.bundleID)
        XCTAssertEqual(updated.appName, original.appName)
        XCTAssertEqual(updated.isEditable, original.isEditable)
        XCTAssertEqual(updated.capturedAt, original.capturedAt)
        XCTAssertNil(original.selectionText, "Original must be unchanged.")
    }

    func testRestoreFocusActivatesTargetPIDOnly() {
        let appProvider = MockFocusSnapshotApplicationProvider(frontmost: nil)
        FocusSnapshot.applicationProvider = appProvider
        let snapshot = FocusSnapshot(
            targetPID: 99,
            bundleID: "com.example.Target",
            appName: "Target",
            selectionText: nil,
            isEditable: false,
            capturedAt: Date()
        )

        XCTAssertTrue(snapshot.restoreFocus())
        XCTAssertEqual(appProvider.activatedPIDs, [99])
        XCTAssertEqual(appProvider.sidekeyActivationCalls, 0)
    }
}

private final class MockFocusSnapshotApplicationProvider: FocusSnapshotApplicationProviding {
    let frontmost: FocusSnapshotApplication?
    private(set) var activatedPIDs: [pid_t] = []
    private(set) var sidekeyActivationCalls = 0

    init(frontmost: FocusSnapshotApplication?) {
        self.frontmost = frontmost
    }

    func frontmostApplication() -> FocusSnapshotApplication? {
        frontmost
    }

    func activate(processIdentifier: pid_t) -> Bool {
        activatedPIDs.append(processIdentifier)
        return true
    }
}

private struct MockFocusSnapshotAXReader: FocusSnapshotAXReading {
    let element: FocusSnapshotAXElement

    func focusedElement() -> FocusSnapshotAXElement {
        element
    }
}
