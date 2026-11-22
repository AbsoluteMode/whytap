import Foundation

/// The server window's state and work: it checks each model row on its own
/// as the user types (or at once when the type changes), and saves the
/// whole server with one Save.
///
/// A row's status is bound to what it was checked against: its name, its
/// type, the address and a digest of the key. Any of them changing, typed
/// here or synced from another Mac, makes the row need a new check, so a
/// result never carries over to another configuration.
// WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
@MainActor
final class ServerSheetModel: ObservableObject, Identifiable {
    struct Snapshot: Equatable {
        let name: String
        let kind: ServerModel.Kind
        let target: ServerModelTarget
    }

    @Published private(set) var draft: ServerSheetDraft
    @Published private(set) var saving = false
    /// Why the last Save did not go through; cleared by the next edit.
    @Published private(set) var saveError: String?

    /// The saved server, or a fresh ID the new server's checks run under.
    let account: ProviderAccount
    nonisolated var id: String { account.storageID }
    private let viewModel: APIAndModelsViewModel
    /// Quiet time after typing before a row is checked.
    private let delay: Duration
    /// What each row's current status was checked against.
    private var verified: [UUID: Snapshot] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(viewModel: APIAndModelsViewModel, account: ProviderAccount?, delay: Duration = .milliseconds(800)) {
        self.viewModel = viewModel
        self.account = account ?? .server(UUID())
        self.delay = delay
        draft = viewModel.serverSheetDraft(for: account)
        if !draft.isNew, case .success(let connection) = currentConnection() {
            for row in draft.rows where !Self.trimmed(row.name).isEmpty {
                verified[row.id] = Snapshot(name: Self.trimmed(row.name), kind: row.kind, target: connection.target)
            }
        }
    }

    /// For renders: a window in a given state, no checks run.
    init(viewModel: APIAndModelsViewModel, previewing draft: ServerSheetDraft, suggestions: [String]) {
        self.viewModel = viewModel
        account = .server(UUID())
        delay = .seconds(3600)
        self.draft = draft
        previewSuggestions = suggestions
    }

    private var previewSuggestions: [String]?

    deinit {
        for task in tasks.values { task.cancel() }
    }

    /// Names from the server's `/v1/models` for the model fields; a server
    /// not saved yet has no list.
    var suggestions: [String] { previewSuggestions ?? viewModel.modelSuggestions(for: account) }

    // MARK: - Edits

    func setBaseURL(_ value: String) {
        guard value != draft.baseURL else { return }
        draft.baseURL = value
        connectionChanged()
    }

    func setKey(_ value: String) {
        guard value != draft.apiKey else { return }
        draft.apiKey = value
        connectionChanged()
    }

    func setName(_ value: String, of id: UUID) {
        guard let index = index(of: id), draft.rows[index].name != value else { return }
        draft.rows[index].name = value
        rowChanged(id, immediately: false)
    }

    func setKind(_ kind: ServerModel.Kind, of id: UUID) {
        guard let index = index(of: id), draft.rows[index].kind != kind else { return }
        draft.rows[index].kind = kind
        rowChanged(id, immediately: true)
    }

    /// A name chosen from the server's list: its kind is preselected from
    /// the name, and the row is checked at once.
    func choose(_ name: String, for id: UUID) {
        guard let index = index(of: id) else { return }
        draft.rows[index].name = name
        draft.rows[index].kind = ServerModelClassifier.suggestedKind(for: name)
        rowChanged(id, immediately: true)
    }

    func addRow() {
        draft.rows.append(.init())
        saveError = nil
    }

    func removeRow(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        verified[id] = nil
        draft.rows.removeAll { $0.id == id }
        saveError = nil
    }

