import CryptoKit
import Foundation

// Settings sync keeps the same preferences and provider keys on every Mac that
// shares one backup recovery code. One encrypted document in the user's own
// private backup repository holds every synced item with the time and Mac of
// its last change; each item merges on its own, so a model chosen on one Mac
// and a hotkey changed on the other both survive.
// WHY: .project-docs/decisions/2026-11-20-settings-sync.md

/// One synced value: a preference from the backup allowlist or a provider key.
enum SettingsSyncValue: Codable, Equatable {
    case preference(ConfigBackupValue)
    case secret(String)
}

/// The latest known state of one item. `value == nil` records a removal, so a
/// key deleted on one Mac is deleted on the other instead of coming back.
struct SettingsSyncEntry: Codable, Equatable {
    var value: SettingsSyncValue?
    var modifiedAt: Date
    var device: String

    /// Later change wins; the device ID breaks an exact tie the same way on
    /// every Mac, so both converge on one value.
    func wins(over other: SettingsSyncEntry) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        return device > other.device
    }
}

struct SettingsSyncDocument: Codable, Equatable {
    static let currentSchema = 1
    var schema = Self.currentSchema
    var entries: [String: SettingsSyncEntry] = [:]
}

/// What this Mac last agreed with the shared document, per item. Values are
/// kept only as hashes: the ledger file never holds a key in plain text.
struct SettingsSyncLedger: Codable, Equatable {
    struct Record: Codable, Equatable {
        var hash: String
        var modifiedAt: Date
        var device: String
        /// The shared value this Mac is about to write. Until the write is
        /// confirmed, finding the old value means the write never landed (for
        /// example the app quit or the Keychain refused it): it is written
        /// again, never shared as this Mac's own change.
        var pending: Target?
    }
    struct Target: Codable, Equatable {
        var hash: String
        var modifiedAt: Date
        var device: String
    }
    var device: String
    var records: [String: Record] = [:]
    /// False until the first round whose result reached the shared document.
    /// A Mac that is joining takes the shared values over its own.
    var joined = false

    /// Stamps every item whose value changed since the last agreement with
    /// the time it was noticed. This runs on every sync request, also while
    /// GitHub is unreachable or backing off, and is saved, so an edit keeps
    /// the time it was made instead of the time it finally syncs. A joining
    /// Mac records no removals: an item it drops before its first shared
    /// round never existed for the others.
    /// Values a joining Mac already had are stamped at the epoch: they fill
    /// gaps in the shared document but never beat a value another Mac shared.
    /// `noticed` carries times seen while a round was busy.
    func recordingLocalChanges(current: [String: SettingsSyncValue], now: Date,
                               noticed: [String: (hash: String, at: Date)] = [:]) -> SettingsSyncLedger {
        let now = SettingsSyncClock.normalized(joined ? now : Date(timeIntervalSince1970: 0))
        var next = self
        let items = Set(current.keys).union(records.keys).filter(SettingsSyncItem.isApplicable)
        for item in items {
            let hash = SettingsSyncItem.hash(current[item])
            if let pending = records[item]?.pending {
                if hash == pending.hash {
                    next.records[item] = Record(hash: pending.hash, modifiedAt: pending.modifiedAt, device: pending.device)
                    continue
                }
                if hash == records[item]?.hash { continue } // the write never landed; it is written again
                next.records[item]?.pending = nil
            }
            guard records[item]?.hash != hash else { continue }
            if !joined && current[item] == nil { next.records[item] = nil; continue }
            if records[item] == nil && current[item] == nil { continue }
            let seen = noticed[item].flatMap { $0.hash == hash && joined ? SettingsSyncClock.normalized($0.at) : nil }
            next.records[item] = Record(hash: hash, modifiedAt: seen ?? now, device: device)
        }
        return next
    }
}

/// Item names inside the document: `pref:<defaults key>` and `key:<Keychain account>`.
enum SettingsSyncItem {
    static func preference(_ key: String) -> String { "pref:" + key }
    static func secret(_ account: String) -> String { "key:" + account }

    static func preferenceKey(_ item: String) -> String? {
        item.hasPrefix("pref:") ? String(item.dropFirst(5)) : nil
    }
    static func secretAccount(_ item: String) -> String? {
        item.hasPrefix("key:") ? String(item.dropFirst(4)) : nil
    }

    /// Preferences that belong to one Mac only. The island's display is a
    /// screen of this Mac; calendar accounts rotate their own refresh tokens
    /// per Mac, and sharing one token would sign the other Mac out; the
    /// routing repair copy is local evidence, not a choice.
    static let excludedPreferences: Set<String> = [
        "sidekey.dynamicIsland.preferredDisplayUUID",
        CalendarAccountSettings.accountsKey,
        CalendarAccountSettings.hiddenFeedsKey,
        CalendarAccountSettings.appleEnabledKey,
        ConfigBackupRegistry.aiRoutingPreservedKey,
    ]

    static func syncsPreference(_ key: String) -> Bool {
        ConfigBackupRegistry.entries[key] != nil && !excludedPreferences.contains(key)
    }

    static func syncsSecret(_ account: String) -> Bool {
        ConfigBackupRegistry.isCredentialAccount(account) && !account.hasPrefix("calendar.")
    }

