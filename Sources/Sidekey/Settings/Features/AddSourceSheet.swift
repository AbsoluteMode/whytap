import AppKit
import SwiftUI

/// Add source, in the plan's order: what is already set up on this Mac, then
/// service tiles with a token, then a folder, then a custom server.
/// Adding closes the sheet; the new row shows Connecting… and then the proof.
// WHY: .project-docs/decisions/2026-11-26-agent-sources.md
@MainActor
struct AddSourceSheet: View {
    @ObservedObject var controller: SourcesController
    let close: () -> Void

    @State private var scan: SourceImportScan?
    @State private var ghAvailable = false
    @State private var ghBusy = false
    @State private var ghFailed = false
    @State private var preset: SourcePreset?
    @State private var token = ""
    @State private var fields: [String: String] = [:]
    @State private var presetProblem: String?
    @State private var customRemote = false
    @State private var customName = ""
    @State private var customCommand = ""
    @State private var customValues = ""
    @State private var customURL = ""
    @State private var customProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add a source").font(.system(size: 17, weight: .semibold)).foregroundStyle(MacSettingsTheme.text)
                Spacer()
                MacButton(title: "Cancel", action: close).keyboardShortcut(.cancelAction).fixedSize()
            }
            Text("The Agent searches it when you ask. Secrets are kept in Keychain.")
                .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    foundOnThisMac
                    services
                    folder
                    custom
                }
                .padding(.bottom, 4)
            }
            .frame(minHeight: 360, maxHeight: 560)
        }
        .padding(20)
        .frame(width: 600)
        .background(MacSettingsTheme.bgContent)
        .task {
            async let found = Task.detached(priority: .userInitiated) { MCPConfigImporter().scan() }.value
            async let gh = Task.detached(priority: .utility) { LoginShellWhich.resolve("gh") != nil }.value
            scan = await found
            ghAvailable = await gh
        }
    }

    private func add(_ draft: SourceDraft) {
        if let problem = draft.credentialProblem { customProblem = problem; presetProblem = problem; return }
        Task { await controller.add(draft) }
        close()
    }

    private var importedSummaries: Set<String> { Set(controller.sources.map(\.summary)) }

    // MARK: Found on this Mac

    private var foundOnThisMac: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Found on this Mac")
            MacCard {
                if let scan {
                    let rows = scan.candidates
                    if rows.isEmpty && !ghAvailable {
                        MacRow(title: "Nothing to import",
                               subtitle: "No MCP servers in Claude Code, Claude Desktop, Cursor, Codex or VS Code.") { EmptyView() }
                    }
                    if ghAvailable {
                        MacRow(title: "GitHub CLI sign-in",
                               subtitle: ghFailed ? "gh isn’t signed in. Run gh auth login, or paste a token below."
                                   : "Use the account gh is signed in to, read-only.") {
                            Image(systemName: "terminal").frame(width: 22).foregroundStyle(MacSettingsTheme.text2)
                        } trailing: {
                            MacButton(title: ghBusy ? "Reading…" : "Use it", style: .tinted, isEnabled: !ghBusy) {
                                ghBusy = true
                                Task {
                                    let token = await GitHubCLISignIn.token()
                                    ghBusy = false
                                    guard let token else { ghFailed = true; return }
                                    var draft = SourcePreset.github.draft(token: token, fields: [:])
                                    draft.importedFrom = "GitHub CLI"
                                    add(draft)
                                }
                            }.fixedSize()
                        }
                        if !rows.isEmpty { MacRowSeparator() }
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { MacRowSeparator() }
                        candidateRow(candidate)
                    }
                } else {
                    MacRow(title: "Looking for MCP servers…", subtitle: nil) { ProgressView().controlSize(.small) }
                }
            }
            if let problems = scan?.problems, !problems.isEmpty {
                Text(problems.joined(separator: "\n"))
                    .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.orange)
                    .padding(.horizontal, 6).padding(.top, 6)
            }
        }
    }

    private func candidateRow(_ candidate: SourceImportCandidate) -> some View {
        let done = importedSummaries.contains(candidate.draft.map { draftSummary($0) } ?? "\u{0}")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.name).font(.system(size: 13)).foregroundStyle(MacSettingsTheme.text)
                Text(candidate.app).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text3)
                Spacer()
                if let draft = candidate.draft {
                    MacButton(title: done ? "Added" : "Import", style: .tinted, isEnabled: !done) { add(draft) }
                        .fixedSize()
                        .accessibilityLabel("Import \(candidate.name) from \(candidate.app)")
                }
            }
            Text(candidate.summary)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(MacSettingsTheme.text2)
                .lineLimit(1).truncationMode(.middle)
            if let note = candidate.note {
                Text(note).font(.system(size: 11.5))
                    .foregroundStyle(candidate.draft == nil ? MacSettingsTheme.text3 : MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func draftSummary(_ draft: SourceDraft) -> String {
        SourceRecord(id: "", name: "", kind: draft.kind, transport: draft.transport).summary
    }

    // MARK: Services

    private var services: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Services")
            MacCard {
                ForEach(Array(SourcePreset.allCases.enumerated()), id: \.element) { index, item in
                    if index > 0 { MacRowSeparator() }
                    MacRow(title: item.title, subtitle: item.subtitle) {
                        Image(systemName: item == .github ? "chevron.left.forwardslash.chevron.right" : "checklist")
                            .frame(width: 22).foregroundStyle(MacSettingsTheme.text2)
                    } trailing: {
                        MacButton(title: preset == item ? "Hide" : "Connect", style: .tinted) {
                            preset = preset == item ? nil : item
                            token = ""; fields = [:]; presetProblem = nil
                        }.fixedSize()
                    }
                    if preset == item { presetForm(item) }
                }
            }
        }
    }

    private func presetForm(_ item: SourcePreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(item.fields, id: \.name) { field in
                MacField(placeholder: field.placeholder,
                         text: Binding(get: { fields[field.name] ?? "" }, set: { fields[field.name] = $0 }))
                    .accessibilityLabel(field.name == "site" ? "Jira site address" : "Account e-mail")
            }
            HStack(spacing: 8) {
                MacButton(title: "Create a token…") { NSWorkspace.shared.open(item.tokenURL) }.fixedSize()
                MacField(placeholder: "Paste the token", text: $token, isSecure: true)
                    .accessibilityLabel("\(item.title) token")
                MacButton(title: "Connect", style: .primary) {
                    if let problem = item.validate(token: token, fields: fields) { presetProblem = problem; return }
                    add(item.draft(token: token, fields: fields))
                }.fixedSize()
            }
            Text(item == .github
                 ? "The page opens with read-only access already chosen. Pick the repositories, create the token and paste it here."
                 : "Create an API token for your Atlassian account and paste it here. Jira runs through uvx; install uv first if needed (brew install uv).")
                .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let presetProblem {
                Text(presetProblem).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.red)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    // MARK: Folder

    private var folder: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Folder")
            MacCard {
                MacRow(title: "A folder on this Mac",
                       subtitle: "Searches file names and text. Hidden files, build folders and credential files are skipped.") {
                    Image(systemName: "folder").frame(width: 22).foregroundStyle(MacSettingsTheme.text2)
                } trailing: {
                    MacButton(title: "Choose folder…", style: .tinted) { chooseFolder() }.fixedSize()
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(SourceDraft(name: url.lastPathComponent, kind: .folder, transport: .folder(path: url.path)))
    }

    // MARK: Custom

    private var custom: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Custom server")
            MacCard {
                VStack(alignment: .leading, spacing: 8) {
                    MacSegmented(items: [.init(value: false, label: "Command on this Mac"), .init(value: true, label: "Remote address")], selection: $customRemote).fixedSize()
                    MacField(placeholder: "Name", text: $customName).accessibilityLabel("Server name")
                    if customRemote {
                        MacField(placeholder: "https://example.com/mcp", text: $customURL, monospaced: true)
                            .accessibilityLabel("Server address")
                        valuesEditor(placeholder: "Authorization: Bearer your-token")
                    } else {
                        MacField(placeholder: "npx -y @scope/server --flag", text: $customCommand, monospaced: true)
                            .accessibilityLabel("Command")
                        valuesEditor(placeholder: "API_TOKEN=your-token")
                    }
                    HStack {
                        if let customProblem {
                            Text(customProblem).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.red)
                        }
                        Spacer()
                        MacButton(title: "Add server", style: .primary) { addCustom() }.fixedSize()
                    }
                }
                .padding(14)
            }
            Text(customRemote ? "One header per line. Header values are kept in Keychain and sent only to this address."
                 : "One variable per line. Values are kept in Keychain and given only to this server’s process.")
                .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text3)
                .padding(.horizontal, 6).padding(.top, 7)
        }
    }

    private func valuesEditor(placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $customValues)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 56)
                .padding(4)
                .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MacSettingsTheme.switchBorder, lineWidth: 0.5))
                .accessibilityLabel(customRemote ? "Headers" : "Environment variables")
            if customValues.isEmpty {
                Text(placeholder).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MacSettingsTheme.text3).padding(.horizontal, 9).padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func addCustom() {
        customProblem = nil
        switch AddSourceSheet.customDraft(name: customName, remote: customRemote, command: customCommand,
                                          url: customURL, values: customValues) {
        case .success(let draft): add(draft)
        case .failure(let problem): customProblem = problem.message
        }
    }

    struct Problem: Error { let message: String }

    /// The custom form as a draft. Every value is a secret.
    nonisolated static func customDraft(name: String, remote: Bool, command: String, url: String, values: String) -> Result<SourceDraft, Problem> {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var draft = SourceDraft(name: trimmedName.isEmpty ? "Server" : trimmedName, kind: .custom, transport: .http(url: ""))
        let lines = values.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if remote {
            let address = url.trimmingCharacters(in: .whitespaces)
            guard let parsed = URL(string: address), parsed.host != nil else { return .failure(Problem(message: "Enter the server’s address.")) }
            _ = parsed
            draft.transport = .http(url: address)
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { return .failure(Problem(message: "Write each header as Name: value.")) }
                let header = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !header.isEmpty, !value.isEmpty else { return .failure(Problem(message: "Write each header as Name: value.")) }
                guard header.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                    return .failure(Problem(message: "Write each header as Name: value."))
                }
                guard SourceCredentialPolicy.isPlainValueAcceptable(value) else {
                    return .failure(Problem(message: "A value is too long."))
                }
                draft.headers.append(SourceValue(name: header, secret: true, value: nil))
                draft.secrets["header." + header] = value
            }
            if let problem = draft.credentialProblem { return .failure(Problem(message: problem)) }
        } else {
            let words = splitCommand(command)
            guard let executable = words.first else { return .failure(Problem(message: "Enter the command that starts the server.")) }
            let arguments = Array(words.dropFirst())
            // One credential policy for every source: secrets go in variables below, never argv.
            draft.transport = .stdio(command: executable, arguments: arguments, directory: nil)
            if let problem = draft.credentialProblem { return .failure(Problem(message: problem)) }
            for line in lines {
                guard let equals = line.firstIndex(of: "=") else { return .failure(Problem(message: "Write each variable as NAME=value.")) }
                let variable = line[..<equals].trimmingCharacters(in: .whitespaces)
                guard !variable.isEmpty, variable.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                    return .failure(Problem(message: "Write each variable as NAME=value."))
                }
                let value = String(line[line.index(after: equals)...])
                guard SourceCredentialPolicy.isPlainValueAcceptable(value) else {
                    return .failure(Problem(message: "A value is too long."))
                }
                draft.environment.append(SourceValue(name: variable, secret: true, value: nil))
                draft.secrets[variable] = value
            }
        }
        if let problem = draft.credentialProblem { return .failure(Problem(message: problem)) }
        return .success(draft)
    }

    /// Splits like a shell would for simple quoting; nothing is expanded or run.
    nonisolated static func splitCommand(_ text: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, started = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character; started = true
            } else if character == " " || character == "\t" {
                if started || !current.isEmpty { words.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }
}
