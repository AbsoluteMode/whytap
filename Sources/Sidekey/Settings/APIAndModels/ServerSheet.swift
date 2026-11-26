import SwiftUI

/// Everything about one of the user's servers in one window: its address,
/// optional key and the models it runs, each with its type and the result
/// of its check. One Save keeps it all. The server has no name field: it is
/// called by its address (`ServerEndpoint.displayName(for:)`).
// WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
struct ServerSheetDraft: Equatable {
    struct Row: Identifiable, Equatable {
        enum Status: Equatable {
            /// Not checked yet: new, or its name or type just changed.
            case pending
            case checking
            case works
            case failed(String)
            /// Saved earlier without a passing check.
            case notChecked
        }

        let id: UUID
        var name: String
        var kind: ServerModel.Kind
        var status: Status

        init(id: UUID = UUID(), name: String = "", kind: ServerModel.Kind = .llm, status: Status = .pending) {
            self.id = id
            self.name = name
            self.kind = kind
            self.status = status
        }
    }

    var isNew: Bool
    var baseURL: String
    /// Typed into the key field; empty keeps the stored key (if any).
    var apiKey: String
    var hasStoredKey: Bool
    var rows: [Row]
}

@MainActor
struct ServerSheet: View {
    @ObservedObject var model: ServerSheetModel
    /// The window closes: after Save, Cancel or Remove server.
    var onClose: () -> Void = {}

    private var draft: ServerSheetDraft { model.draft }
    private var saving: Bool { model.saving }

    private static let labelWidth: CGFloat = 88
    private static let typeWidth: CGFloat = 176
    private static let statusWidth: CGFloat = 104

