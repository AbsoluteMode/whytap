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
    @State private var expanded: Target?
    /// A server opens its own window instead of an inline form.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    @State private var serverSheet: ServerSheetModel?
    @State private var busy = false
    @FocusState private var focused: Target?

    init(viewModel: APIAndModelsViewModel, initiallyExpanded: Target? = nil,
         tavily: TavilySettings? = nil, onRemoveFailure: @escaping () -> Void = {},
         onSaveResult: @escaping (Bool) -> Void = { _ in },
         onSaveFailure: @escaping (String) -> Void = { _ in }) {
        self.viewModel = viewModel
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
                                onSaveFailure: onSaveFailure, onClose: close)
                    .id(expanded)
                }
            }
        }
        .onKeyPress(.escape) {
            guard expanded != nil, !busy, !tavily.saving else { return .ignored }
            close()
            return .handled
        }
        .sheet(item: $serverSheet) { model in
            ServerSheet(model: model) { serverSheet = nil }
        }
    }

    private func tile(_ target: Target) -> some View {
        let provider = kind(target)
        let chip = account(target).flatMap { account in viewModel.chips.first { $0.account == account } }
        let title = target == .tavily ? "Tavily" : chip?.title ?? (provider == .openAICompatible ? "Custom server" : provider?.displayName ?? "")
        let status = target == .tavily ? (tavily.configured ? "Key saved" : "Add API key")
            : chip?.statusText ?? (provider == .openAICompatible ? "Add server" : "Add API key")
        let hasKey = target == .tavily ? tavily.configured : chip != nil
        let selected = expanded == target
        return Button {
            if opensServerSheet(target) {
                expanded = nil
                serverSheet = ServerSheetModel(viewModel: viewModel, account: account(target))
            } else {
                expanded = selected ? nil : target
            }
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

    /// The Custom server tile adds a server; a server's tile edits it.
    private func opensServerSheet(_ target: Target) -> Bool {
        switch target {
        case .provider(let kind): return kind == .openAICompatible
        case .server: return true
        case .tavily: return false
        }
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
    /// The onboarding's form only adds a key; removing one stays in Settings.
    var showsRemove = true

    @State private var key = ""
    @State private var saving = false
    @FocusState private var keyFocused: Bool
    @State private var keyHovered = false

    private var chip: KeyChip? { viewModel.chips.first { $0.account == account } }
    private var busy: Bool { saving }
    private var canSave: Bool { !busy && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField(chip == nil ? "API key" : "New API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(keyHovered && !busy ? MacSettingsTheme.accent.opacity(0.6) : .clear, lineWidth: 1).allowsHitTesting(false) }
                .onHover { keyHovered = $0 }
                .onSubmit(save)
            HStack(spacing: 10) {
                if showsRemove {
                    APIModelAction(title: "Remove", style: .danger, isEnabled: chip != nil && account != nil && !busy) {
                        guard let account, !busy else { return }
                        viewModel.remove(account)
                        onClose()
                    }
                }
                Spacer(minLength: 0)
                if saving { ProgressView().controlSize(.small).accessibilityLabel("Saving key") }
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
        guard canSave else { return }
        saving = true
        let candidate = key
        Task {
            let failure: String?
            if let account {
                failure = await viewModel.replaceKey(candidate, for: account)
            } else {
                failure = await viewModel.addKey(candidate, kind: kind)
            }
            saving = false
            onSaveResult(failure == nil)
            if let failure { onSaveFailure(failure) }
            if failure == nil { key = "" }
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
