import XCTest
@testable import Sidekey

@MainActor
final class InsertExecutorTests: XCTestCase {
    override func tearDown() {
        FocusSnapshot.resetDependencies()
        super.tearDown()
    }

    func testAvailableVariantsUseSnapshotAppAndSelectionContext() {
        let executor = InsertExecutor(
            formatter: ClientInsertFormatter(),
            textInserter: TextInserter(),
            snapshot: snapshot(bundleID: "com.tinyspeck.slackmacgap")
        )

        let variants = executor.availableVariants(for: calendarEventBlock)

        XCTAssertEqual(variants.map(\.id), [
            "slack_link",
            "url_only",
            "title_only",
            "markdown_link",
            "full_plain_text",
            "replace_selection"
        ])
        XCTAssertEqual(variants.first?.text, "<https://calendar.google.com/event|Planning>")
        XCTAssertEqual(variants.last?.actionType, .replace)
    }

    func testExecutePasteRestoresFocusAndPastesText() async throws {
        let appProvider = MockFocusSnapshotApplicationProvider()
        FocusSnapshot.applicationProvider = appProvider
        var pasted: [String] = []
        var replaced: [String] = []
        let executor = InsertExecutor(
            formatter: ClientInsertFormatter(),
            textInserter: TextInserter(
                paste: { pasted.append($0) },
                replaceSelection: {
                    replaced.append($0)
                    return true
                }
            ),
            snapshot: nil
        )
        let variant = InsertVariant(
            id: "full_text",
            label: "Full text",
            text: "hello",
            actionType: .paste
        )

        let didInsert = try await executor.execute(
            variant,
            snapshot: snapshot(bundleID: "com.example.Target")
        )

        XCTAssertTrue(didInsert)
        XCTAssertEqual(appProvider.activatedPIDs, [123])
        XCTAssertEqual(pasted, ["hello"])
        XCTAssertTrue(replaced.isEmpty)
    }

    func testExecutePasteRefreshesFrontmostTargetAtExecutionTime() async throws {
        let currentFrontmost = FocusSnapshotApplication(
            processIdentifier: 456,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )
        let appProvider = MockFocusSnapshotApplicationProvider(frontmost: currentFrontmost)
        FocusSnapshot.applicationProvider = appProvider
        FocusSnapshot.axReader = MockFocusSnapshotAXReader()
        var pasted: [String] = []
        let executor = InsertExecutor(
            formatter: ClientInsertFormatter(),
            textInserter: TextInserter(
                paste: { pasted.append($0) },
                replaceSelection: { _ in false }
            ),
            snapshot: nil
        )
        let variant = InsertVariant(
            id: "url_only",
            label: "URL",
            text: "https://example.com",
            actionType: .paste
        )

        let didInsert = try await executor.execute(
            variant,
            snapshot: snapshot(bundleID: "com.example.Original")
        )

        XCTAssertTrue(didInsert)
        XCTAssertEqual(appProvider.activatedPIDs, [456])
        XCTAssertEqual(pasted, ["https://example.com"])
    }

    func testExecuteReplaceRestoresFocusAndWritesSelectionForCompatibleApp() async throws {
        let appProvider = MockFocusSnapshotApplicationProvider()
        FocusSnapshot.applicationProvider = appProvider
        var pasted: [String] = []
        var replaced: [String] = []
        let executor = InsertExecutor(
            formatter: ClientInsertFormatter(),
            textInserter: TextInserter(
                paste: { pasted.append($0) },
                replaceSelection: {
                    replaced.append($0)
                    return true
                }
            ),
            snapshot: nil
        )

        let didInsert = try await executor.execute(
            replaceVariant(text: "replacement"),
            snapshot: snapshot(bundleID: "com.tinyspeck.slackmacgap")
        )

        XCTAssertTrue(didInsert)
        XCTAssertEqual(appProvider.activatedPIDs, [123])
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(replaced, ["replacement"])
    }

    func testExecuteReplaceReturnsFalseForUnsupportedAppWithoutAXWrite() async throws {
        let appProvider = MockFocusSnapshotApplicationProvider()
        FocusSnapshot.applicationProvider = appProvider
        var replaced: [String] = []
        let executor = InsertExecutor(
            formatter: ClientInsertFormatter(),
            textInserter: TextInserter(
                paste: { _ in },
                replaceSelection: {
                    replaced.append($0)
                    return true
                }
            ),
            snapshot: nil
        )

        let didInsert = try await executor.execute(
            replaceVariant(text: "replacement"),
            snapshot: snapshot(bundleID: "com.apple.mail")
        )

        XCTAssertFalse(didInsert)
        XCTAssertTrue(appProvider.activatedPIDs.isEmpty)
        XCTAssertTrue(replaced.isEmpty)
    }

    func testExecuteReplaceReturnsFalseWhenAXWriteIsRejected() async throws {
        let appProvider = MockFocusSnapshotApplicationProvider()
        FocusSnapshot.applicationProvider = appProvider
        var replaced: [String] = []
        let executor = InsertExecutor(
            formatter: ClientInsertFormatter(),
            textInserter: TextInserter(
                paste: { _ in },
                replaceSelection: {
                    replaced.append($0)
                    return false
                }
            ),
            snapshot: nil
        )

        let didInsert = try await executor.execute(
            replaceVariant(text: "replacement"),
            snapshot: snapshot(bundleID: "com.microsoft.VSCode")
        )

        XCTAssertFalse(didInsert)
        XCTAssertEqual(appProvider.activatedPIDs, [123])
        XCTAssertEqual(replaced, ["replacement"])
    }

    private func replaceVariant(text: String) -> InsertVariant {
        InsertVariant(
            id: "replace_selection",
            label: "Replace selection",
            text: text,
            actionType: .replace
        )
    }

    private func snapshot(
        bundleID: String?,
        isEditable: Bool = true,
        selectionText: String? = "selection"
    ) -> FocusSnapshot {
        FocusSnapshot(
            targetPID: 123,
            bundleID: bundleID,
            appName: "Target",
            selectionText: selectionText,
            isEditable: isEditable,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private var calendarEventBlock: UIBlock {
        .entityCard(EntityCardBlock(
            entityType: .calendarEvent,
            name: "Planning",
            description: "Weekly planning",
            url: URL(string: "https://calendar.google.com/event")
        ))
    }
}

private final class MockFocusSnapshotApplicationProvider: FocusSnapshotApplicationProviding {
    private let frontmost: FocusSnapshotApplication?
    private(set) var activatedPIDs: [pid_t] = []

    init(frontmost: FocusSnapshotApplication? = nil) {
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
    func focusedElement() -> FocusSnapshotAXElement {
        FocusSnapshotAXElement()
    }
}
