import Combine
import CryptoKit
import XCTest
@testable import Sidekey

@MainActor
final class CaseViewModelTests: XCTestCase {
    func test_unlock_loads_payload_and_exposes_rows_without_values() async throws {
        let secretID = UUID()
        let payload = CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-secret-value")]
        )
        let env = TestCaseEnvironment(payload: payload)
        let vm = env.makeViewModel()

        try await vm.unlock()

        XCTAssertEqual(vm.unlockState, .unlocked)
        XCTAssertEqual(vm.rows.map(\.displayName), ["OPENAI_API_KEY"])
        XCTAssertFalse(String(describing: vm.rows).contains("sk-secret-value"))
    }

    func test_create_key_moves_from_name_to_hidden_value_mode_and_saves() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.submitName("open ai api key")
        XCTAssertEqual(vm.inputMode, .value(name: "OPEN_AI_API_KEY", groupID: nil))

        try vm.submitValue("sk-secret-value")

        XCTAssertEqual(env.savedPayload?.secrets.map(\.name), ["OPEN_AI_API_KEY"])
        XCTAssertEqual(env.savedPayload?.values.map(\.value), ["sk-secret-value"])
        XCTAssertEqual(vm.inputMode, .name)
    }

    func test_copy_writes_value_to_injected_pasteboard_and_updates_usage() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-secret-value")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.copySecret(secretID)

        XCTAssertEqual(env.pasteboard.lastString, "sk-secret-value")
        XCTAssertEqual(env.savedPayload?.secrets.first?.copyCount, 1)
        XCTAssertNotNil(env.savedPayload?.secrets.first?.lastCopiedAt)
    }

    func test_edit_replaces_value_without_revealing_old_value() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OLD_NAME")],
            values: [CaseSecretValue(secretID: secretID, value: "old-secret")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.replaceSecret(secretID, rawName: "new name", newValue: "new-secret")

        XCTAssertEqual(env.savedPayload?.secrets.first?.name, "NEW_NAME")
        XCTAssertEqual(env.savedPayload?.values.first?.value, "new-secret")
        XCTAssertFalse(String(describing: vm.rows).contains("old-secret"))
    }

    func test_rename_preserves_hidden_value_without_revealing_it() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OLD_NAME")],
            values: [CaseSecretValue(secretID: secretID, value: "old-secret")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.renameSecret(secretID, rawName: "new name")

        XCTAssertEqual(env.savedPayload?.secrets.first?.name, "NEW_NAME")
        XCTAssertEqual(env.savedPayload?.values.first?.value, "old-secret")
        XCTAssertFalse(String(describing: vm.rows).contains("old-secret"))
    }

    func test_idle_timeout_locks_and_drops_rows() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(name: "OPENAI_API_KEY")],
            values: []
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        vm.expireUnlockedSessionForTesting()

        XCTAssertEqual(vm.unlockState, .locked)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func test_unlock_schedules_fifteen_minute_idle_lock() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()

        try await vm.unlock()

        XCTAssertEqual(vm.unlockedSessionSecondsForTesting, 15 * 60)
        XCTAssertTrue(vm.hasScheduledIdleLockForTesting)
    }

    func test_stale_idle_lock_does_not_lock_after_session_refresh() async throws {
        let secretID = UUID()
        let scheduler = CapturingIdleLockScheduler()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-secret-value")]
        ))
        let vm = env.makeViewModel(scheduleIdleLock: scheduler.schedule)
        try await vm.unlock()
        let staleLock = try XCTUnwrap(scheduler.scheduled.first?.action)

        try vm.copySecret(secretID)
        XCTAssertEqual(scheduler.scheduled.count, 2)

        staleLock()

        XCTAssertEqual(vm.unlockState, .unlocked)
        XCTAssertEqual(vm.rows.map(\.displayName), ["OPENAI_API_KEY"])
    }

    func test_unlock_failure_publishes_sanitized_message() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: ScaryCaseVaultError(message: "storage blew up with sk-secret-value")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock()) { error in
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }

        XCTAssertEqual(vm.unlockState, .failed("Unable to unlock Case"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-secret-value"))
    }

    func test_unlock_failure_after_unlocked_session_clears_stale_state() async throws {
        let secretID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: secretID, name: "OPENAI_API_KEY")],
            values: [CaseSecretValue(secretID: secretID, value: "sk-stale-value")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()
        try vm.submitName("new key")

        env.failLoads(with: ScaryCaseVaultError(message: "storage blew up with sk-stale-value"))

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .failed("Unable to unlock Case"))
        XCTAssertTrue(vm.rows.isEmpty)
        XCTAssertEqual(vm.inputMode, .name)
        XCTAssertFalse(String(describing: vm.rows).contains("sk-stale-value"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-stale-value"))
    }

    func test_unlock_key_provider_failure_publishes_and_throws_sanitized_error() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            keyError: ScaryCaseVaultError(message: "keychain leaked sk-secret-value")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock()) { error in
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }

        XCTAssertEqual(vm.unlockState, .failed("Unable to unlock Case"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-secret-value"))
    }

    func test_unlock_missing_file_save_failure_publishes_and_throws_sanitized_error() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.missingFile,
            saveError: ScaryCaseVaultError(message: "save leaked sk-secret-value")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock()) { error in
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }

        XCTAssertEqual(vm.unlockState, .failed("Unable to unlock Case"))
        XCTAssertFalse(String(describing: vm.unlockState).contains("sk-secret-value"))
    }

    func test_unlock_undecryptable_vault_enters_needs_reset() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .needsReset("Couldn't unlock this Case. Reset to start over."))
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func test_unlock_invalid_envelope_enters_needs_reset() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.invalidEnvelope
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .needsReset("Couldn't unlock this Case. Reset to start over."))
    }

    func test_unlock_newer_schema_vault_enters_needs_newer_app_not_needs_reset() async {
        // A vault written by a future build has schemaVersion > current. The
        // vault decrypted fine — the user just needs to update the app. This
        // must NOT be classified as undecryptable and must NOT offer Reset.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.needsNewerApp
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .needsNewerApp("Update the app to open this Case."))
    }

    func test_newer_schema_vault_does_not_classify_as_undecryptable() async {
        // isUndecryptableVault must return false for needsNewerApp so the
        // "Reset to start over" path is never reached.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CaseVaultStoreError.needsNewerApp
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        // Crucially, must not be .needsReset — that would offer destructive Reset.
        if case .needsReset = vm.unlockState {
            XCTFail("needsNewerApp vault must not surface as needsReset")
        }
    }

    func test_reset_requires_confirm_step_first_call_arms_then_second_executes() async throws {
        // The confirm step lives on the view model: first resetVault() arms the
        // confirmation, second actually deletes. This prevents accidental reset
        // from a single misclick.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())

        // First call must arm, NOT delete.
        let armed = vm.armResetVault()
        XCTAssertTrue(armed, "First call must return true (armed), not execute reset")
        XCTAssertEqual(env.store.resetCallCount, 0, "First call must not delete the vault")

        // Second call while armed executes the reset.
        try vm.resetVault()
        XCTAssertEqual(env.store.resetCallCount, 1, "Second call must delete the vault")
    }

    func test_arm_reset_publishes_change_so_confirm_ui_can_render() async throws {
        // The panel's "Confirm Reset" label and warning copy key off
        // isResetArmed. Arming must emit objectWillChange or SwiftUI never
        // re-renders and the confirm step is invisible to the user.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())

        var changeCount = 0
        let cancellable = vm.objectWillChange.sink { changeCount += 1 }
        defer { cancellable.cancel() }

        vm.armResetVault()

        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(vm.isResetArmed)
    }

    func test_reset_arm_expires_so_misclick_recovery_requires_re_arm() async throws {
        // Arming must auto-disarm: if the user navigates away and back,
        // the confirm state should not persist indefinitely.
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())

        _ = vm.armResetVault()
        // Simulate disarm (e.g. panel closed/reopened)
        vm.disarmResetVault()
        // resetVault without prior arm must not delete
        XCTAssertThrowsError(try vm.resetVault()) { error in
            XCTAssertEqual(error as? CaseViewModelError, .resetNotArmed)
        }
        XCTAssertEqual(env.store.resetCallCount, 0)
    }

    func test_unlock_generic_storage_error_stays_failed_not_needs_reset() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: ScaryCaseVaultError(message: "io blew up")
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(vm.unlockState, .failed("Unable to unlock Case"))
    }

    func test_reset_vault_discards_file_and_allows_fresh_unlock() async throws {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            loadError: CryptoKitError.authenticationFailure
        )
        let vm = env.makeViewModel()
        await XCTAssertAsyncThrows(try await vm.unlock())
        XCTAssertEqual(vm.unlockState, .needsReset("Couldn't unlock this Case. Reset to start over."))

        vm.armResetVault()
        try vm.resetVault()
        XCTAssertEqual(env.store.resetCallCount, 1)
        XCTAssertEqual(vm.unlockState, .locked)

        // Stub reset() flips load to missingFile -> a fresh empty vault unlocks.
        try await vm.unlock()
        XCTAssertEqual(vm.unlockState, .unlocked)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func test_unlock_authenticates_before_reading_key() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()

        try await vm.unlock()

        XCTAssertEqual(env.authenticator.authenticateCallCount, 1)
        XCTAssertEqual(env.keys.readCallCount, 1)
    }

    func test_unlock_authentication_failure_does_not_read_key() async {
        let env = TestCaseEnvironment(
            payload: CaseVaultPayload(),
            authError: CaseAuthenticationError.denied
        )
        let vm = env.makeViewModel()

        await XCTAssertAsyncThrows(try await vm.unlock())

        XCTAssertEqual(env.authenticator.authenticateCallCount, 1)
        XCTAssertEqual(env.keys.readCallCount, 0)
        XCTAssertEqual(vm.unlockState, .failed("Unable to unlock Case"))
    }

    func test_query_change_refreshes_idle_lock() async throws {
        let scheduler = CapturingIdleLockScheduler()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(name: "OPENAI_API_KEY")],
            values: []
        ))
        let vm = env.makeViewModel(scheduleIdleLock: scheduler.schedule)
        try await vm.unlock()

        vm.query = "open"

        XCTAssertEqual(scheduler.scheduled.count, 2)
        XCTAssertTrue(scheduler.scheduled[0].cancellable.isCancelled)
        XCTAssertEqual(scheduler.scheduled[1].delaySeconds, 15 * 60)
    }

    func test_delete_secret_clears_orphaned_group_id_when_group_dissolves() async throws {
        let groupID = UUID()
        let deletedID = UUID()
        let survivingID = UUID()
        let payload = CaseVaultPayload(
            secrets: [
                secret(id: deletedID, name: "AWS_ACCESS_KEY", groupID: groupID),
                secret(id: survivingID, name: "AWS_SECRET_KEY", groupID: groupID)
            ],
            values: [
                CaseSecretValue(secretID: deletedID, value: "deleted-value"),
                CaseSecretValue(secretID: survivingID, value: "surviving-value")
            ],
            groups: [
                group(id: groupID, name: "AWS", keyIDs: [deletedID, survivingID])
            ]
        )
        let env = TestCaseEnvironment(payload: payload)
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.deleteSecret(deletedID)

        XCTAssertTrue(env.savedPayload?.groups.isEmpty ?? false)
        XCTAssertEqual(env.savedPayload?.secrets.first(where: { $0.id == survivingID })?.groupID, nil)
        XCTAssertEqual(vm.rows, [CaseDisplayRow(id: survivingID, kind: .secret, displayName: "AWS_SECRET_KEY")])
    }

    func test_create_group_from_dragged_keys() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: firstID, name: "OPENAI_API_KEY"), secret(id: secondID, name: "ANTHROPIC_API_KEY")],
            values: []
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        let createdGroupID = try vm.createGroup(sourceSecretID: firstID, targetSecretID: secondID, name: "AI keys")

        XCTAssertEqual(createdGroupID, env.savedPayload?.groups.first?.id)
        XCTAssertEqual(env.savedPayload?.groups.first?.name, "AI keys")
        XCTAssertEqual(Set(env.savedPayload?.groups.first?.keyIDs ?? []), Set([firstID, secondID]))
        XCTAssertEqual(env.savedPayload?.secrets.first { $0.id == firstID }?.groupID, env.savedPayload?.groups.first?.id)
        XCTAssertEqual(env.savedPayload?.secrets.first { $0.id == secondID }?.groupID, env.savedPayload?.groups.first?.id)
    }

    func test_create_group_rejects_empty_and_too_long_names() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: firstID, name: "OPENAI_API_KEY"), secret(id: secondID, name: "ANTHROPIC_API_KEY")]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        XCTAssertThrowsError(try vm.createGroup(sourceSecretID: firstID, targetSecretID: secondID, name: "   "))
        XCTAssertThrowsError(try vm.createGroup(sourceSecretID: firstID, targetSecretID: secondID, name: String(repeating: "a", count: 49)))
        XCTAssertTrue(env.store.payload.groups.isEmpty)
    }

    func test_create_key_directly_inside_opened_group() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let groupID = UUID()
        let group = CaseGroup(id: groupID, name: "AI keys", keyIDs: [firstID, secondID], copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: firstID, name: "OPENAI_API_KEY", groupID: groupID), secret(id: secondID, name: "ANTHROPIC_API_KEY", groupID: groupID)],
            values: [],
            groups: [group]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.submitName("github token", groupID: groupID)
        try vm.submitValue("ghp-secret")

        XCTAssertEqual(env.savedPayload?.secrets.last?.groupID, groupID)
        XCTAssertEqual(env.savedPayload?.groups.first?.keyIDs.count, 3)
    }

    func test_drag_out_of_two_key_group_collapses_group() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let groupID = UUID()
        let group = CaseGroup(id: groupID, name: "AI keys", keyIDs: [firstID, secondID], copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: firstID, name: "OPENAI_API_KEY", groupID: groupID), secret(id: secondID, name: "ANTHROPIC_API_KEY", groupID: groupID)],
            values: [],
            groups: [group]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.removeSecretFromGroup(firstID)

        XCTAssertTrue(env.savedPayload?.groups.isEmpty ?? false)
        XCTAssertNil(env.savedPayload?.secrets.first { $0.id == firstID }?.groupID)
        XCTAssertNil(env.savedPayload?.secrets.first { $0.id == secondID }?.groupID)
    }

    func test_copy_all_group_emits_env_payload_and_updates_usage() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let groupID = UUID()
        let group = CaseGroup(id: groupID, name: "AI keys", keyIDs: [firstID, secondID], copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [secret(id: firstID, name: "OPENAI_API_KEY", groupID: groupID), secret(id: secondID, name: "ANTHROPIC_API_KEY", groupID: groupID)],
            values: [CaseSecretValue(secretID: firstID, value: "sk-openai"), CaseSecretValue(secretID: secondID, value: "sk-anthropic")],
            groups: [group]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        try vm.copyAll(groupID)

        XCTAssertEqual(env.pasteboard.lastString, "OPENAI_API_KEY=sk-openai\nANTHROPIC_API_KEY=sk-anthropic")
        XCTAssertEqual(env.savedPayload?.groups.first?.copyCount, 1)
        XCTAssertEqual(env.savedPayload?.secrets.map(\.copyCount), [1, 1])
    }

    func test_child_rows_for_group_exposes_names_without_values() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let groupID = UUID()
        let group = CaseGroup(id: groupID, name: "AI keys", keyIDs: [firstID, secondID], copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
        let env = TestCaseEnvironment(payload: CaseVaultPayload(
            secrets: [
                secret(id: firstID, name: "OPENAI_API_KEY", groupID: groupID),
                secret(id: secondID, name: "ANTHROPIC_API_KEY", groupID: groupID)
            ],
            values: [
                CaseSecretValue(secretID: firstID, value: "sk-openai"),
                CaseSecretValue(secretID: secondID, value: "sk-anthropic")
            ],
            groups: [group]
        ))
        let vm = env.makeViewModel()
        try await vm.unlock()

        let childRows = vm.childRows(forGroupID: groupID)

        XCTAssertEqual(childRows.map(\.displayName), ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        XCTAssertFalse(String(describing: childRows).contains("sk-openai"))
        XCTAssertFalse(String(describing: childRows).contains("sk-anthropic"))
    }

    func test_cancel_input_returns_to_name_mode_and_clears_query() async throws {
        let env = TestCaseEnvironment(payload: CaseVaultPayload())
        let vm = env.makeViewModel()
        try await vm.unlock()
        vm.query = "github token"
        try vm.submitName("github token")

        vm.cancelInput()

        XCTAssertEqual(vm.inputMode, .name)
        XCTAssertEqual(vm.query, "")
    }

    private func secret(id: UUID = UUID(), name: String, groupID: UUID? = nil) -> CaseSecret {
        CaseSecret(id: id, name: name, groupID: groupID, copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
    }

    private func group(id: UUID = UUID(), name: String, keyIDs: [UUID]) -> CaseGroup {
        CaseGroup(id: id, name: name, keyIDs: keyIDs, copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
    }
}

@MainActor
private final class TestCaseEnvironment {
    var savedPayload: CaseVaultPayload?
    let pasteboard = StubCasePasteboard()
    let store: StubCaseVaultStore
    let keys: StubCaseVaultKeyProvider
    let authenticator: StubCaseAuthenticator

    init(
        payload: CaseVaultPayload,
        loadError: Error? = nil,
        saveError: Error? = nil,
        keyError: Error? = nil,
        authError: Error? = nil
    ) {
        self.store = StubCaseVaultStore(payload: payload, loadError: loadError, saveError: saveError)
        self.keys = StubCaseVaultKeyProvider(error: keyError)
        self.authenticator = StubCaseAuthenticator(error: authError)
        self.store.onSave = { [weak self] payload in self?.savedPayload = payload }
    }

    func makeViewModel(
        scheduleIdleLock: CaseViewModel.IdleLockScheduler? = nil
    ) -> CaseViewModel {
        CaseViewModel(
            store: store,
            keyProvider: keys,
            authenticator: authenticator,
            pasteboard: pasteboard,
            now: Date.init,
            scheduleIdleLock: scheduleIdleLock
        )
    }

    func failLoads(with error: Error) {
        store.loadError = error
    }
}

private final class StubCaseVaultStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    var loadError: Error?
    var saveError: Error?
    var resetError: Error?
    private(set) var resetCallCount = 0
    var onSave: ((CaseVaultPayload) -> Void)?

    init(payload: CaseVaultPayload, loadError: Error? = nil, saveError: Error? = nil) {
        self.payload = payload
        self.loadError = loadError
        self.saveError = saveError
    }

    func load(using key: SymmetricKey) throws -> CaseVaultPayload {
        if let loadError {
            throw loadError
        }
        return payload
    }

    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws {
        if let saveError {
            throw saveError
        }
        self.payload = payload
        onSave?(payload)
    }

    func reset() throws {
        resetCallCount += 1
        if let resetError {
            throw resetError
        }
        // Model "file deleted": the next load behaves as a fresh (missing) vault.
        loadError = CaseVaultStoreError.missingFile
        payload = CaseVaultPayload()
    }
}

@MainActor
private final class StubCaseVaultKeyProvider: CaseVaultKeyProviding {
    var error: Error?
    private(set) var readCallCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func readOrCreateKey() throws -> SymmetricKey {
        readCallCount += 1
        if let error {
            throw error
        }
        return SymmetricKey(size: .bits256)
    }
}

@MainActor
private final class StubCaseAuthenticator: CaseAuthenticating {
    var error: Error?
    private(set) var authenticateCallCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func authenticate(reason: String) async throws {
        authenticateCallCount += 1
        XCTAssertEqual(reason, "Unlock Case")
        if let error {
            throw error
        }
    }
}

private final class StubCasePasteboard: CasePasteboardWriting {
    var lastString: String?

    func writeString(_ value: String) {
        lastString = value
    }
}

private struct ScaryCaseVaultError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

private func XCTAssertAsyncThrows(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        handler(error)
    }
}

@MainActor
private final class CapturingIdleLockScheduler {
    struct Scheduled {
        let delaySeconds: Int
        let action: @MainActor () -> Void
        let cancellable: StubIdleLockCancellable
    }

    private(set) var scheduled: [Scheduled] = []

    func schedule(delaySeconds: Int, action: @escaping @MainActor () -> Void) -> CaseIdleLockCancellable {
        let cancellable = StubIdleLockCancellable()
        scheduled.append(Scheduled(delaySeconds: delaySeconds, action: action, cancellable: cancellable))
        return cancellable
    }
}

private final class StubIdleLockCancellable: CaseIdleLockCancellable {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
