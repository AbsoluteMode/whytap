import AppKit
import SwiftUI

enum APIAndModelsSection: String, CaseIterable {
    case keys = "API keys", models = "Models", costs = "Costs", hints = "API hints"
}

/// Four sections in one API & Models surface. One model menu
/// per feature row: a provider is never picked on its own, only through the
/// model it serves.
@MainActor
struct APIAndModelsView: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    @Binding var focusedFeature: AIFeature?

    private struct KeyNotice: Identifiable {
        let id = UUID()
        let accepted: Bool
        var failureText = "Key not accepted"
    }
    @State private var keyNotice: KeyNotice?
    @State private var activeSheet: ActiveSheet?
    @State private var highlighted: Set<AIFeature> = []
    @State private var expandedGroup: String?
    @State private var section: APIAndModelsSection
    @StateObject private var usage: AIUsageCostsViewModel
    @FocusState private var focusedGroup: String?
    @FocusState private var focusedSection: APIAndModelsSection?
    /// Bumped by "Show": the scroll reader then finds the features with no model.
    @State private var showUnsetTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: APIAndModelsViewModel, focusedFeature: Binding<AIFeature?>,
         initiallyExpandedGroup: String? = nil, initialSection: APIAndModelsSection = .models,
         usageStore: AIUsageStore? = nil, usageModel: AIUsageCostsViewModel? = nil,
         initialKeyResult: Bool? = nil) {
        self.viewModel = viewModel
        self._keyNotice = State(initialValue: initialKeyResult.map { KeyNotice(accepted: $0) })
        self._focusedFeature = focusedFeature
        self._expandedGroup = State(initialValue: initiallyExpandedGroup)
        self._section = State(initialValue: initialSection)
        self._usage = StateObject(wrappedValue: usageModel ?? AIUsageCostsViewModel(store: usageStore ?? .shared))
    }

    /// Explicit model selection can still use a sheet. Key setup always opens
    /// the same minimal provider form in API keys.
    private enum ActiveSheet: Equatable {
        case otherModel(AIFeature)
    }

    private enum PresentedSheet: Identifiable {
        case otherModel(AIFeature)
        case assign(AssignProposal)

        var id: String {
            switch self {
            case .otherModel(let feature): return "otherModel.\(feature.rawValue)"
            case .assign: return "assign"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionTabs
            Rectangle().fill(MacSettingsTheme.sep).frame(height: 0.5)
            ScrollViewReader { scroller in
                Group {
                    switch section {
                    case .keys, .models:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                if section == .keys { keysBlock } else { modelsBlock }
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    case .costs:
                        AIUsageCostsView(model: usage)
                    case .hints:
                        APIHintsView(onAddKey: showKeySetup,
                                     onClose: { section = .models }, embedded: true)
                    }
                }
            .onChange(of: focusedFeature) { _, feature in
                if let feature { focus(feature, scroller: scroller) }
            }
            .onChange(of: showUnsetTick) { _, _ in
                let unset = viewModel.rows.filter(\.needsSetup).map(\.feature)
                if let first = unset.first { highlight(Set(unset), scrollTo: first, scroller: scroller) }
            }
            .task {
                if let feature = focusedFeature { focus(feature, scroller: scroller) }
                await viewModel.onAppear()
            }
            }
        }
        .background(MacSettingsTheme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5) }
        .overlay(alignment: .bottom) {
            if let keyNotice {
                ProviderKeySaveNotice(accepted: keyNotice.accepted, failureText: keyNotice.failureText).padding(.bottom, 16)
            }
        }
        .task(id: keyNotice?.id) {
            guard let keyNotice else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: keyNotice.accepted ? "Key accepted" : keyNotice.failureText,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self.keyNotice = nil
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .sheet(item: presentedSheet) { sheet in
            switch sheet {
            case .otherModel(let feature):
                OtherModelSheet(
                    feature: feature,
                    accounts: viewModel.sections(for: feature).map { ($0.account, $0.title) }
                ) { account, model in
                    activeSheet = nil
                    Task { await viewModel.select(model: model, account: account, for: feature) }
                } onCancel: { activeSheet = nil }
            case .assign(let proposal):
                AssignModelsSheet(
                    proposal: proposal,
                    onUse: { viewModel.applyProposal(selected: $0) },
                    onNotNow: { viewModel.proposal = nil }
                )
            }
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: 22) {
            ForEach(APIAndModelsSection.allCases, id: \.self) { item in
                Button { selectSection(item) } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12.5, weight: section == item ? .medium : .regular))
                        .foregroundStyle(section == item ? MacSettingsTheme.text : MacSettingsTheme.text2)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            if section == item { Rectangle().fill(MacSettingsTheme.text).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
                .focused($focusedSection, equals: item)
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(focusedSection == item ? MacSettingsTheme.accent : .clear, lineWidth: 1.5) }
                .accessibilityValue(section == item ? "Selected" : "")
                .onMoveCommand { direction in
                    let items = APIAndModelsSection.allCases
                    guard direction == .left || direction == .right,
                          let index = items.firstIndex(of: item) else { return }
                    if direction == .right { selectSection(items[(index + 1) % items.count]) }
                    if direction == .left { selectSection(items[(index + items.count - 1) % items.count]) }
                    focusedSection = section
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 18)
    }

    private func selectSection(_ next: APIAndModelsSection) {
        if next == .costs, section != .costs { usage.beginVisit() }
        section = next
    }

    private var presentedSheet: Binding<PresentedSheet?> {
        Binding(
            get: {
                if let proposal = viewModel.proposal { return .assign(proposal) }
                switch activeSheet {
                case .otherModel(let feature): return .otherModel(feature)
                case nil: return nil
                }
            },
            set: { newValue in
                guard newValue == nil else { return }
                activeSheet = nil
                viewModel.proposal = nil
            }
        )
    }

    // MARK: - API keys

    private var keysBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "API keys")
            ProviderKeyTiles(viewModel: viewModel,
                onRemoveFailure: { keyNotice = KeyNotice(accepted: false, failureText: "Couldn’t remove key") }) {
                    keyNotice = KeyNotice(accepted: $0)
                }
        }
    }

    // MARK: - Models

    private var modelsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                MacGroupTitle(title: "Models")
                if let banner = viewModel.unsetBanner {
                    unsetNote(banner)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewModel.aliasGroups.enumerated()), id: \.offset) { _, group in
                    aliasBanner(group)
                }
            }
            .padding(.bottom, viewModel.aliasGroups.isEmpty ? 0 : 10)
            VStack(spacing: 10) {
                ForEach(viewModel.groups) { group in
                    MacCard(needsSetup: group.rows.contains(where: \.needsSetup)) {
                        groupRow(group)
                    }
                    .id(group.id)
                }
            }
        }
    }

    /// A quiet count beside the title; Show lights up the rows it counts.
    private func unsetNote(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text("\(text) ·").foregroundStyle(MacSettingsTheme.text3)
            Button("Show") { showUnsetTick += 1 }
                .buttonStyle(.plain)
                .foregroundStyle(MacSettingsTheme.accent)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.bottom, 7)
        .fixedSize()
    }

    private func aliasBanner(_ group: AliasGroupAction) -> some View {
        let count = group.features.count
        return bannerButton(
            text: "Switch \(count) \(count == 1 ? "feature" : "features") to \(group.to)",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            Task { await viewModel.apply(group) }
        }
    }

    private func bannerButton(text: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MacBanner(tone: .warn, systemImage: systemImage, text: text)
        }
        .buttonStyle(.plain)
    }

    /// A stable, compact summary opens its settings in place. Transport modes
    /// stay in routing policy rather than appearing beside every model.
    // WHY: docs/DESIGN.md — Model disclosure, 2026-10-20.
    private func groupRow(_ group: FeatureGroup) -> some View {
        let paired = group.rows.count > 1
        let expanded = expandedGroup == group.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedGroup = expanded ? nil : group.id
            } label: {
                HStack(spacing: 12) {
                    Text(group.title)
                        .font(.system(size: 13))
                        .foregroundStyle(MacSettingsTheme.text)
                        .frame(width: 116, alignment: .leading)
                    HStack(spacing: 7) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.feature) { index, row in
                            if index > 0 {
                                Text("·").accessibilityHidden(true)
                            }
                            Text(row.modelSummary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedGroup, equals: group.id)
            .accessibilityLabel(group.title)
            .accessibilityValue(disclosureValue(group, expanded: expanded))
            .accessibilityHint(expanded ? "Hide model settings" : "Show model settings")
            .help(group.rows.map(\.selectionLabel).joined(separator: "\n"))
            .onKeyPress(.return) {
                expandedGroup = expanded ? nil : group.id
                return .handled
            }

            if expanded {
                MacRowSeparator()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.rows) { row in
                        pickers(for: row, paired: paired)
                    }
                    if group.title == "Drop Smart" {
                        Text("The text model keeps ready messages unchanged and edits only when corrections or structure are useful.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if group.rows.contains(where: { $0.feature == .meetingAssistantDetector }) {
                        Text("The optional detector checks new speech and calls the Meeting Assistant model only when someone may need help.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            ForEach(group.rows) { row in
                statusLines(for: row, prefix: paired ? row.fieldLabel : nil)
            }
        }
        .onKeyPress(.escape) {
            guard expanded else { return .ignored }
            expandedGroup = nil
            focusedGroup = group.id
            return .handled
        }
        .background(group.rows.contains { highlighted.contains($0.feature) }
                    ? MacSettingsTheme.accent.opacity(0.16) : Color.clear)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: highlighted)
    }

    private func disclosureValue(_ group: FeatureGroup, expanded: Bool) -> String {
        let setup = group.rows.contains(where: \.needsSetup) ? ", Needs setup" : ""
        return "\(expanded ? "Expanded" : "Collapsed"), \(group.summary)\(setup)"
    }

    private func pickers(for row: FeatureRow, paired: Bool) -> some View {
        GeometryReader { geometry in
            let providerWidth: CGFloat = 132
            let modelWidth = max(90, geometry.size.width - 52 - 20 - providerWidth)
            HStack(spacing: 10) {
                Text(paired ? row.fieldLabel : "Model")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 52, alignment: .leading)
                ModelMenu(
                    viewModel: viewModel,
                    feature: row.feature,
                    label: row.selectionLabel,
                    onAddKey: showKeySetup,
                    width: modelWidth
                )
                Group {
                    if let choice = row.provider {
                        ProviderMenu(viewModel: viewModel, feature: row.feature, choice: choice,
                                     width: providerWidth)
                    } else {
                        Color.clear.frame(width: providerWidth, height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(height: MacPopupMetrics.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.feature.title)
        .accessibilityValue(row.needsSetup ? "Needs setup" : row.status == .notSet ? "Optional, off" : "")
        .help(row.needsSetup ? "Choose a model and add its provider key in API keys."
              : row.status == .notSet ? "Optional. Choose a decision model to check new speech before the answer model." : row.selectionLabel)
    }

    /// `prefix` names the part when a function has more than one route.
    @ViewBuilder
    private func statusLines(for row: FeatureRow, prefix: String? = nil) -> some View {
        let status = statusLine(for: row)
        if status != nil || row.message != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let status {
                    HStack(spacing: 6) {
                        if row.isChecking { ProgressView().controlSize(.mini) }
                        Text(prefix.map { "\($0): \(status.text)" } ?? status.text)
                        if let action = status.action {
                            Button(action.title, action: action.run)
                                .buttonStyle(.plain)
                                .foregroundStyle(MacSettingsTheme.accent)
                        }
                    }
                }
                if let message = row.message {
                    HStack(spacing: 6) {
                        Text(prefix.map { "\($0): \(message)" } ?? message).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(row.isChecking ? MacSettingsTheme.text2 : MacSettingsTheme.orange)
            .padding(.horizontal, 14)
            .padding(.top, -3)
            .padding(.bottom, 9)
        }
    }

    private struct StatusLine {
        struct Action {
            let title: String
            let run: () -> Void
        }
        let text: String
        var action: Action?
    }

    /// The row's problem as text with its one action; `nil` when it is fine.
    private func statusLine(for row: FeatureRow) -> StatusLine? {
        if row.isChecking { return StatusLine(text: "Checking…") }
        switch row.status {
        case .ok:
            return nil
        case .notSet:
            return nil
        case .keyProblem:
            return StatusLine(text: "Key problem")
        case .notVerified:
            return StatusLine(text: "Not verified ·", action: .init(title: "Check now") {
                Task { await viewModel.checkNow(row.feature) }
            })
        case .removedByProvider:
            return StatusLine(text: "Removed by provider ·", action: .init(title: "Choose model") {
                chooseModel(for: row.feature)
            })
        case .deprecatedAlias(let target):
            let group = viewModel.aliasGroups.first { $0.features.contains(row.feature) }
            return StatusLine(
                text: "Alias of \(target)",
                action: group.map { group in
                    .init(title: "Switch to \(target)") { Task { await viewModel.apply(group) } }
                }
            )
        case .expiring(let date):
            return StatusLine(text: "Expires \(date.formatted(date: .abbreviated, time: .omitted))")
        case .notSupported(let reason):
            return StatusLine(text: "Not supported yet: \(reason) ·", action: .init(title: "Check now") {
                Task { await viewModel.checkNow(row.feature) }
            })
        }
    }

    /// The menu cannot be opened from code: the window below takes a model ID
    /// from a provider with a key; with none, it asks for a key first.
    private func chooseModel(for feature: AIFeature) {
        if viewModel.sections(for: feature).isEmpty { showKeySetup() }
        else { activeSheet = .otherModel(feature) }
    }

    private func showKeySetup() {
        activeSheet = nil
        section = .keys
    }

    // MARK: - Focus

    /// Scrolls to the row, lights it for a second and gives the binding back.
    private func focus(_ feature: AIFeature, scroller: ScrollViewProxy) {
        section = .models
        Task { @MainActor in
            await Task.yield()
            focusedFeature = nil
            highlight([feature], scrollTo: feature, scroller: scroller, seconds: 1)
        }
    }

    /// Scrolls to `target` and tints the rows of `features` for a moment.
    private func highlight(_ features: Set<AIFeature>, scrollTo target: AIFeature,
                           scroller: ScrollViewProxy, seconds: Double = 2.5) {
        guard let group = viewModel.groups.first(where: { $0.rows.contains { $0.feature == target } }) else { return }
        expandedGroup = group.id
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            scroller.scrollTo(group.id, anchor: .center)
        }
        highlighted = features
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if highlighted == features { highlighted = [] }
        }
    }
}

/// The one place a provider kind becomes a brand mark. A kind without a brand
/// asset (Anthropic, a user's server) shows an SF Symbol.
@MainActor
struct ProviderKindIcon: View {
    let kind: AIProviderKind
    var size: CGFloat = 16

    var body: some View {
        if let assetName = Self.assetName(for: kind) {
            ProviderBrandIcon(assetName: assetName, size: size)
        } else {
            ProviderBrandIcon(systemName: Self.systemName(for: kind), size: size)
        }
    }

    static func systemName(for kind: AIProviderKind) -> String {
        switch kind {
        case .anthropic: return TranscriptionProviderBrand.anthropicSystemName
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .openAICompatible: return "server.rack"
        }
    }

    static func assetName(for kind: AIProviderKind) -> String? {
        switch kind {
        case .soniox: return "soniox"
        case .deepgram: return "deepgram"
        case .elevenLabs: return "elevenlabs"
        case .openRouter: return "openrouter"
        case .openAI: return "openai"
        case .anthropic, .openAICompatible: return nil
        }
    }
}

private extension View {
    func chipBackground() -> some View {
        self
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Chips left to right, wrapping to the next line when the width runs out.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, arranged.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (origins, CGSize(width: usedWidth, height: y + lineHeight))
    }
}
