import SwiftUI

/// The one model dropdown of a feature row: models grouped by the providers
/// that have a key and can serve the feature. Picking a model is the only way
/// to pick a provider.
// WHY: .project-docs/decisions/2026-10-20-model-search.md
@MainActor
struct ModelMenu: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let feature: AIFeature
    let label: String
    let onAddKey: () -> Void
    var width: CGFloat? = nil
    @State private var isPresented = false
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            MacPopupLabel(title: label, minWidth: width ?? 90, maxWidth: width ?? 300)
        }
        .lilBroControl(label)
        .buttonStyle(APIModelFeedbackStyle(cornerRadius: MacPopupMetrics.radius, focused: focused))
        .focused($focused)
        .help(label)
        .accessibilityLabel("Model for \(feature.title)")
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPicker(
                sections: viewModel.sections(for: feature),
                missingProviderHint: viewModel.missingProviderHint(for: feature),
                onSelect: { account, model in
                    close()
                    Task { await viewModel.select(model: model, account: account, for: feature) }
                },
                onRefresh: { await viewModel.refreshModels() },
                onAddKey: { close(); onAddKey() },
                onClose: close
            )
        }
        .onChange(of: isPresented) { _, shown in
            if !shown { focused = true }
        }
    }

    private func close() {
        isPresented = false
    }
}

/// The model dropdown of a shared Speech or LLM row: the picker of the kind's
/// lead feature, whose pick goes to the caller (which may first ask about
/// custom per-feature models).
// WHY: .project-docs/decisions/2026-11-22-shared-model-rows.md
@MainActor
struct SharedModelMenu: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let kind: SharedModelKind
    let label: String
    let onAddKey: () -> Void
    let onPick: (ProviderAccount, String) -> Void
    var width: CGFloat? = nil
    @State private var isPresented = false
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            MacPopupLabel(title: label, minWidth: width ?? 90, maxWidth: width ?? 300)
        }
        .lilBroControl(label)
        .buttonStyle(APIModelFeedbackStyle(cornerRadius: MacPopupMetrics.radius, focused: focused))
        .focused($focused)
        .help(label)
        .accessibilityLabel("\(kind.title) model for every feature")
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPicker(
                sections: viewModel.sharedSections(kind),
                missingProviderHint: viewModel.missingProviderHint(for: kind.pickerFeature),
                onSelect: { account, model in
                    isPresented = false
                    onPick(account, model)
                },
                onRefresh: { await viewModel.refreshModels() },
                onAddKey: { isPresented = false; onAddKey() },
                onClose: { isPresented = false }
            )
        }
        .onChange(of: isPresented) { _, shown in
            if !shown { focused = true }
        }
    }
}

/// Query terms can appear anywhere in an ID and in any order. Keeping the
/// provider in each result prevents identical IDs on two accounts from merging.
enum ModelPickerSearch {
    struct ID: Hashable {
        let account: ProviderAccount
        let model: String
    }

    struct Result: Identifiable {
        let account: ProviderAccount
        let providerTitle: String
        let refreshFailed: Bool
        var keyProblem: String? = nil
        let option: PickerOption
        var id: ID { ID(account: account, model: option.model) }
        var isEnabled: Bool {
            if case .notSupported = option.state { return false }
            return true
        }
    }

    /// The provider bar's choice: one account's section, or every section
    /// when nothing (or an account no longer listed) is chosen.
    static func sections(_ sections: [PickerSection], showing account: ProviderAccount?) -> [PickerSection] {
        guard let account, sections.contains(where: { $0.account == account }) else { return sections }
        return sections.filter { $0.account == account }
    }

    /// Shown sections that have a problem to name but no row under which its
    /// header would appear: a refused or unreadable key, or a first catalog
    /// fetch that failed. The picker lists them with the reason instead of
    /// an anonymous "No matching models".
    static func notices(in sections: [PickerSection], results: [Result]) -> [PickerSection] {
        sections.filter { section in
            guard !section.acceptsModelName, !results.contains(where: { $0.account == section.account }) else { return false }
            return section.keyProblem != nil || (section.refreshFailed && section.options.isEmpty)
        }
    }

