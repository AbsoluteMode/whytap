import Foundation

enum ConfigBackupSection: String, Codable, CaseIterable, Identifiable {
    case models, hotkeys, vocabulary, toolbox, other, agents, credentials
    var id: String { rawValue }
    var title: String {
        switch self {
        case .models: return "API & Models · languages"
        case .hotkeys: return "Hotkeys"
        case .vocabulary: return "Vocabulary & replacements"
        case .toolbox: return "Toolbox layout"
        case .other: return "Display & features"
        case .agents: return "Agent preferences"
        case .credentials: return "Provider keys"
        }
    }
}

/// An explicit import/export allowlist. Never copy the defaults domain: it also
/// contains migrations, installation state, updater state and file bookmarks.
enum ConfigBackupRegistry {
    enum Kind { case string, bool, strings, data, propertyList, calendarAccounts }
    static let aiRoutingKey = "sidekey.aiRouting.v1"
    static let aiRoutingPreservedKey = "sidekey.aiRouting.v1.unreadable"
    struct Entry {
        let section: ConfigBackupSection
        let kind: Kind
    }

    static let entries: [String: Entry] = {
        var result: [String: Entry] = [:]
        func add(_ section: ConfigBackupSection, _ kind: Kind, _ keys: [String]) {
            for key in keys { result[key] = Entry(section: section, kind: kind) }
        }
        add(.models, .string, ["sidekey.models.transcriptionLevel", "sidekey.models.byokProvider",
            "sidekey.models.selfHostedBaseURL", "sidekey.models.selfHostedModel", "sidekey.models.llmLevel",
            "sidekey.models.openRouterModel", "sidekey.models.customLLMBaseURL", "sidekey.models.customLLMModel",
            "sidekey.preferences.transcriptionMode", "sidekey.preferences.selectedLanguage", "sidekey.preferences.targetLanguage", "com.sidekey.meetings.preferredLanguage"])
        add(.models, .string, ["openAI", "selfHosted", "deepgram", "soniox", "elevenLabs"].map { "sidekey.models.byokModel." + $0 })
        add(.models, .string, ["sidekey.translation.textTarget", "sidekey.translation.subtitleTarget", "sidekey.translation.source"])
        add(.models, .bool, ["sidekey.translation.original"])
        add(.models, .data, [aiRoutingKey])
        add(.models, .propertyList, [aiRoutingPreservedKey])
        // Keep migration completion with the map so restore preserves deliberate old-stock assignments.
        // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
        add(.hotkeys, .propertyList, [HotkeyPreferences.toolShortcutsDefaultsKey,
            HotkeyPreferences.screenshotArrowsDefaultsKey, HotkeyPreferences.screenshotArrowDefaultsVersionKey])
        add(.hotkeys, .bool, ["sidekey.preferences.brightnessKeys"])
        add(.hotkeys, .string, ["agentGestureKey", "agentTextKey", "agentVoiceKey", "agentTextShortcut",
            "agentVoiceShortcut", "agentVoiceGesture", "dropVoiceGesture", "dropVoiceTapCombo", "dropVoiceShortcut",
            "agentCloseCombo", "agentCloseShortcut", "usefulLinksInsertCombo", "usefulLinksInsertShortcut",
            "usefulLinksOpenCombo", "usefulLinksOpenShortcut", "usefulLinksNextCombo", "usefulLinksNextShortcut",
            "usefulLinksPreviousCombo", "usefulLinksPreviousShortcut", "hoverSlot1Shortcut", "hoverSlot2Shortcut",
            "hoverSlot3Shortcut", "hoverSlot4Shortcut", "hoverSlot5Shortcut", "meetingRecordShortcut"].map { "hotkeys." + $0 })
        add(.vocabulary, .strings, ["sidekey.preferences.vocabularyTerms", "sidekey.replace.terms"])
        add(.toolbox, .strings, ["sidekey.b2b.hover.layout"])
        add(.other, .bool, ["sidekey.privacy.screenshotProtectionEnabled", "sidekey.preferences.hideHelpers",
            "sidekey.preferences.hideIslandHoverWidgets", "sidekey.preferences.agentEnabled", "sidekey.preferences.meetingsEnabled",
            "sidekey.preferences.googleEnabled", "com.sidekey.meetings.enabled", "com.sidekey.volumeduck.enabled",
            "com.sidekey.nowplaying.enabled", "com.sidekey.island.idleHideEnabled", "notifications.meetingReady.enabled",
            "com.sidekey.wakeword.enabled"])
        add(.other, .strings, ["com.sidekey.wakeword.phrases"])
        add(.other, .string, ["sidekey.dynamicIsland.preferredDisplayUUID"])
        add(.other, .calendarAccounts, [CalendarAccountSettings.accountsKey])
        add(.other, .strings, [CalendarAccountSettings.hiddenFeedsKey])
        add(.other, .bool, [CalendarAccountSettings.appleEnabledKey])
        add(.other, .propertyList, ["notifications.sourceSounds"])
        add(.agents, .string, ["agent.opencode.model", "agent.claude.model", "agent.claude.effort", "agent.codex.model", "agent.codex.effort", "agent.codex.serviceTier"])
        add(.agents, .bool, ["agent.opencode.allowActions"])
        return result
    }()