    private var checking: Int { draft.rows.filter { $0.status == .checking }.count }
    private var failed: [ServerSheetDraft.Row] {
        draft.rows.filter { if case .failed = $0.status { return true } else { return false } }
    }
    private var namedRows: [ServerSheetDraft.Row] {
        draft.rows.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var canSave: Bool {
        !saving && checking == 0
            && !draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The address, key and model rows scroll past this height, so a long
    /// model list never pushes Save below the screen.
    // WHY: .project-docs/decisions/2026-11-22-server-window.md
    static let maxScrollHeight: CGFloat = 460
    /// The least the rows get when the window is short: the Base URL row.
    static let minScrollHeight: CGFloat = 64
    @State private var contentHeight: CGFloat = 0
    private var scrollHeight: CGFloat { min(max(contentHeight, 1), Self.maxScrollHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    connection
                    models
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ServerSheetContentHeight.self, value: proxy.size.height)
                })
            }
            .scrollBounceBehavior(.basedOnSize)
            // Up to its content or the cap, and smaller when the window has
            // less room: the header and footer keep their height, the rows scroll.
            .frame(minHeight: min(max(contentHeight, 1), Self.minScrollHeight),
                   idealHeight: scrollHeight, maxHeight: scrollHeight)
            .layoutPriority(-1)
            .onPreferenceChange(ServerSheetContentHeight.self) { contentHeight = $0 }
            .disabled(saving)
            footer
        }
        .padding(22)
        .frame(width: 600, alignment: .topLeading)
        .background(MacSettingsTheme.bgContent)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(draft.isNew ? "Add your server" : (ServerEndpoint.displayName(for: draft.baseURL) ?? "Your server"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
                .lineLimit(1)
            Text("An OpenAI-compatible server: Ollama, vLLM, LM Studio or your company's gateway.")
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)
        }
    }

    // MARK: - Connection

    private var connection: some View {
        group {
            labeled("Base URL") {
                MacField(placeholder: "http://localhost:11434/v1",
                         text: Binding(get: { model.draft.baseURL }, set: { model.setBaseURL($0) }), monospaced: true)
            }
            divider
            labeled("API key") {
                VStack(alignment: .leading, spacing: 4) {
                    MacField(placeholder: draft.hasStoredKey && !model.keyWithheld ? "Saved · type to replace" : "Optional",
                             text: Binding(get: { model.draft.apiKey }, set: { model.setKey($0) }), isSecure: true)
                    if let note = keyNote {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Why the key field is empty although a key was saved or typed.
    private var keyNote: String? {
        if model.typedKeyCleared { return "The key was typed for another address. Type it again to use it here." }
        if model.keyWithheld { return "The saved key stays with the old address. Type it again to use it here." }
        return nil
    }

    // MARK: - Models

    private var models: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text2)
                .padding(.leading, 14)
            group {
                ForEach(Array(draft.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { divider }
                    modelRow(index)
                }
                divider
                // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                Button {
                    model.addRow()
                } label: {
                    Label("Add model", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(APIModelFeedbackStyle(cornerRadius: 0))
            }
            Text("Each model shows up only where its type fits: an LLM in text features, Transcription in dictation and meetings. Whytap checks it once with a short request.")
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
        }
    }

    private func modelRow(_ index: Int) -> some View {
        let row = draft.rows[index]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                nameField(index)
                // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                Picker("Type", selection: Binding(get: { row.kind }, set: { model.setKind($0, of: row.id) })) {
                    ForEach(ServerModel.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: Self.typeWidth)
                .accessibilityLabel("Type of \(row.name)")
                status(row.status)
                    .frame(width: Self.statusWidth, alignment: .leading)
                // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                Button {
                    model.removeRow(row.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(APIModelFeedbackStyle(cornerRadius: 5))
                .help("Remove \(row.name)")
                .accessibilityLabel("Remove \(row.name)")
            }
            if case .failed(let message) = row.status {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Check failed: \(message)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func nameField(_ index: Int) -> some View {
        let id = draft.rows[index].id
        let suggestions = model.suggestions
        return HStack(spacing: 4) {
            // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
            TextField("Model name", text: Binding(get: { model.draft.rows.first { $0.id == id }?.name ?? "" },
                                                   set: { model.setName($0, of: id) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MacSettingsTheme.text)
                .padding(.leading, 10)
                .padding(.vertical, 6)
            if !suggestions.isEmpty {
                // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                Menu {
                    Section("On this server") {
                        ForEach(suggestions, id: \.self) { name in
                            // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                            Button(name) { model.choose(name, for: id) }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Models this server lists")
                .accessibilityLabel("Models this server lists")
            }
        }
        .padding(.trailing, 4)
        .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(MacSettingsTheme.switchBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private func status(_ status: ServerSheetDraft.Row.Status) -> some View {
        switch status {
        case .pending:
            // Keeps the column so rows line up before their first check.
            Color.clear.frame(height: 1)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(MacSettingsTheme.text2)
            }
            .font(.system(size: 12))
        case .works:
            Label("Works", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MacSettingsTheme.green)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MacSettingsTheme.red)
        case .notChecked:
            Label("Not checked", systemImage: "exclamationmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MacSettingsTheme.orange)
        }
    }

    // MARK: - Footer

    private var summary: String? {
        if let error = model.saveError { return error }
        if checking > 0 { return checking == 1 ? "Checking 1 model…" : "Checking \(checking) models…" }
        if failed.count == 1, let name = failed.first?.name {
            return "\(name) didn't pass. Save anyway keeps it, marked Not checked."
        }
        if failed.count > 1 { return "\(failed.count) models didn't pass. Save anyway keeps them, marked Not checked." }
        if !draft.isNew, namedRows.isEmpty { return "Without a model the server isn't offered anywhere." }
        return nil
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if !draft.isNew {
                APIModelAction(title: "Remove server", style: .danger, isEnabled: !saving) {
                    model.removeServer()
                    onClose()
                }
            }
            if let summary {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(model.saveError != nil || (checking == 0 && !failed.isEmpty)
                                     ? MacSettingsTheme.red : MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if saving { ProgressView().controlSize(.small) }
            APIModelAction(title: "Cancel", style: .default, isEnabled: !saving) {
                model.cancel()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            APIModelAction(title: failed.isEmpty ? "Save" : "Save anyway", style: .primary, isEnabled: canSave) {
                Task { if await model.save() { onClose() } }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Pieces

    private var divider: some View {
        Rectangle().fill(MacSettingsTheme.rowSeparator).frame(height: 1).padding(.horizontal, 14)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(MacSettingsTheme.bgCard, in: RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard))
            .overlay(RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard)
                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5))
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(MacSettingsTheme.text)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ServerSheetContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
