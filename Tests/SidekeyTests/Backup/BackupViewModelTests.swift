import AppKit
import Combine
import XCTest
@testable import Sidekey

@MainActor
final class BackupViewModelTests: XCTestCase {
    private final class MemoryKey: TokenStore {
        var value: String?; var reads = 0; var writes = 0
        init(_ value: String? = nil) { self.value = value }
        func read() throws -> String? { reads += 1; return value }
        func save(_ value: String) throws { writes += 1; self.value = value }
        func delete() throws { value = nil }
    }
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var key: Data!
    private var keyStore: MemoryKey!
    override func setUp() {
        openCalendarForThisTest()
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "BackupViewModelTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        key = ConfigBackupArchive.makeKey(); keyStore = MemoryKey(key.base64EncodedString())
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }
    private func model(engine: BackupEngineActions? = nil, idle: Bool = true) -> BackupViewModel {
        let fallback = BackupEngineActions(create: { _, _ in throw ConfigBackupError.saveFailed },
            inspect: { _, _ in throw ConfigBackupError.invalidArchive }, stage: { _, _, _ in throw ConfigBackupError.restoreFailed })
        return BackupViewModel(defaults: defaults, keyStore: keyStore, githubTokenStore: MemoryKey(),
            local: BackupLocalStore(root: root.appendingPathComponent("archives")),
            settingsFiles: ConfigBackupFiles(root: root.appendingPathComponent("settings")),
            engine: engine ?? fallback, changeProbe: { "isolated-fixture" }, idle: { idle }, providerStore: { _ in MemoryKey() }, previousRestoreOutcome: { nil })
    }
    func testConstructingASettingsFixtureDoesNotAccessCredentials() {
        _ = model()
        XCTAssertEqual(keyStore.reads, 0); XCTAssertEqual(keyStore.writes, 0)
    }
    func testRecoveryVerificationRequiresTheActualIndependentCode() throws {
        let model = model(); model.beginSetup()
        let code = model.recoveryCode
        XCTAssertFalse(code.isEmpty)
        XCTAssertThrowsError(try model.confirmRecoveryCode(ConfigBackupArchive.recoveryCode(for: ConfigBackupArchive.makeKey())))
        XCTAssertFalse(model.recoverySaved)
        try model.confirmRecoveryCode(code)
        XCTAssertTrue(model.recoverySaved); XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains(code) == true })
        XCTAssertEqual(keyStore.writes, 0)
    }
    func testStartingSetupAgainDoesNotRevealAVerifiedRecoveryCode() throws {
        let model = model(); model.beginSetup()
        try model.confirmRecoveryCode(model.recoveryCode)
        model.beginSetup()
        XCTAssertTrue(model.recoveryCode.isEmpty)
    }
    func testRecoveryCopySuppressesPrivateHistoryAndDoesNotClearANewerCopy() async throws {
        let model = model(); model.beginSetup()
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let suppression = ClipboardSuppression()
        model.copyRecoveryCode(pasteboard: board, suppression: suppression, clearAfterNanoseconds: 10_000_000)
        XCTAssertEqual(board.string(forType: .string), model.recoveryCode)
        XCTAssertTrue(board.types!.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        XCTAssertEqual(suppression.skipThroughChangeCount, board.changeCount)
        board.clearContents(); board.setString("a newer ordinary copy", forType: .string)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(board.string(forType: .string), "a newer ordinary copy")
    }
    /// The markers alone keep the recovery code out of clipboard history,
    /// independent of the suppression threshold the copy also raises. With
    /// no row and no sidecar there is nothing for a backup to carry.
    func testRecoveryCopyNeverReachesClipboardHistory() throws {
        let model = model(); model.beginSetup()
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        model.copyRecoveryCode(pasteboard: board, suppression: ClipboardSuppression(), clearAfterNanoseconds: 10_000_000)
        let store = try SQLiteHistoryStore(path: ":memory:")
        let assets = root.appendingPathComponent("clipboard-assets")
        let watcher = ClipboardWatcher(store: store, assetsDirectory: assets, suppression: ClipboardSuppression())

        let snapshot = ClipboardWatcher.readSnapshot(from: board)
        XCTAssertEqual(snapshot.exclusionMarkers, [.concealed, .transient])
        XCTAssertNil(snapshot.text)
        watcher.handleChange(snapshot: snapshot, changeCount: board.changeCount)
        XCTAssertTrue(try store.latestClipboardEntries(limit: 10).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.path))

        board.clearContents(); board.setString("an ordinary copy", forType: .string)
        watcher.handleChange(snapshot: ClipboardWatcher.readSnapshot(from: board), changeCount: board.changeCount)
        XCTAssertEqual(try store.latestClipboardEntries(limit: 10).count, 1)
    }
    func testFolderBackupIsMarkedCompleteOnlyAfterCopyAndReadback() async throws {
        let id = UUID(), date = Date()
        let summary = ArtifactBackupSummary(id: id, createdAt: date, totalBytes: 4, fileCount: 1, sections: [.settings])
        let engine = BackupEngineActions(create: { file, _ in try Data([1,2,3,4]).write(to: file); return summary },
            inspect: { _, _ in ArtifactBackupPreview(summary: summary, warnings: []) }, stage: { _, _, _ in })
        let folder = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set(try folder.bookmarkData(), forKey: "backup.folder-bookmark.v1")
        defaults.set("folder", forKey: "backup.destination-kind.v1")
        defaults.set("isolated-folder", forKey: "backup.destination-id.v1")
        let model = model(engine: engine); model.isEnabled = false; model.recoverySaved = true
        await model.backupNow()
        XCTAssertFalse(model.isEnabled, "A manual backup must not resume the automatic schedule")
        XCTAssertNil(model.errorMessage); XCTAssertNotNil(model.lastBackupAt); XCTAssertNotNil(model.lastRemoteBackupAt)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(id.uuidString.lowercased() + ".exodiabackup")), Data([1,2,3,4]))
        XCTAssertFalse(model.isBusy)
    }
    func testBusyApplicationCannotStageRestoreOrStartAFullBackup() async {
        defaults.set("folder", forKey: "backup.destination-kind.v1")
        let model = model(idle: false); model.isEnabled = true; model.recoverySaved = true
        await model.backupNow()
        XCTAssertNotNil(model.errorMessage); XCTAssertNil(model.lastBackupAt)
        XCTAssertFalse(model.needsRestart)
    }

    func testCalendarSignInBlocksRestoreBeforeAnySettingsOrCredentialRead() async {
        let previous = AppState.shared.calendarConnectionActive
        defer { AppState.shared.calendarConnectionActive = previous }
        AppState.shared.calendarConnectionActive = true
        let model = model()
        await model.restoreSettingsDefaults(.models)
        XCTAssertEqual(model.errorMessage, "Finish calendar sign-in before restoring a backup.")
        XCTAssertEqual(keyStore.reads, 0)
        XCTAssertFalse(model.needsRestart)
    }

    func testBackupWorkAndStagedRestoreBlockNewCalendarConnections() {
        let model = model()
        let calendars = CalendarConnections(defaults: defaults, backup: model)
        var changes = 0
        let observation = calendars.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        model.isBusy = true
        XCTAssertNotNil(calendars.connectionBlockReason)
        XCTAssertFalse(calendars.beginConnecting(provider: .microsoft))
        model.isBusy = false; model.needsRestart = true
        XCTAssertNotNil(calendars.connectionBlockReason)
        XCTAssertFalse(calendars.beginConnecting(provider: .apple))
        model.needsRestart = false; model.hasPendingMaintenance = true
        XCTAssertNotNil(calendars.connectionBlockReason)
        XCTAssertFalse(calendars.beginConnecting(provider: .google))
        model.hasPendingMaintenance = false
        XCTAssertNil(calendars.connectionBlockReason)
        XCTAssertTrue(calendars.beginConnecting(provider: .microsoft))
        calendars.endConnecting()
        XCTAssertGreaterThanOrEqual(changes, 6, "Calendar controls must observe backup state changes")
        XCTAssertEqual(keyStore.reads, 0)
    }
}