    func cancel() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }

    func removeServer() {
        cancel()
        viewModel.remove(account)
    }

    // MARK: - Checks

    private func connectionChanged() {
        saveError = nil
        for row in draft.rows { rowChanged(row.id, immediately: false) }
    }

    /// The row's status no longer describes it: check it again after the
    /// user stops typing (or at once), unless it is empty or still matches
    /// what it was checked against.
    private func rowChanged(_ id: UUID, immediately: Bool) {
        saveError = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        guard let index = index(of: id) else { return }
        let row = draft.rows[index]
        guard !Self.trimmed(row.name).isEmpty else {
            draft.rows[index].status = .pending
            return
        }
        if let snapshot = snapshot(of: row), verified[id] == snapshot { return }
        draft.rows[index].status = .pending
        let delay = immediately ? Duration.zero : self.delay
        tasks[id] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.check(id)
        }
    }

    /// Checks one row now. The result is applied only if the row, the
    /// address and the key are still what the request was sent for.
    private func check(_ id: UUID) async {
        guard let index = index(of: id) else { return }
        let row = draft.rows[index]
        let name = Self.trimmed(row.name)
        guard !name.isEmpty else { return }
        guard case .success(let connection) = currentConnection() else {
            draft.rows[index].status = .pending
            return
        }
        let sent = Snapshot(name: name, kind: row.kind, target: connection.target)
        draft.rows[index].status = .checking
        let result = await viewModel.checkServerModel(name, kind: row.kind, on: connection)
        guard !Task.isCancelled, let now = self.index(of: id) else { return }
        guard snapshot(of: draft.rows[now]) == sent else {
            draft.rows[now].status = .pending
            return
        }
        verified[id] = sent
        switch result {
        case .passed: draft.rows[now].status = .works
        case .failed(let message), .unreachable(let message): draft.rows[now].status = .failed(message)
        }
    }

    // MARK: - Save

    /// Checks every row whose status does not describe it as it is now, then
    /// saves. A failure found by this Save stops it so the user sees why; a
    /// failure already on screen is saved as Not checked (Save anyway).
    /// `true` when the server was saved and the window can close.
    func save() async -> Bool {
        guard !saving else { return false }
        saving = true
        saveError = nil
        defer { saving = false }

        let connection: ServerSheetConnection
        switch currentConnection() {
        case .success(let value): connection = value
        case .failure(let problem):
            saveError = problem.message
            return false
        }

        // A name listed twice with one type is one model: say so on the copy.
        var seen: [Snapshot] = []
        var duplicate = false
        for index in draft.rows.indices {
            let name = Self.trimmed(draft.rows[index].name)
            guard !name.isEmpty else { continue }
            let key = Snapshot(name: name, kind: draft.rows[index].kind, target: connection.target)
            if seen.contains(key) {
                draft.rows[index].status = .failed("\(name) is already listed as \(draft.rows[index].kind.label)")
                verified[draft.rows[index].id] = nil
                duplicate = true
            } else {
                seen.append(key)
            }
        }
        if duplicate { return false }

        let shownFailures = Set(draft.rows.filter { row in
            if case .failed = row.status, let snapshot = snapshot(of: row), verified[row.id] == snapshot { return true }
            return false
        }.map(\.id))
        let stale = draft.rows.filter { row in
            guard let snapshot = snapshot(of: row) else { return false }
            return verified[row.id] != snapshot
        }.map(\.id)
        for id in stale {
            tasks[id]?.cancel()
            tasks[id] = nil
        }
        await withTaskGroup(of: Void.self) { group in
            for id in stale { group.addTask { await self.check(id) } }
        }
        let newFailures = draft.rows.contains { row in
            if case .failed = row.status { return !shownFailures.contains(row.id) }
            return false
        }
        if newFailures { return false }
        // Something changed while the checks ran (a synced key, say).
        guard case .success(let after) = currentConnection(), after.target == connection.target,
              draft.rows.allSatisfy({ row in snapshot(of: row).map { verified[row.id] == $0 } ?? true }) else {
            for row in draft.rows { rowChanged(row.id, immediately: true) }
            saveError = "The server's address or key changed during the check. Save again."
            return false
        }

        let models = draft.rows.compactMap { row -> ServerModel? in
            let name = Self.trimmed(row.name)
            guard !name.isEmpty else { return nil }
            return ServerModel(name: name, kind: row.kind, checked: row.status == .works)
        }
        if let failure = await viewModel.saveServer(draft, models: models, account: account) {
            saveError = failure
            return false
        }
        return true
    }

    // MARK: - Pieces

    private func index(of id: UUID) -> Int? { draft.rows.firstIndex { $0.id == id } }

    private func currentConnection() -> Result<ServerSheetConnection, ServerSheetProblem> {
        viewModel.serverSheetConnection(baseURL: draft.baseURL, typedKey: draft.apiKey, account: account)
    }

    private func snapshot(of row: ServerSheetDraft.Row) -> Snapshot? {
        let name = Self.trimmed(row.name)
        guard !name.isEmpty, case .success(let connection) = currentConnection() else { return nil }
        return Snapshot(name: name, kind: row.kind, target: connection.target)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