    static func noticeDetail(for section: PickerSection) -> String {
        section.keyProblem != nil
            ? "Its models show again once the key works. Check it in API keys."
            : "Its model list couldn't be loaded. It loads again when this list opens."
    }

    /// A section header: the provider, then why its list may be off.
    static func header(title: String, refreshFailed: Bool, keyProblem: String?) -> String {
        if let keyProblem { return "\(title) · \(keyProblem)" }
        return refreshFailed ? "\(title) · Couldn't refresh" : title
    }

    static func results(in sections: [PickerSection], query: String) -> [Result] {
        let terms = tokens(query)
        let phrase = terms.joined()
        return sections.flatMap { section in
            section.options.compactMap { option -> (result: Result, rank: Int)? in
                let modelTerms = tokens(option.model)
                let model = modelTerms.joined()
                let searchable = modelTerms + tokens(section.title)
                // Never invent a size by joining numeric version components:
                // qwen 27 must not match qwen2.7-72b.
                guard terms.allSatisfy({ term in searchable.contains { $0.contains(term) } }) else { return nil }
                let rank = phrase.isEmpty ? 2 : (model == phrase ? 0 : (model.contains(phrase) ? 1 : 2))
                return (Result(account: section.account, providerTitle: section.title,
                               refreshFailed: section.refreshFailed, keyProblem: section.keyProblem,
                               option: option), rank)
            }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.rank != rhs.element.rank { return lhs.element.rank < rhs.element.rank }
                // Search relevance wins; recency only breaks a tie within the
                // existing provider group. Unknown dates follow known dates.
                if !terms.isEmpty {
                    let left = lhs.element.result.option.catalogDate ?? .distantPast
                    let right = rhs.element.result.option.catalogDate ?? .distantPast
                    if left != right { return left > right }
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element.result)
        }
    }

    /// Split before digits: qwen27 and qwen 27 are the same query. Keep suffixes
    /// together so gpt4o still requires 4o, rather than a stray "o" in the provider.
    private static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var result: [String] = []
        var word = ""
        var wasNumber: Bool?
        for character in folded {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty { result.append(word); word = "" }
                wasNumber = nil
                continue
            }
            if wasNumber == false, character.isNumber, !word.isEmpty {
                result.append(word)
                word = ""
            }
            word.append(character)
            wasNumber = character.isNumber
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    static func moved(from current: ID?, by offset: Int, in results: [Result]) -> ID? {
        let enabled = results.filter(\.isEnabled).map(\.id)
        guard !enabled.isEmpty else { return nil }
        guard let current, let index = enabled.firstIndex(of: current) else {
            return offset < 0 ? enabled.last : enabled.first
        }
        return enabled[min(max(index + offset, 0), enabled.count - 1)]
    }
}

/// "Other model ID…": a model the provider does not list, or a provider with
/// no model list. The ID goes through the same check as any new model.
@MainActor
struct OtherModelSheet: View {
    let feature: AIFeature
    let accounts: [(account: ProviderAccount, title: String)]
    let onUse: (ProviderAccount, String) -> Void
    let onCancel: () -> Void

    @State private var modelID = ""
    @State private var selected: ProviderAccount?

    init(feature: AIFeature, accounts: [(ProviderAccount, String)],
         onUse: @escaping (ProviderAccount, String) -> Void, onCancel: @escaping () -> Void) {
        self.feature = feature
        self.accounts = accounts.map { (account: $0.0, title: $0.1) }
        self.onUse = onUse
        self.onCancel = onCancel
        _selected = State(initialValue: accounts.first?.0)
    }

    private var trimmedID: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Other model ID for \(feature.title)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
            if accounts.count > 1 {
                HStack {
                    Text("Account").font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                    Spacer()
                    MacPopup(items: accounts.map { .init(value: Optional($0.account), label: $0.title) },
                             selection: $selected, maxWidth: 260)
                        .accessibilityLabel("Account")
                }
            }
            MacField(placeholder: "Model ID", text: $modelID, monospaced: true)
            Text("It is checked when picked. If the check fails, the current model stays.")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            HStack {
                Spacer()
                MacButton(title: "Not now", style: .default, action: onCancel)
                MacButton(title: "Use", style: .primary, isEnabled: selected != nil && !trimmedID.isEmpty) {
                    if let selected { onUse(selected, trimmedID) }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