    static let credentialAccounts: Set<String> = Set(
        ["openAI", "selfHosted", "deepgram", "soniox", "elevenLabs"].map { "byok." + $0 + ".api_key" }
        + ["byok.openrouter.llm_api_key", "byok.custom_llm.api_key", "byok.anthropic.api_key", "byok.openai.llm_api_key", TavilySearch.keychainAccount])

    /// No Keychain enumeration or caller-controlled account names. Only server
    /// IDs registered in the routing document add accounts to the export.
    static func credentialAccounts(in defaults: UserDefaults) throws -> Set<String> {
        var accounts = credentialAccounts
        if let stored = defaults.object(forKey: aiRoutingKey) {
            accounts.formUnion(try routingServers(capturedRouting(stored).data).map(\.keyAccount))
        }
        if let stored = defaults.object(forKey: CalendarAccountSettings.accountsKey) {
            guard let data = stored as? Data else { throw ConfigBackupError.invalidArchive }
            accounts.formUnion(try CalendarAccountSettings.decode(data).map { CalendarKeychain.account($0.id) })
        }
        return accounts
    }

    static func isCredentialAccount(_ account: String) -> Bool {
        if credentialAccounts.contains(account) { return true }
        if account.hasPrefix("calendar."), let id = UUID(uuidString: String(account.dropFirst(9))) {
            return account == CalendarKeychain.account(id)
        }
        let prefix = "byok.server.", suffix = ".api_key"
        guard account.hasPrefix(prefix), account.hasSuffix(suffix),
              let id = UUID(uuidString: String(account.dropFirst(prefix.count).dropLast(suffix.count))) else { return false }
        return account == "byok.server.\(id.uuidString.lowercased()).api_key"
    }

    /// Token rotation keeps the live Keychain current without consuming settings
    /// rollback points. The next real snapshot/archive captures the latest token.
    /// WHY: .project-docs/decisions/2026-10-19-planner.md
    static func settingsCredentialsMatch(_ first: [String: String], _ second: [String: String]) -> Bool {
        do { return try credentialsForChangeDetection(first) == credentialsForChangeDetection(second) }
        catch { return false }
    }

    /// Full archives and settings history share the same semantic comparison:
    /// rotating calendar authorization alone is not a new rollback point.
    /// The actual archive continues to carry the latest durable authorization.
    static func credentialsForChangeDetection(_ values: [String: String]) throws -> [String: String] {
        try validate([:], credentials: values)
        var result = values
        for (account, value) in values where account.hasPrefix("calendar.") {
            var credential = try JSONDecoder().decode(CalendarCredential.self, from: Data(value.utf8))
            credential.refreshToken = "rotating-authorization"
            result[account] = String(decoding: try JSONEncoder.artifactBackup.encode(credential), as: UTF8.self)
        }
        return result
    }

    private struct RoutingDocument: Decodable {
        var servers: [ServerEndpoint]?
        var migrationVersion: Int?
    }

    private static func routingServers(_ data: Data) throws -> [ServerEndpoint] {
        guard data.count <= 262_144,
              let document = try? JSONDecoder().decode(RoutingDocument.self, from: data) else { throw ConfigBackupError.invalidArchive }
        guard (document.migrationVersion ?? 1) >= 1 else { throw ConfigBackupError.invalidArchive }
        let servers = document.servers ?? []
        let legacyAccounts: Set<String> = ["byok.selfHosted.api_key", "byok.custom_llm.api_key"]
        guard servers.count <= 256, Set(servers.map(\.id)).count == servers.count,
              servers.allSatisfy({ server in
                  (server.keyAccount == "byok.server.\(server.id.uuidString.lowercased()).api_key"
                      || legacyAccounts.contains(server.keyAccount))
                      && [server.name, server.baseURL].allSatisfy { $0.utf8.count <= 8192 && !$0.contains("\0") }
              }) else { throw ConfigBackupError.invalidArchive }
        return servers
    }

    private static func preserved(_ value: Any) throws -> ConfigBackupValue {
        let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
        guard data.count <= 524_288 else { throw ConfigBackupError.tooLarge }
        return .propertyList(data)
    }

