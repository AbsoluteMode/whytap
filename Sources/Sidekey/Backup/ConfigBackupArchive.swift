import CryptoKit
import Foundation

/// Portable archives never use a device-bound key as their only recovery path.
/// WHY: .project-docs/decisions/2026-10-19-config-backup.md
enum ConfigBackupError: Error, LocalizedError, Equatable {
    case invalidCode, cannotUnlock, unsupportedVersion, invalidArchive, tooLarge
    case unsafePath, keyUnavailable, saveFailed, restoreFailed, busy

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "Check your recovery code. Enter every group, including the last one."
        case .cannotUnlock: return "This code could not open the backup. Check the code or choose another backup."
        case .unsupportedVersion: return "This backup needs a newer version of Whytap. Your settings have not changed."
        case .invalidArchive: return "This backup is incomplete or damaged. Choose another version."
        case .tooLarge: return "This backup exceeds a supported size limit. Choose a smaller version or another destination."
        case .unsafePath: return "This location cannot be used safely. Choose another folder."
        case .keyUnavailable: return "Whytap could not access its backup key. Unlock your Mac, or restore with your saved recovery code."
        case .saveFailed: return "The backup could not be saved. Check the folder and available space, then try again."
        case .restoreFailed: return "Settings could not be restored. The previous version has been kept for recovery."
        case .busy: return "Finish recording, dictation and agent work before restoring settings."
        }
    }
}

enum ConfigBackupValue: Codable, Equatable {
    case string(String), bool(Bool), strings([String]), data(Data), propertyList(Data)

    func propertyListValue() throws -> Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .strings(let value): return value
        case .data(let value): return value
        case .propertyList(let data):
            guard let wrapper = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  wrapper.count == 1, let value = wrapper["value"] else { throw ConfigBackupError.invalidArchive }
            return value
        }
    }
}

struct ConfigBackupSnapshot: Codable, Equatable, Identifiable {
    static let version = 3
    var schemaVersion = Self.version
    var id = UUID()
    var createdAt = Date()
    var reason: String
    var preferences: [String: ConfigBackupValue]
    /// Only the application's explicitly supported provider accounts, never the
    /// user's whole Keychain. Nil means credentials were not requested.
    var credentials: [String: String]? = nil
    /// Every preference this app could back up when the snapshot was made.
    /// Nil in snapshots made up to 2.2.27; restoring a block from one keeps
    /// the keys added since (`ConfigBackupRegistry.keysAddedAfterUnlistedArchives`).
    /// WHY: .project-docs/decisions/2026-11-28-backup-keys-unknown-to-the-writer.md
    var knownKeys: [String]? = ConfigBackupRegistry.entries.keys.sorted()

    func hasSameContent(as other: Self) -> Bool {
        preferences == other.preferences && credentials == other.credentials
    }
}

struct ConfigBackupEnvelope: Codable {
    var format = "exodia.settings"
    var version = 1
    let keyID: String
    let sealed: Data
}

enum ConfigBackupArchive {
    static let maxBytes = 2_000_000

    static func makeKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func keyID(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    /// A random 256-bit key with a typo checksum. This is an encoding of random
    /// key material, not a password; no low-entropy password KDF is involved.
    static func recoveryCode(for key: Data) throws -> String {
        guard key.count == 32 else { throw ConfigBackupError.invalidCode }
        let hex = key.map { String(format: "%02X", $0) }.joined()
        let value = hex + keyID(key).prefix(8).uppercased()
        return stride(from: 0, to: value.count, by: 8).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return String(value[start..<value.index(start, offsetBy: 8)])
        }.joined(separator: "-")
    }

    static func key(from code: String) throws -> Data {
        guard code.utf8.count <= 512 else { throw ConfigBackupError.invalidCode }
        let normalized = code.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
        guard normalized.utf8.count == 72,
              normalized.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) })
        else { throw ConfigBackupError.invalidCode }
        let characters = Array(normalized.prefix(64))
        var key = Data()
        for offset in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(characters[offset...offset + 1]), radix: 16) else {
                throw ConfigBackupError.invalidCode
            }
            key.append(byte)
        }
        guard keyID(key).prefix(8).uppercased() == normalized.suffix(8) else { throw ConfigBackupError.invalidCode }
        return key
    }

    static func seal(_ snapshot: ConfigBackupSnapshot, key: Data) throws -> Data {
        guard key.count == 32 else { throw ConfigBackupError.keyUnavailable }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maxBytes / 2 else { throw ConfigBackupError.tooLarge }
        let id = keyID(key)
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: associatedData(id))
        guard let sealed = box.combined else { throw ConfigBackupError.invalidArchive }
        return try JSONEncoder().encode(ConfigBackupEnvelope(keyID: id, sealed: sealed))
    }

    static func open(_ data: Data, key: Data) throws -> ConfigBackupSnapshot {
        let envelope = try readEnvelope(data)
        guard key.count == 32, envelope.keyID == keyID(key) else { throw ConfigBackupError.cannotUnlock }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed),
                using: SymmetricKey(data: key), authenticating: associatedData(envelope.keyID))
        } catch { throw ConfigBackupError.cannotUnlock }
        let snapshot: ConfigBackupSnapshot
        do { snapshot = try JSONDecoder().decode(ConfigBackupSnapshot.self, from: plaintext) }
        catch { throw ConfigBackupError.invalidArchive }
        guard (1...ConfigBackupSnapshot.version).contains(snapshot.schemaVersion) else { throw ConfigBackupError.unsupportedVersion }
        return snapshot
    }

    static func readEnvelope(_ data: Data) throws -> ConfigBackupEnvelope {
        guard data.count <= maxBytes else { throw ConfigBackupError.tooLarge }
        let envelope: ConfigBackupEnvelope
        do { envelope = try JSONDecoder().decode(ConfigBackupEnvelope.self, from: data) }
        catch { throw ConfigBackupError.invalidArchive }
        guard envelope.format == "exodia.settings" else { throw ConfigBackupError.invalidArchive }
        guard envelope.version == 1 else { throw ConfigBackupError.unsupportedVersion }
        return envelope
    }

    private static func associatedData(_ id: String) -> Data { Data("exodia.settings.v1:\(id)".utf8) }
}
