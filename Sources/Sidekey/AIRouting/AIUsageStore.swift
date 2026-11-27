import Foundation
import SQLite3

enum AIUsageCurrency: String, Codable, Sendable { case usd, elevenLabsCredits }
enum AIUsageBasis: String, Codable, Sendable { case reported, estimated, unavailable }

/// Metadata only. Never retain credentials, URLs, prompts, audio or responses.
struct AIUsageContext: Equatable, Sendable {
    let feature: AIFeature
    let account: ProviderAccount
    let model: String

    init(feature: AIFeature, account: ProviderAccount, model: String) {
        self.feature = feature; self.account = account; self.model = model
    }

    init(_ route: ResolvedRoute) {
        self.init(feature: route.feature, account: route.account, model: route.model)
    }

    var currency: AIUsageCurrency { account == .elevenLabs ? .elevenLabsCredits : .usd }
}

struct AIUsageEvent: Equatable, Sendable {
    var id: String = UUID().uuidString
    var createdAt = Date()
    let context: AIUsageContext
    let currency: AIUsageCurrency
    let amount: Double?
    let basis: AIUsageBasis
    var audioSeconds: Double = 0

    static func speech(_ context: AIUsageContext, seconds: Double, id: String = UUID().uuidString,
                       at date: Date = Date()) -> Self {
        // Public Soniox equivalent hourly rates, verified 2026-11-20 (the same
        // for v5 and v6): https://soniox.com/pricing. These are estimates, not
        // account debits.
        // Do not convert ElevenLabs USD prices to credits: the plan/product
        // conversion is not supplied by the streaming API.
        let rate: Double?
        if context.account == .soniox, ["stt-rt-v5", "stt-rt-v6"].contains(context.model) {
            rate = 0.12
        } else if context.account == .soniox, ["stt-async-v5", "stt-async-v6"].contains(context.model) {
            rate = 0.10
        } else if context.account == .openAI, context.model == OpenAIRealtimeTranslateAdapter.model {
            // $0.034/min translation + $0.017/min input transcript (OpenAI
            // pricing, 2026-11-21): $3.06 per hour of audio.
            rate = (OpenAIRealtimeTranslateAdapter.usdPerMinute
                + OpenAIRealtimeTranslateAdapter.inputTranscriptionUSDPerMinute) * 60
        } else if context.account == .openAI, let perMinute = ModelRegistry.openAISpeechUSDPerMinute(context.model) {
            rate = perMinute * 60
        } else { rate = nil }
        let duration = seconds.isFinite ? max(0, seconds) : 0
        return Self(id: id, createdAt: date, context: context, currency: context.currency,
                    amount: rate.map { duration / 3600 * $0 },
                    basis: rate == nil ? .unavailable : .estimated, audioSeconds: duration)
    }
}

/// Runtime opt-in lives at the executable entry point, so unit tests and
/// offscreen fixtures never write to the user's journal through default clients.
enum AIUsageRecorder {
    private static let lock = NSLock()
    private static var enabled = false
    static func enable() { lock.withLock { enabled = true } }
    static func record(_ event: AIUsageEvent) {
        guard lock.withLock({ enabled }) else { return }
        Task {
            let priced = await ElevenLabsCreditUsage.shared.estimates(for: [event], refresh: false)
            await AIUsageStore.shared.record(priced[0])
        }
    }
    struct Prices {
        var events: [AIUsageEvent]
        var sonioxUnavailable = false
        var elevenLabsRateUnavailable = false
    }
    static func speechPrices(_ events: [AIUsageEvent]) async -> Prices {
        guard lock.withLock({ enabled }) else { return Prices(events: events) }
        var result = Prices(events: await ElevenLabsCreditUsage.shared.estimates(for: events))
        result.elevenLabsRateUnavailable = result.events.contains {
            $0.context.account == .elevenLabs && $0.amount == nil && $0.audioSeconds > 0
        }
        do {
            let reported = try await SonioxUsagePrices.shared.prices(for: result.events)
            let byID = Dictionary(uniqueKeysWithValues: reported.map { ($0.id, $0) })
            result.events = result.events.map { byID[$0.id] ?? $0 }
        } catch { result.sonioxUnavailable = true }
        return result
    }
}

enum AIUsageStoreError: Error { case unavailable, invalidEvent }

