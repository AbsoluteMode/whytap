import SwiftUI

/// Provider identities stay visible even before the first key is added. The
/// selected square opens its form directly below its row, at the full width.
@MainActor
struct ProviderKeyTiles: View {
    enum Target: Hashable {
        case provider(AIProviderKind)
        case server(ProviderAccount)
        case tavily
    }

    @ObservedObject var viewModel: APIAndModelsViewModel
    @StateObject private var tavily: TavilySettings
    let onRemoveFailure: () -> Void
    let onSaveResult: (Bool) -> Void
    /// Why a key was not saved, after `onSaveResult(false)`.
    let onSaveFailure: (String) -> Void
    /// The onboarding asked for a new server: the Custom server tile opens
    /// as if clicked, then the request clears.
    @Binding var newServerRequested: Bool
    @State private var expanded: Target?
    @State private var busy = false
    @FocusState private var focused: Target?

    init(viewModel: APIAndModelsViewModel, newServerRequested: Binding<Bool> = .constant(false),
         initiallyExpanded: Target? = nil,
         tavily: TavilySettings? = nil, onRemoveFailure: @escaping () -> Void = {},
         onSaveResult: @escaping (Bool) -> Void = { _ in },
         onSaveFailure: @escaping (String) -> Void = { _ in }) {
        self.viewModel = viewModel
        self._newServerRequested = newServerRequested
        self.onSaveResult = onSaveResult
        self.onSaveFailure = onSaveFailure
        self.onRemoveFailure = onRemoveFailure
        _tavily = StateObject(wrappedValue: tavily ?? viewModel.makeTavilySettings())
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var targets: [Target] {
        // On this Mac is not a key: it has its own card above the tiles.
        AIProviderKind.allCases
            .filter { $0 != .onDevice }
            .map(Target.provider) + [.tavily]
            + viewModel.chips.compactMap { chip in
                if case .server = chip.account { return .server(chip.account) }
                return nil
            }
    }

    var body: some View {
        let items = targets
        ProviderGrid(tileCount: items.count, expandedIndex: expanded.flatMap { items.firstIndex(of: $0) }) {
            ForEach(items, id: \.self) { target in tile(target) }
            if let expanded {
                if expanded == .tavily {
                    TavilyKeyForm(settings: tavily, onSaveResult: onSaveResult, onRemoveFailure: onRemoveFailure, onClose: close)
                } else if let kind = kind(expanded) {
                    ProviderKeyForm(viewModel: viewModel, kind: kind, account: account(expanded),
                                onBusyChanged: { busy = $0 }, onSaveResult: onSaveResult,
                                onSaveFailure: onSaveFailure, onClose: close,
                                onServerAdded: { self.expanded = .server($0) })
                    .id(expanded)
                }
            }
        }
        .onKeyPress(.escape) {
            guard expanded != nil, !busy, !tavily.saving else { return .ignored }
            close()
            return .handled
        }
        .onChange(of: newServerRequested, initial: true) { _, requested in
            guard requested else { return }
            newServerRequested = false
            if expanded != .provider(.openAICompatible) { activate(.provider(.openAICompatible)) }
        }
    }

    private func tile(_ target: Target) -> some View {
        let provider = kind(target)
        let chip = account(target).flatMap { account in viewModel.chips.first { $0.account == account } }
        let title = target == .tavily ? "Tavily" : chip?.title ?? (provider == .openAICompatible ? "Custom server" : provider?.displayName ?? "")
        let status = target == .tavily ? (tavily.configured ? "Key saved" : "Add API key") : chip?.statusText ?? "Add API key"
        let hasKey = target == .tavily ? tavily.configured : chip != nil
        let selected = expanded == target
        return Button {
            activate(target)
        } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 9) {
                        if let provider { ProviderKindIcon(kind: provider, size: 28) }
                        else if target == .tavily { ProviderKindIcon(assetName: "tavily", size: 28) }
                        else { Image(systemName: "globe").font(.system(size: 28)).frame(width: 28, height: 28).accessibilityHidden(true) }
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(provider?.keyTileDetail ?? "Web search")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(!hasKey && !selected ? MacSettingsTheme.accent : MacSettingsTheme.text2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                }
                .foregroundStyle(MacSettingsTheme.text)
                .background(selected ? MacSettingsTheme.accent.opacity(0.07) : MacSettingsTheme.fieldBg,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected || focused == target ? MacSettingsTheme.accent : MacSettingsTheme.sep,
                                      lineWidth: selected || focused == target ? 1.5 : 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(APIModelFeedbackStyle(cornerRadius: 12))
        .disabled(busy || tavily.saving)
        .focused($focused, equals: target)
        .accessibilityLabel(title)
        .accessibilityValue("\(status), \(selected ? "Expanded" : "Collapsed")")
        .accessibilityHint(selected ? "Close key settings" : "Open key settings")
    }

    /// A click on a tile; the onboarding's new server request takes the
    /// same path, so it opens whatever the Custom server tile opens.
    private func activate(_ target: Target) {
        expanded = expanded == target ? nil : target
    }

    private func kind(_ target: Target) -> AIProviderKind? {
        switch target {
        case .provider(let kind): return kind
        case .server(let account): return account.kind
        case .tavily: return nil
        }
    }

    private func account(_ target: Target) -> ProviderAccount? {
        switch target {
        case .provider(let kind): return viewModel.account(for: kind)
        case .server(let account): return account
        case .tavily: return nil
        }
    }

    private func close() {
        focused = expanded
        expanded = nil
    }
}

/// Layout computes the column count directly from the proposed width. Resizing
/// never recreates the form or loses an entered key while a request is pending.
private struct ProviderGrid: Layout {
    let tileCount: Int
    let expandedIndex: Int?
    private let spacing: CGFloat = 12

    private func metrics(width: CGFloat, subviews: Subviews) -> (columns: Int, side: CGFloat, formHeight: CGFloat) {
        let columns = width >= 700 ? 4 : (width >= 450 ? 3 : 2)
        let side = max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let height = expandedIndex != nil && subviews.count > tileCount
            ? subviews[tileCount].sizeThatFits(.init(width: width, height: nil)).height : 0
        return (columns, side, height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 516)
        let m = metrics(width: width, subviews: subviews)
        let rows = (tileCount + m.columns - 1) / m.columns
        let height = CGFloat(rows) * m.side + CGFloat(max(0, rows - 1)) * spacing
            + (expandedIndex == nil ? 0 : m.formHeight + spacing)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(width: bounds.width, subviews: subviews)
        let expandedRow = expandedIndex.map { $0 / m.columns }
        for index in 0..<min(tileCount, subviews.count) {
            let row = index / m.columns
            let extra = expandedRow.map { row > $0 ? m.formHeight + spacing : 0 } ?? 0
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index % m.columns) * (m.side + spacing),
                                              y: bounds.minY + CGFloat(row) * (m.side + spacing) + extra),
                                  anchor: .topLeading, proposal: .init(width: m.side, height: m.side))
        }
        if let expandedRow, subviews.count > tileCount {
            subviews[tileCount].place(at: CGPoint(x: bounds.minX,
                                                 y: bounds.minY + CGFloat(expandedRow + 1) * (m.side + spacing)),
                                     anchor: .topLeading, proposal: .init(width: bounds.width, height: m.formHeight))
        }
    }
}

