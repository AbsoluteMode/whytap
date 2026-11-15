import AppKit
import SwiftUI

/// A fixed search band and result count stay visible while the catalog scrolls.
@MainActor
struct ModelPicker: View {
    let sections: [PickerSection]
    let missingProviderHint: String?
    let onSelect: (ProviderAccount, String) -> Void
    let onRefresh: () async -> Void
    let onAddKey: () -> Void
    let onClose: () -> Void

    @State private var query: String
    @State private var activeID: ModelPickerSearch.ID?
    @State private var hoveredID: ModelPickerSearch.ID?
    @State private var refreshing = false
    @FocusState private var focusedResult: ModelPickerSearch.ID?
    @State private var serverModelNames: [ProviderAccount: String] = [:]

    init(sections: [PickerSection], missingProviderHint: String?,
         initialQuery: String = "", onSelect: @escaping (ProviderAccount, String) -> Void,
         onRefresh: @escaping () async -> Void, onAddKey: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.sections = sections
        self.missingProviderHint = missingProviderHint
        self.onSelect = onSelect
        self.onRefresh = onRefresh
        self.onAddKey = onAddKey
        self.onClose = onClose
        _query = State(initialValue: initialQuery)
    }

    private var results: [ModelPickerSearch.Result] {
        ModelPickerSearch.results(in: sections, query: query)
    }

    private var unlistedServers: [PickerSection] {
        sections.filter(\.acceptsModelName)
    }

    var body: some View {
        let matches = results
        VStack(spacing: 0) {
            ModelSearchField(text: $query, resultAnnouncement: activeResultDescription,
                             onMove: move, onSubmit: chooseActive, onEscape: escape)
                .frame(height: 30)
                .padding(12)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if matches.isEmpty {
                            if unlistedServers.isEmpty || !query.isEmpty { emptyState }
                        } else {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, result in
                                if index == 0 || matches[index - 1].account != result.account {
                                    Text(result.refreshFailed
                                         ? "\(result.providerTitle) · Couldn't refresh"
                                         : result.providerTitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(MacSettingsTheme.text2)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                }
                                resultRow(result)
                                    .id(result.id)
                            }
                        }
                        ForEach(unlistedServers, id: \.account) { section in
                            serverModelField(section)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 300)
                // A filtered list needs a fresh viewport. Reusing the lazy
                // layout can leave even a nonempty result set visually blank.
                .id(query)
                .onChange(of: activeID) { _, id in
                    if let id { scroll.scrollTo(id) }
                }
                .onChange(of: query) { _, _ in
                    resetActive()
                    if let activeID { scroll.scrollTo(activeID) }
                }
                .onChange(of: sections) { _, _ in
                    resetActive()
                    if let activeID { scroll.scrollTo(activeID) }
                }
                .onAppear { resetActive() }
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(matches.count) \(matches.count == 1 ? "model" : "models")")
                    .foregroundStyle(MacSettingsTheme.text2)
                    .accessibilityLabel("\(matches.count) matching models")
                Spacer(minLength: 0)
                if refreshing {
                    ProgressView().controlSize(.mini)
                    Text("Updating models…")
                        .foregroundStyle(MacSettingsTheme.text2)
                }
            }
            .font(.system(size: 11.5))
            .padding(12)
        }
        .frame(width: 440)
        .background(MacSettingsTheme.bgCard)
        .task {
            refreshing = true
            await onRefresh()
            refreshing = false
        }
        .onKeyPress(.escape) { escape(); return .handled }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sections.isEmpty ? "Add a provider to choose a model" : "No matching models")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text)
            if sections.isEmpty {
                APIModelAction(title: missingProviderHint ?? "Add API key", style: .ghost, action: onAddKey)
            } else {
                Text("Try a name and size, like qwen 27.")
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                APIModelAction(title: "Clear search", style: .ghost) { query = "" }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A custom server may intentionally omit /models. Give that specific
    /// endpoint a named input instead of a global "Other model" command.
    private func serverModelField(_ section: PickerSection) -> some View {
        let name = Binding(get: { serverModelNames[section.account] ?? "" },
                           set: { serverModelNames[section.account] = $0 })
        let trimmed = name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Text(section.title).font(.system(size: 12, weight: .semibold))
            Text("This server doesn't provide a model list. Enter the model name configured on it.")
                .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
            HStack {
                TextField("Model name on this server", text: name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !trimmed.isEmpty { onSelect(section.account, trimmed) } }
                APIModelAction(title: "Choose", isEnabled: !trimmed.isEmpty) { onSelect(section.account, trimmed) }
            }
        }
        .padding(12)
    }

    private func resultRow(_ result: ModelPickerSearch.Result) -> some View {
        Button { choose(result) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .opacity(result.option.isSelected ? 1 : 0)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.option.model)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = result.option.dateLabel {
                        Text(date)
                            .font(.system(size: 11))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let hint = result.option.hint {
                        Text(hint).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                    }
                    if case .notSupported(let reason) = result.option.state {
                        Text(reason).font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
            .foregroundStyle(MacSettingsTheme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(activeID == result.id ? MacSettingsTheme.accent.opacity(0.15)
                        : (result.isEnabled && hoveredID == result.id ? MacSettingsTheme.hover : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(APIModelFeedbackStyle(focused: focusedResult == result.id))
        .disabled(!result.isEnabled)
        .focused($focusedResult, equals: result.id)
        .help(result.option.model)
        .onHover { hovering in hoveredID = hovering && result.isEnabled ? result.id : nil }
        .accessibilityValue(result.option.isSelected ? "Current model" : "")
        .onKeyPress(.return) { choose(result); return .handled }
    }

    private func resetActive() {
        activeID = results.first(where: { $0.isEnabled && $0.option.isSelected })?.id
            ?? results.first(where: \.isEnabled)?.id
    }

    private var activeResultDescription: String? {
        let matches = results
        guard let index = matches.firstIndex(where: { $0.id == activeID }) else { return nil }
        let result = matches[index]
        let date = result.option.dateLabel.map { ", \($0)" } ?? ""
        return "\(result.providerTitle), \(result.option.model)\(date), \(index + 1) of \(matches.count)"
    }

    private func move(_ offset: Int) {
        activeID = ModelPickerSearch.moved(from: activeID, by: offset, in: results)
    }

    private func chooseActive() {
        guard let result = results.first(where: { $0.id == activeID }) else { return }
        choose(result)
    }

    private func choose(_ result: ModelPickerSearch.Result) {
        guard result.isEnabled else { return }
        onSelect(result.account, result.option.model)
    }

    private func escape() {
        if query.isEmpty { onClose() } else { query = "" }
    }
}

/// Native field editing, clear button and IME composition; only result-navigation
/// commands are intercepted, locally in the field's delegate.
struct ModelSearchField: NSViewRepresentable {
    @Binding var text: String
    var resultAnnouncement: String? = nil
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusedSearchField()
        field.placeholderString = "Search models — e.g. qwen 27"
        field.setAccessibilityLabel("Search models")
        field.setAccessibilityHelp("Use Up and Down to choose a result, Return to select, Escape to clear or close.")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if resultAnnouncement != context.coordinator.lastAnnouncement {
            context.coordinator.lastAnnouncement = resultAnnouncement
            if let resultAnnouncement, field.window != nil {
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                     userInfo: [.announcement: resultAnnouncement,
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ModelSearchField
        var lastAnnouncement: String?
        init(parent: ModelSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            default: return false
            }
            return true
        }
    }

    private final class FocusedSearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }
}