    /// Export tolerates the same broken/partially newer document as the live
    /// store. The original is retained separately; an unreadable server can
    /// never redirect credential reads or prevent meetings/Case being saved.
    private static func capturedRouting(_ stored: Any) throws -> (data: Data, repaired: Bool) {
        _ = try preserved(stored) // Proves the raw copy fits its independent bound.
        if let data = stored as? Data, (try? routingServers(data)) != nil { return (data, false) }
        var object = (stored as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var servers: [ServerEndpoint] = [], ids = Set<UUID>()
        for raw in (object["servers"] as? [Any] ?? []).prefix(256) {
            guard JSONSerialization.isValidJSONObject(raw),
                  let bytes = try? JSONSerialization.data(withJSONObject: raw),
                  let server = try? JSONDecoder().decode(ServerEndpoint.self, from: bytes),
                  !ids.contains(server.id),
                  let probe = try? JSONEncoder().encode(AIRoutingState(routes: [:], migratedRoutes: [:], servers: [server], migrationVersion: 1)),
                  (try? routingServers(probe)) != nil else { continue }
            ids.insert(server.id); servers.append(server)
        }
        object["servers"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(servers))
        object["migrationVersion"] = max(1, object["migrationVersion"] as? Int ?? 1)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        _ = try routingServers(data)
        return (data, true)
    }

    static func capture(_ defaults: UserDefaults) throws -> [String: ConfigBackupValue] {
        var warnings: [String] = []
        return try capture(defaults, warnings: &warnings)
    }

    static func capture(_ defaults: UserDefaults, warnings: inout [String]) throws -> [String: ConfigBackupValue] {
        var values: [String: ConfigBackupValue] = [:]
        for (key, entry) in entries {
            guard let value = defaults.object(forKey: key) else { continue }
            switch entry.kind {
            case .string:
                guard let value = value as? String else { throw ConfigBackupError.invalidArchive }
                values[key] = .string(value)
            case .bool:
                guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw ConfigBackupError.invalidArchive
                }
                values[key] = .bool(value.boolValue)
            case .strings:
                guard let value = value as? [String] else { throw ConfigBackupError.invalidArchive }
                values[key] = .strings(value)
            case .data:
                let captured = try capturedRouting(value)
                values[key] = .data(captured.data)
                if captured.repaired {
                    var copy: [String: Any] = ["routing": value]
                    if let previous = defaults.object(forKey: aiRoutingPreservedKey) { copy["previousCopy"] = previous }
                    values[aiRoutingPreservedKey] = try preserved(copy)
                    warnings.append("Some API & Models settings could not be read. Their original value is preserved in this backup. Keys for unreadable server entries could not be included; review those servers after recovery.")
                }
            case .calendarAccounts:
                guard let data = value as? Data else { throw ConfigBackupError.invalidArchive }
                _ = try CalendarAccountSettings.decode(data)
                values[key] = .data(data)
            case .propertyList:
                // A repaired routing document includes this existing copy too.
                if values[key] == nil { values[key] = try preserved(value) }
            }
        }
        try validate(values)
        return values
    }

    static func validate(_ values: [String: ConfigBackupValue], credentials: [String: String]? = nil) throws {
        for (key, value) in values {
            guard let entry = entries[key] else { throw ConfigBackupError.invalidArchive }
            switch (entry.kind, value) {
            case (.string, .string(let value)):
                guard value.utf8.count <= 8192, !value.contains("\0") else { throw ConfigBackupError.invalidArchive }
            case (.bool, .bool): break
            case (.data, .data(let data)): _ = try routingServers(data)
            case (.calendarAccounts, .data(let data)): _ = try CalendarAccountSettings.decode(data)
            case (.propertyList, .propertyList(let data)):
                guard data.count <= 524_288 else { throw ConfigBackupError.tooLarge }
                _ = try value.propertyListValue()
            case (.strings, .strings(let values)):
                let maximumCount = key == CalendarAccountSettings.hiddenFeedsKey ? CalendarAccountSettings.maximumHiddenFeeds : 256
                guard values.count <= maximumCount, values.allSatisfy({ $0.utf8.count <= 1024 && !$0.contains("\0") }) else {
                    throw ConfigBackupError.invalidArchive
                }
            default: throw ConfigBackupError.invalidArchive
            }
        }
        if let credentials {
            guard credentials.count <= 328, credentials.keys.allSatisfy(isCredentialAccount),
                  credentials.allSatisfy({ account, value in
                      !value.isEmpty && value.utf8.count <= (account.hasPrefix("calendar.") ? 65_536 : 16_384) && !value.contains("\0")
                  })
            else { throw ConfigBackupError.invalidArchive }
            for (account, value) in credentials where account.hasPrefix("calendar.") {
                guard let data = value.data(using: .utf8),
                      let credential = try? JSONDecoder().decode(CalendarCredential.self, from: data),
                      credential.provider != .apple, !credential.clientID.isEmpty,
                      !credential.refreshToken.isEmpty,
                      credential.expiresAt.timeIntervalSince1970.isFinite else { throw ConfigBackupError.invalidArchive }
            }
        }
    }

    static func apply(_ values: [String: ConfigBackupValue], sections: Set<ConfigBackupSection>,
                      preservingMissingKeys: Set<String> = [], to defaults: UserDefaults) throws {
        try validate(values)
        for (key, entry) in entries where sections.contains(entry.section) {
            if let value = values[key] { defaults.set(try value.propertyListValue(), forKey: key) }
            else if !preservingMissingKeys.contains(key) {
                if key == aiRoutingKey {
                    // A reset must stay Not set after launch; removing this
                    // marker would re-run migration from the frozen old tab.
                    let empty = AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 1)
                    defaults.set(try JSONEncoder().encode(empty), forKey: key)
                } else { defaults.removeObject(forKey: key) }
            }
        }
        guard defaults.synchronize() else { throw ConfigBackupError.restoreFailed }
    }
}