extension AIProviderKind {
    var keyTileDetail: String {
        switch self {
        case .soniox, .deepgram, .elevenLabs, .onDevice: return "Speech recognition"
        // One OpenAI key serves its speech and its language models.
        case .openAI: return "Speech and LLMs"
        case .openRouter, .anthropic: return "Language models"
        case .openAICompatible: return "Your own endpoint"
        }
    }
}

/// A new key is checked before saving. Existing keys are never read into the
/// field, and a failed replacement leaves the saved credential untouched.
@MainActor
struct ProviderKeyForm: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let kind: AIProviderKind
    let account: ProviderAccount?
    var onBusyChanged: (Bool) -> Void = { _ in }
    var onSaveResult: (Bool) -> Void = { _ in }
    var onSaveFailure: (String) -> Void = { _ in }
    let onClose: () -> Void
    /// A new server was saved: its own form opens next and asks for a model.
    var onServerAdded: (ProviderAccount) -> Void = { _ in }
    /// The onboarding's form only adds a key; removing one stays in Settings.
    var showsRemove = true

    @State private var key = ""
    @State private var name = ""
    @State private var baseURL = ""
    /// One operation at a time: a key save or a model check. The form, its
    /// Save/Remove and the parent's tile switching follow `busy`.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    @State private var activity = ServerFormActivity()
    @FocusState private var keyFocused: Bool
    @State private var keyHovered = false

    private var chip: KeyChip? { viewModel.chips.first { $0.account == account } }
    private var newServer: Bool { kind == .openAICompatible && account == nil }
    private var busy: Bool { activity.busy }
    private var canSave: Bool {
        !busy && (newServer ? !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  : !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if newServer {
                MacField(placeholder: "Server name", text: $name)
                MacField(placeholder: "Base URL", text: $baseURL, monospaced: true)
            }
            if let account, let models = chip?.serverModels {
                ServerModelsSection(viewModel: viewModel, account: account, models: models, activity: $activity)
            }
            if chip?.serverModels != nil { Divider() }
            SecureField(chip == nil ? (newServer ? "API key (optional)" : "API key") : "New API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(keyHovered && !busy ? MacSettingsTheme.accent.opacity(0.6) : .clear, lineWidth: 1).allowsHitTesting(false) }
                .onHover { keyHovered = $0 }
                .onSubmit(save)
            HStack(spacing: 10) {
                if showsRemove {
                    APIModelAction(title: "Remove", style: .danger, isEnabled: chip != nil && account != nil && activity.canRemove) {
                        guard let account, activity.canRemove else { return }
                        viewModel.remove(account)
                        onClose()
                    }
                }
                Spacer(minLength: 0)
                if activity.savingKey { ProgressView().controlSize(.small).accessibilityLabel("Saving key") }
                APIModelAction(title: "Save", style: .primary, isEnabled: canSave, action: save)
            }
        }
        .foregroundStyle(MacSettingsTheme.text)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 12))
        .disabled(busy)
        .onChange(of: busy) { _, isBusy in onBusyChanged(isBusy) }
        .onAppear { keyFocused = true }
    }

    private func save() {
        guard canSave, activity.beginKeySave() else { return }
        let candidate = key
        Task {
            let failure: String?
            if newServer {
                failure = await viewModel.addServer(name: name, baseURL: baseURL, key: candidate, proposeModels: false)
            } else if let account {
                failure = await viewModel.replaceKey(candidate, for: account)
            } else {
                failure = await viewModel.addKey(candidate, kind: kind)
            }
            activity.finishKeySave()
            onSaveResult(failure == nil)
            if let failure { onSaveFailure(failure) }
            if failure == nil {
                key = ""
                if newServer {
                    if let added = viewModel.lastAddedServer { onServerAdded(added) } else { onClose() }
                }
            }
        }
    }
}