    /// Only items this build understands are ever applied. Unknown items from
    /// a newer app stay in the document untouched.
    static func isApplicable(_ item: String) -> Bool {
        if let key = preferenceKey(item) { return syncsPreference(key) }
        if let account = secretAccount(item) { return syncsSecret(account) }
        return false
    }

    static func hash(_ value: SettingsSyncValue?) -> String {
        guard let value else { return "absent" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The pure decision of one sync round. No I/O: the service reads the current
/// values and the shared document, asks for a plan, then carries it out.
struct SettingsSyncPlan: Equatable {
    /// Items whose shared value differs from this Mac's: write them here.
    var apply: [String: SettingsSyncValue?]
    /// The merged document; upload it when `needsUpload`.
    var document: SettingsSyncDocument
    var needsUpload: Bool
    var ledger: SettingsSyncLedger

    static func make(current: [String: SettingsSyncValue], ledger: SettingsSyncLedger,
                     remote: SettingsSyncDocument?, now: Date) -> SettingsSyncPlan {
        let now = SettingsSyncClock.normalized(now)
        let remoteEntries = remote?.entries ?? [:]
        var local: [String: SettingsSyncEntry] = [:]
        let items = Set(current.keys).union(ledger.records.keys).filter(SettingsSyncItem.isApplicable)
        for item in items {
            let value = current[item]
            let hash = SettingsSyncItem.hash(value)
            if let record = ledger.records[item], record.hash == hash {
                local[item] = SettingsSyncEntry(value: value, modifiedAt: record.modifiedAt, device: record.device)
            } else if ledger.joined || value != nil {
                local[item] = SettingsSyncEntry(value: value, modifiedAt: now, device: ledger.device)
            }
        }

        var merged = remoteEntries
        var apply: [String: SettingsSyncValue?] = [:]
        for (item, entry) in local {
            // Joining: what this Mac had before yields to anything already shared.
            if let shared = remoteEntries[item], !ledger.joined || !entry.wins(over: shared) {
                if SettingsSyncItem.hash(shared.value) != SettingsSyncItem.hash(current[item]) {
                    apply[item] = .some(shared.value)
                }
            } else {
                merged[item] = entry
            }
        }
        for (item, shared) in remoteEntries where local[item] == nil && SettingsSyncItem.isApplicable(item) {
            if shared.value != nil, current[item] == nil { apply[item] = .some(shared.value) }
        }

        var next = ledger
        next.joined = true
        next.records = [:]
        for (item, entry) in merged where SettingsSyncItem.isApplicable(item) {
            next.records[item] = .init(hash: SettingsSyncItem.hash(entry.value), modifiedAt: entry.modifiedAt, device: entry.device)
        }
        let document = SettingsSyncDocument(schema: max(remote?.schema ?? 0, SettingsSyncDocument.currentSchema), entries: merged)
        return SettingsSyncPlan(apply: apply, document: document, needsUpload: remote == nil || merged != remoteEntries, ledger: next)
    }
}

/// The document as stored remotely: sealed with the backup key. The key ID is
/// readable so a Mac with another recovery code can say so instead of failing.
enum SettingsSyncEnvelope {
    enum Failure: Error, Equatable { case differentKey, newerFormat, damaged }

    private struct Stored: Codable {
        var format = "whytap.settings-sync"
        var version = 1
        var keyID: String
        var sealed: Data
    }

    /// GitHub's Contents API returns file contents inline only up to 1 MB.
    static let maximumBytes = 900_000

    static func seal(_ document: SettingsSyncDocument, key: Data) throws -> Data {
        let keyID = ConfigBackupArchive.keyID(key)
        let plaintext = try JSONEncoder.settingsSync.encode(document)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: associatedData(keyID))
        guard let combined = box.combined else { throw Failure.damaged }
        let data = try JSONEncoder.settingsSync.encode(Stored(keyID: keyID, sealed: combined))
        guard data.count <= maximumBytes else { throw ConfigBackupError.tooLarge }
        return data
    }

    static func open(_ data: Data, key: Data) throws -> SettingsSyncDocument {
        guard data.count <= maximumBytes,
              let stored = try? JSONDecoder.settingsSync.decode(Stored.self, from: data),
              stored.format == "whytap.settings-sync" else { throw Failure.damaged }
        guard stored.version <= 1 else { throw Failure.newerFormat }
        let keyID = ConfigBackupArchive.keyID(key)
        guard stored.keyID == keyID else { throw Failure.differentKey }
        guard let box = try? AES.GCM.SealedBox(combined: stored.sealed),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: associatedData(keyID)),
              let document = try? JSONDecoder.settingsSync.decode(SettingsSyncDocument.self, from: plaintext)
        else { throw Failure.damaged }
        guard document.schema <= SettingsSyncDocument.currentSchema else { throw Failure.newerFormat }
        return document
    }

    private static func associatedData(_ keyID: String) -> Data { Data(("whytap.settings-sync.v1:" + keyID).utf8) }
}

/// Change times are whole milliseconds, stored as integers, so a time read
/// back from the document or the ledger compares equal to the one written.
enum SettingsSyncClock {
    static func milliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        return Int64(max(-9e15, min(9e15, value)))
    }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
    static func normalized(_ date: Date) -> Date { self.date(milliseconds(date)) }
}

extension JSONEncoder {
    static var settingsSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SettingsSyncClock.milliseconds(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var settingsSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            SettingsSyncClock.date(try decoder.singleValueContainer().decode(Int64.self))
        }
        return decoder
    }
}