/// The actor serializes inserts and snapshots. A separate database and table
/// never change the existing meetings/history stores. Primary IDs deduplicate
/// resumed file jobs and repeated parts; each new paid retry has its
/// own ID. A failed insert remains a visible error instead of becoming zero.
actor AIUsageStore {
    static let changed = Notification.Name("AIUsageStore.changed")
    static let shared = AIUsageStore(url: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent(BuildConfig.bundleID, isDirectory: true)
        .appendingPathComponent("ai-usage.sqlite"))

    private let url: URL
    private var database: OpaquePointer?
    private var pending: [AIUsageEvent] = []
    init(url: URL) { self.url = url }
    deinit { if let database { sqlite3_close(database) } }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw AIUsageStoreError.unavailable
        }
        sqlite3_busy_timeout(handle, 2000)
        guard sqlite3_exec(handle, """
            CREATE TABLE IF NOT EXISTS usage_events (
              id TEXT PRIMARY KEY, created_at REAL NOT NULL, feature TEXT NOT NULL,
              account TEXT NOT NULL, model TEXT NOT NULL, currency TEXT NOT NULL,
              amount REAL, basis TEXT NOT NULL, audio_seconds REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS usage_date ON usage_events(created_at);
            """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); throw AIUsageStoreError.unavailable
        }
        database = handle
        return handle
    }

    /// One rule for every writer, including a restore merging this Mac's
    /// earlier rows: the same ID never duplicates, and a known price only
    /// replaces a missing one, a reported price only an estimate.
    static let upsertSQL = """
        INSERT INTO usage_events VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET amount=excluded.amount, basis=excluded.basis
        WHERE ((usage_events.amount IS NULL AND excluded.amount IS NOT NULL)
               OR (usage_events.basis='estimated' AND excluded.basis='reported'))
          AND usage_events.feature=excluded.feature AND usage_events.account=excluded.account
          AND usage_events.model=excluded.model AND usage_events.currency=excluded.currency
        """

    /// Coherent backup snapshot taken on this actor's own connection, so it
    /// is serialized with every insert and price upgrade; the live file and
    /// its rollback journal are never copied. Returns nil when no journal
    /// exists and creates none. Retry pending rows before the snapshot; a
    /// failure keeps them pending and refuses an incomplete backup.
    /// WHY: .project-docs/decisions/2026-10-21-backup-reliability.md
    func exportArtifactGeneration(into directory: URL) throws -> URL? {
        while let event = pending.first {
            try insert(event)
            pending.removeFirst()
        }
        guard database != nil || FileManager.default.fileExists(atPath: url.path) else { return nil }
        try ConfigBackupFiles.checkDirectory(url.deletingLastPathComponent())
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ArtifactBackupError.invalidContent(ArtifactUsageBackup.label)
        }
        let db = try open()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let snapshot = directory.appendingPathComponent(ArtifactUsageBackup.fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: snapshot.path) { try FileManager.default.removeItem(at: snapshot) }
        let quoted = snapshot.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "VACUUM INTO '\(quoted)'", nil, nil, nil) == SQLITE_OK else {
            try? FileManager.default.removeItem(at: snapshot)
            throw AIUsageStoreError.unavailable
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        _ = try ArtifactUsageBackup.validate(database: snapshot)
        return snapshot
    }

    func record(_ event: AIUsageEvent) async {
        do { try insert(event) }
        catch { if !pending.contains(where: { $0.id == event.id }) { pending.append(event) } }
        await MainActor.run { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// Throwing variant for imports/fixtures; no user content is accepted here.
    func insert(_ event: AIUsageEvent) throws {
        guard event.createdAt.timeIntervalSince1970.isFinite,
              event.audioSeconds.isFinite, event.audioSeconds >= 0,
              event.amount.map({ $0.isFinite && $0 >= 0 }) ?? (event.basis == .unavailable),
              (event.amount == nil) == (event.basis == .unavailable),
              event.currency == event.context.currency,
              !event.context.model.isEmpty, event.context.model.count <= 512 else {
            throw AIUsageStoreError.invalidEvent
        }
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw AIUsageStoreError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func text(_ value: String, _ index: Int32) { sqlite3_bind_text(statement, index, value, -1, transient) }
        text(event.id, 1); sqlite3_bind_double(statement, 2, event.createdAt.timeIntervalSince1970)
        text(event.context.feature.rawValue, 3); text(event.context.account.storageID, 4)
        text(event.context.model, 5); text(event.currency.rawValue, 6)
        if let amount = event.amount { sqlite3_bind_double(statement, 7, amount) }
        else { sqlite3_bind_null(statement, 7) }
        text(event.basis.rawValue, 8); sqlite3_bind_double(statement, 9, event.audioSeconds)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AIUsageStoreError.unavailable }
    }

    /// [start, end) uses local-calendar boundaries supplied by the screen.
    func events(from start: Date, to end: Date) throws -> [AIUsageEvent] {
        // Retry transient disk/locking failures before exposing a numeric total.
        // A failed retry keeps the screen in its recoverable error state.
        while let event = pending.first {
            try insert(event)
            pending.removeFirst()
        }
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM usage_events WHERE created_at >= ? AND created_at < ? ORDER BY created_at", -1, &statement, nil) == SQLITE_OK else {
            throw AIUsageStoreError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        func text(_ index: Int32) -> String { String(cString: sqlite3_column_text(statement, index)) }
        var result: [AIUsageEvent] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW,
                  let feature = AIFeature(rawValue: text(2)),
                  let account = ProviderAccount(storageID: text(3)),
                  let currency = AIUsageCurrency(rawValue: text(5)),
                  let basis = AIUsageBasis(rawValue: text(7)) else { throw AIUsageStoreError.unavailable }
            result.append(AIUsageEvent(id: text(0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                context: .init(feature: feature, account: account, model: text(4)), currency: currency,
                amount: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                basis: basis, audioSeconds: sqlite3_column_double(statement, 8)))
        }
    }
}