struct ProviderKeySaveNotice: View {
    let accepted: Bool
    var failureText = "Key not accepted"
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(accepted ? MacSettingsTheme.green : MacSettingsTheme.red)
                .accessibilityHidden(true)
            Text(accepted ? "Key accepted" : failureText)
                .foregroundStyle(MacSettingsTheme.text)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(MacSettingsTheme.bgCard, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

/// A server's models, each with its kind, and the row that adds one: a name
/// (any name; the server's `/v1/models` only suggests), LLM or Transcription
/// (preselected from the name, the user decides) and a check request before
/// it is saved. A check that does not pass can still be saved, marked Not
/// checked.
// WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
@MainActor
struct ServerModelsSection: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let account: ProviderAccount
    let models: [ServerModel]
    /// The form's one operation at a time; a check runs only when nothing else does.
    @Binding var activity: ServerFormActivity

    @State private var name = ""
    @State private var kind: ServerModel.Kind = .llm
    @State private var kindChosen = false
    /// The last check's message, for exactly `failedFor`.
    @State private var failure: String?
    @State private var failedFor: ServerModel?
    /// The refused check that "Save without check" adds from; bound to the
    /// server's address and key it ran against.
    @State private var failedCheck: ServerModelCheck?
    @State private var removedNote: String?

    init(viewModel: APIAndModelsViewModel, account: ProviderAccount, models: [ServerModel],
         activity: Binding<ServerFormActivity>,
         draft: String = "", draftKind: ServerModel.Kind? = nil, draftFailure: String? = nil) {
        self.viewModel = viewModel
        self.account = account
        self.models = models
        _activity = activity
        _name = State(initialValue: draft)
        _kind = State(initialValue: draftKind ?? ServerModelClassifier.suggestedKind(for: draft))
        _kindChosen = State(initialValue: draftKind != nil)
        _failure = State(initialValue: draftFailure)
        let failed = draftFailure == nil ? nil : ServerModel(name: draft, kind: draftKind ?? .llm, checked: false)
        _failedFor = State(initialValue: failed)
        _failedCheck = State(initialValue: failed.map {
            ServerModelCheck(name: $0.name, kind: $0.kind, target: viewModel.serverModelTarget(account),
                             result: .failed(draftFailure ?? ""))
        })
    }

    private var checking: Bool { activity.checkingModel }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var problem: String? {
        trimmed.isEmpty ? nil : viewModel.serverModelProblem(trimmed, kind: kind, on: account)
    }
    private var canAdd: Bool { !activity.busy && !trimmed.isEmpty && problem == nil }
    private var canSaveUnchecked: Bool {
        guard !activity.busy, let failedCheck else { return false }
        return failedCheck.name == trimmed && failedCheck.kind == kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models")
                .font(.system(size: 13, weight: .semibold))
            if models.isEmpty {
                Text("Add the models this server runs. Each one shows up only where its type fits.")
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                        if index > 0 { Divider() }
                        row(model)
                    }
                }
                .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                MacField(placeholder: "Model", text: $name, monospaced: true)
                    .onSubmit(add)
                    .accessibilityLabel("Model name")
                let suggestions = viewModel.modelSuggestions(for: account)
                if !suggestions.isEmpty {
                    MacMenu(title: "From server", minWidth: 110, maxWidth: 140) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                        }
                    }
                    .accessibilityLabel("Models this server lists")
                }
            }
            HStack(spacing: 10) {
                Picker("Type", selection: Binding(get: { kind }, set: { kind = $0; kindChosen = true })) {
                    ForEach(ServerModel.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .accessibilityLabel("Model type")
                Spacer(minLength: 0)
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                }
                if canSaveUnchecked {
                    APIModelAction(title: "Save without check", style: .default, isEnabled: true, action: saveUnchecked)
                }
                APIModelAction(title: "Add", style: .tinted, isEnabled: canAdd, action: add)
            }
            if let message = problem ?? (failedFor == ServerModel(name: trimmed, kind: kind, checked: false) ? failure : nil) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Problem: \(message)")
            } else if let removedNote {
                Text(removedNote)
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: name) { _, newValue in
            removedNote = nil
            if !kindChosen { kind = ServerModelClassifier.suggestedKind(for: newValue) }
        }
    }

    private func row(_ model: ServerModel) -> some View {
        HStack(spacing: 8) {
            Text(model.name)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if !model.checked {
                Text("Not checked")
                    .font(.system(size: 11))
                    .foregroundStyle(MacSettingsTheme.orange)
            }
            Text(model.kind.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text2)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(MacSettingsTheme.fieldBg, in: Capsule())
            Button {
                let cleared = viewModel.removeServerModel(model, from: account)
                removedNote = cleared.isEmpty ? nil
                    : "\(cleared.map(\.title).joined(separator: ", ")) \(cleared.count == 1 ? "has" : "have") no model now"
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(APIModelFeedbackStyle(cornerRadius: 5))
            .help("Remove \(model.name)")
            .accessibilityLabel("Remove \(model.name), \(model.kind.label)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// Checks the draft, then adds it. The draft and the whole form stay
    /// disabled while the check runs; the outcome applies only to the draft it
    /// was started for and only while the server's address and key are unchanged.
    private func add() {
        guard canAdd, activity.beginModelCheck() else { return }
        let candidate = ServerModel(name: trimmed, kind: kind, checked: false)
        failure = nil
        failedFor = nil
        failedCheck = nil
        Task {
            let check = await viewModel.runServerModelCheck(candidate.name, kind: candidate.kind, on: account)
            activity.finishModelCheck()
            guard trimmed == candidate.name, kind == candidate.kind else { return }
            failedFor = candidate
            switch check.result {
            case .passed:
                if let problem = viewModel.addServerModel(after: check, to: account) {
                    failure = problem
                } else {
                    reset()
                }
            case .failed(let message), .unreachable(let message):
                failure = message
                failedCheck = check.stale ? nil : check
            }
        }
    }

    private func saveUnchecked() {
        guard canSaveUnchecked, let check = failedCheck else { return }
        if let problem = viewModel.addServerModel(after: check, to: account) {
            failure = problem
            failedFor = ServerModel(name: check.name, kind: check.kind, checked: false)
            failedCheck = nil
        } else {
            reset()
        }
    }

    private func reset() {
        name = ""
        kindChosen = false
        kind = .llm
        failure = nil
        failedFor = nil
        failedCheck = nil
    }
}
