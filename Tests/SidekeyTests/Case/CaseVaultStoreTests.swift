import CryptoKit
import XCTest
@testable import Sidekey

final class CaseVaultStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaseVaultStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    func test_save_and_load_round_trip() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        let key = SymmetricKey(size: .bits256)
        let secretID = UUID()
        let payload = CaseVaultPayload(
            secrets: [
                CaseSecret(id: secretID, name: "OPENAI_API_KEY", groupID: nil, copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())
            ],
            values: [
                CaseSecretValue(secretID: secretID, value: "sk-secret-value")
            ],
            groups: []
        )

        try store.save(payload, using: key)
        let loaded = try store.load(using: key)

        XCTAssertEqual(loaded, payload)
    }

    func test_ciphertext_file_does_not_contain_secret_value_or_env_payload() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        let key = SymmetricKey(size: .bits256)
        let secretID = UUID()
        let payload = CaseVaultPayload(
            secrets: [CaseSecret(id: secretID, name: "OPENAI_API_KEY", groupID: nil, copyCount: 1, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date())],
            values: [CaseSecretValue(secretID: secretID, value: "sk-secret-value")],
            groups: []
        )

        try store.save(payload, using: key)
        let fileText = try String(contentsOf: store.fileURL, encoding: .utf8)

        XCTAssertFalse(fileText.contains("sk-secret-value"))
        XCTAssertFalse(fileText.contains("OPENAI_API_KEY=sk-secret-value"))
    }

    func test_corrupt_ciphertext_fails_closed() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load(using: SymmetricKey(size: .bits256)))
    }

    func test_missing_file_throws_missing_file() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))

        XCTAssertThrowsError(try store.load(using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CaseVaultStoreError, .missingFile)
        }
    }

    func test_unsupported_envelope_version_throws_unsupported_envelope() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try writeEnvelope(
            CaseVaultEnvelope(version: 2, algorithm: CaseVaultStore.algorithm, nonce: "", ciphertext: "", tag: ""),
            to: store.fileURL
        )

        XCTAssertThrowsError(try store.load(using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CaseVaultStoreError, .unsupportedEnvelope)
        }
    }

    func test_unsupported_algorithm_throws_unsupported_envelope() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try writeEnvelope(
            CaseVaultEnvelope(version: CaseVaultStore.envelopeVersion, algorithm: "ChaChaPoly", nonce: "", ciphertext: "", tag: ""),
            to: store.fileURL
        )

        XCTAssertThrowsError(try store.load(using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CaseVaultStoreError, .unsupportedEnvelope)
        }
    }

    func test_invalid_base64_throws_invalid_envelope() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try writeEnvelope(
            CaseVaultEnvelope(version: CaseVaultStore.envelopeVersion, algorithm: CaseVaultStore.algorithm, nonce: "%%%not-base64%%%", ciphertext: "", tag: ""),
            to: store.fileURL
        )

        XCTAssertThrowsError(try store.load(using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CaseVaultStoreError, .invalidEnvelope)
        }
    }

    func test_invalid_nonce_size_throws_invalid_envelope() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try writeEnvelope(
            CaseVaultEnvelope(
                version: CaseVaultStore.envelopeVersion,
                algorithm: CaseVaultStore.algorithm,
                nonce: Data([0x01]).base64EncodedString(),
                ciphertext: Data([0x02]).base64EncodedString(),
                tag: Data(repeating: 0x03, count: 16).base64EncodedString()
            ),
            to: store.fileURL
        )

        XCTAssertThrowsError(try store.load(using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CaseVaultStoreError, .invalidEnvelope)
        }
    }

    func test_wrong_key_authentication_failure_throws() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try store.save(CaseVaultPayload(), using: SymmetricKey(size: .bits256))

        XCTAssertThrowsError(try store.load(using: SymmetricKey(size: .bits256)))
    }

    func test_saved_directory_uses_private_permissions() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try store.save(CaseVaultPayload(), using: SymmetricKey(size: .bits256))

        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700)
    }

    func test_save_secures_parent_directory_before_write_attempt() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o777)], ofItemAtPath: root.path)
        let fileURL = root.appendingPathComponent("case-vault.json.enc")
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let store = CaseVaultStore(fileURL: fileURL)

        XCTAssertThrowsError(try store.save(CaseVaultPayload(), using: SymmetricKey(size: .bits256)))

        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700)
    }

    func test_unsupported_decrypted_payload_schema_version_fails_closed() throws {
        // A vault with schemaVersion GREATER than current was written by a newer
        // build. It decrypts fine but needs a newer app to interpret — throw
        // needsNewerApp, not unsupportedEnvelope, so the VM can surface the right
        // prompt and skip the destructive Reset path.
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        let key = SymmetricKey(size: .bits256)
        try store.save(CaseVaultPayload(schemaVersion: CaseVaultPayload.currentSchemaVersion + 1), using: key)

        XCTAssertThrowsError(try store.load(using: key)) { error in
            XCTAssertEqual(error as? CaseVaultStoreError, .needsNewerApp)
        }
    }

    func test_older_schema_version_throws_unsupported_envelope() throws {
        // A vault with schemaVersion LESS than current is an old format we no
        // longer understand — treat as unsupportedEnvelope (existing downgrade path).
        // Only version 1 exists today, so this is a future-proofing guard; no
        // migration machinery needed.
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        let key = SymmetricKey(size: .bits256)
        try store.save(CaseVaultPayload(schemaVersion: CaseVaultPayload.currentSchemaVersion - 1), using: key)

        XCTAssertThrowsError(try store.load(using: key)) { error in
            XCTAssertEqual(error as? CaseVaultStoreError, .unsupportedEnvelope)
        }
    }

    func test_saved_file_uses_private_permissions() throws {
        let store = CaseVaultStore(fileURL: root.appendingPathComponent("case-vault.json.enc"))
        try store.save(CaseVaultPayload(), using: SymmetricKey(size: .bits256))

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    private func writeEnvelope(_ envelope: CaseVaultEnvelope, to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: fileURL)
    }
}
