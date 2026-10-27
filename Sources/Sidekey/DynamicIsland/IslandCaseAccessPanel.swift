import AppKit
import SwiftUI

/// Connect opens the client picker; a client icon opens that client's policy.
/// No registration is created until the person saves the scope and mode.
struct IslandCaseAccessPanel: View {
    @ObservedObject var viewModel: CaseViewModel
    var onBack: () -> Void

    @State private var draft: CaseAccessDraft?
    @State private var availableClients: [CaseKnownClient] = []
    @State private var isLoadingClients = true
    @State private var lastError: String?
    @State private var isBusy = false
    @State private var projectQuery = ""

    init(viewModel: CaseViewModel, onBack: @escaping () -> Void,
         appID: UUID? = nil) {
        self.viewModel = viewModel
        self.onBack = onBack
        _draft = State(initialValue: appID.flatMap { id in
            viewModel.registrations.first { $0.id == id }.map(CaseAccessDraft.init)
        })
    }

    static let sharedTerminalHint = "Bypass also applies to your own commands in this terminal."
    static let inheritLabel = "Default"

    var body: some View {
        VStack(spacing: 7) {
            header
            if let lastError { messageLine(lastError) }
            ForEach(viewModel.clientSetupProblems, id: \.self) { messageLine($0) }
            if !viewModel.clientSetupProblems.isEmpty, let id = draft?.appID {
                Button("Retry agent setup") {
                    perform { _ = try await viewModel.retryClientSetup(for: id) }
                }
                .buttonStyle(CaseAccessButtonStyle())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .disabled(isBusy)
                .accessibilityIdentifier("case.connect.retry")
            }
            if draft != nil {
                policyEditor
            } else {
                clientPicker
            }
        }
        .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
        .padding(.top, IslandCaseVaultStyle.topPadding)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            guard draft == nil else { isLoadingClients = false; return }
            availableClients = await viewModel.availableClientsToRegister()
            guard !Task.isCancelled else { return }
            isLoadingClients = false
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            IslandHoverBackButton(destination: "case:\(draft?.appID?.uuidString ?? (draft == nil ? "agents" : "new"))",
                accessibilityLabel: draft?.appID == nil && draft != nil ? "Back to agents" : "Back to keys") {
                if draft?.appID == nil, draft != nil {
                    draft = nil
                    lastError = nil
                } else { onBack() }
            }
            .disabled(isBusy)
            .accessibilityIdentifier("case.access.back")
            if let draft {
                CaseAppBrandIcon(identity: draft.identity, size: 17, color: .white.opacity(0.92))
            }
            Text(draft?.name ?? "Connect")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isBusy { ProgressView().controlSize(.small) }
        }
        .foregroundStyle(.white.opacity(0.92))
        .frame(height: 26)
    }

    private var clientPicker: some View {
        IslandCaseClientPicker(clients: availableClients, isLoading: isLoadingClients,
                              hasConnectedClients: viewModel.registrations.contains {
                                  CaseKnownClient(identity: $0.identity).map { CaseKnownClient.connectableClients.contains($0) } ?? false
                              },
                              onChoose: { draft = CaseAccessDraft(identity: $0.identity, name: $0.displayName) })
    }

    private var policyEditor: some View {
        VStack(spacing: 7) {
            ScrollView {
                VStack(spacing: 8) {
                    CaseAccessSection(title: "Access mode", showsDivider: true) {
                        HStack(spacing: 5) {
                            modeButton("Accept", detail: "Ask first", mode: .approve)
                            modeButton("Bypass", detail: "No prompt", mode: .bypass)
                        }
                        if let draft, Self.showsSharedTerminalHint(app: draft.registration, known: CaseKnownClient(identity: draft.identity)) {
                            Label(Self.sharedTerminalHint, systemImage: "exclamationmark.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 1, green: 0.81, blue: 0.48))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    CaseAccessSection(title: "Projects", showsDivider: true) {
                        HStack(spacing: 5) {
                            scopeButton("All projects", all: true)
                            scopeButton("Selected projects", all: false)
                        }
                        if draft?.allProjects == false {
                            if draft?.projectIDs.isEmpty == true {
                                caption("Choose the projects this agent can use")
                            }
                            CaseAccessProjectPicker(projects: viewModel.accessProjects, query: $projectQuery,
                                                    selection: Binding(get: { draft?.projectIDs ?? [] },
                                                                       set: { draft?.projectIDs = $0 }))
                        }
                    }
                    if let draft, !draft.projectModes.isEmpty {
                        CaseAccessSection(title: "Per-project modes") {
                            ForEach(viewModel.accessProjects.filter { draft.projectModes[$0.id] != nil }) { project in
                                HStack {
                                    Text(project.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Menu {
                                        Button(Self.inheritLabel) { self.draft?.projectModes[project.id] = nil }
                                        Button("Accept") { self.draft?.projectModes[project.id] = .approve }
                                        Button("Bypass") { self.draft?.projectModes[project.id] = .bypass }
                                    } label: {
                                        Text(draft.projectModes[project.id] == .bypass ? "Bypass" : "Accept")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                }
                                .font(.system(size: 10))
                            }
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 2)
            }
            .disabled(isBusy)
            HStack(spacing: 8) {
                if let appID = draft?.appID {
                    Button("Disconnect") {
                        perform {
                            _ = try await viewModel.unregisterApp(appID)
                            onBack()
                        }
                    }
                    .buttonStyle(CaseAccessButtonStyle())
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("case.access.unregister")
                }
                Spacer(minLength: 0)
                Button(action: save) {
                    HStack(spacing: 5) {
                        Image(systemName: "touchid").accessibilityHidden(true)
                        Text(draft?.appID == nil ? "Connect" : "Save")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Color(red: 0.18, green: 0.43, blue: 0.96)))
                    .contentShape(Capsule())
                }
                .buttonStyle(CaseAccessButtonStyle(cornerRadius: 14))
                .help("Connecting, wider access and Bypass need Touch ID")
                .accessibilityHint("Connecting, wider access and Bypass need Touch ID")
                .accessibilityIdentifier("case.access.save")
            }
            .font(.system(size: 11, weight: .medium))
            .disabled(isBusy || (draft?.appID == nil && draft?.allProjects == false && draft?.projectIDs.isEmpty == true))
        }
    }

    private func modeButton(_ title: String, detail: String, mode: CaseAccessMode) -> some View {
        let selected = draft?.mode == mode
        let tint = mode == .bypass ? Color(red: 1, green: 0.81, blue: 0.48) : .white
        return Button { draft?.mode = mode } label: {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 10))
            }
            .foregroundStyle(selected ? tint : .white.opacity(0.80))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? tint.opacity(0.14) : .white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? tint.opacity(0.55) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CaseAccessButtonStyle())
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("case.access.mode.\(mode.rawValue)")
    }

    private func scopeButton(_ title: String, all: Bool) -> some View {
        let selected = draft?.allProjects == all
        return Button { draft?.allProjects = all } label: {
            Text(title)
                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(selected ? 0.17 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(CaseAccessButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(all ? "case.access.scope.all" : "case.access.scope.selected")
        .help(all ? "Access to all current and future projects" : "Choose which projects to allow")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageLine(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.6))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard let draft else { return }
        perform {
            if let id = draft.appID {
                try await viewModel.setAccess(for: id, mode: draft.mode, projects: draft.scope, projectModes: draft.projectModes)
                onBack()
            } else {
                let result = try await viewModel.registerApp(draft.identity, name: draft.name, mode: draft.mode, projects: draft.scope)
                availableClients.removeAll { $0.identity == draft.identity }
                if result.problems.isEmpty { onBack() }
                else { self.draft?.appID = result.appID }
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task { @MainActor in
            defer { isBusy = false }
            do { try await action() }
            catch { lastError = Self.message(for: error) }
        }
    }

    static func showsSharedTerminalHint(app: CaseAppRegistration, known: CaseKnownClient?) -> Bool {
        let shared = known?.hasSharedTerminal ?? { if case .executablePath = app.identity { return true }; return false }()
        return shared && (app.defaultMode == .bypass || app.projectModes.values.contains(.bypass))
    }

    static func message(for error: Error) -> String {
        switch error as? CaseViewModelError {
        case .authenticationFailed: return "Touch ID not confirmed — nothing changed"
        case .alreadyRegistered: return "This app is already connected"
        case .invalidAppName: return "This app can’t be connected"
        case .invalidMinutes: return "Use 1 to 240 minutes"
        case .locked: return "Case is locked"
        case .missingApp, .missingProject: return "Already removed"
        default: return "Couldn’t save"
        }
    }
}

/// Sections contain their own explanations; no loose footnotes between controls.
private struct CaseAccessSection<Content: View>: View {
    let title: String
    var showsDivider = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            if showsDivider {
                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                    .accessibilityHidden(true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }
}

/// Filtering changes only the visible rows, never the saved/draft project scope.
struct CaseAccessProjectPicker: View {
    let projects: [CaseProject]
    @Binding var query: String
    @Binding var selection: Set<UUID>
    @FocusState private var searchFocused: Bool
    @State private var searchHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let matches = Self.filteredProjects(projects, query: query)
        VStack(alignment: .leading, spacing: 5) {
            searchField
            if matches.isEmpty {
                Text("No matching projects")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.vertical, 5)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { project in projectChoice(project) }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text("Search projects").foregroundColor(.white.opacity(0.7)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white.opacity(0.92))
                .focused($searchFocused)
                .accessibilityLabel("Search projects")
                .accessibilityIdentifier("case.access.scope.search")
            Button {
                query = ""
                searchFocused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CaseAccessButtonStyle())
            .disabled(query.isEmpty)
            .opacity(query.isEmpty ? 0 : 1)
            .accessibilityHidden(query.isEmpty)
            .accessibilityLabel("Clear project search")
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(isEnabled && searchHovered ? 0.14 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(.white.opacity(isEnabled && searchFocused ? 0.8 : 0.4), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { searchFocused = true } }
        .onHover { searchHovered = $0 }
        .opacity(isEnabled ? 1 : 0.4)
    }

    private func projectChoice(_ project: CaseProject) -> some View {
        let selected = selection.contains(project.id)
        return Button {
            if selected { selection.remove(project.id) }
            else { selection.insert(project.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.blue : .white.opacity(0.7))
                Text(project.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaseAccessButtonStyle())
        .help(project.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("case.access.scope.project.\(project.id)")
    }

    static func filteredProjects(_ projects: [CaseProject], query: String) -> [CaseProject] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return projects }
        return projects.filter { project in
            let text = project.name + " " + project.description
            return terms.allSatisfy {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }
}

struct IslandCaseClientPicker: View {
    let clients: [CaseKnownClient]
    let isLoading: Bool
    var hasConnectedClients = false
    let onChoose: (CaseKnownClient) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for agents…").font(.system(size: 11))
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                } else if clients.isEmpty {
                    CaseAccessSection(title: hasConnectedClients ? "Agents already connected" : "No agents found") {
                        Text(hasConnectedClients
                             ? "Click an agent’s logo in Case to change its access."
                             : "Install OpenCode, Claude Code or Cursor, then open Connect again.")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(clients, id: \.self) { client in
                    CaseClientChoice(client: client) { onChoose(client) }
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 2)
        }
    }
}

private struct CaseClientChoice: View {
    let client: CaseKnownClient
    let onChoose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 10) {
                CaseAppBrandIcon(identity: client.identity, size: 22, color: .white.opacity(0.92))
                    .frame(width: 26)
                Text(client.displayName).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused && isEnabled ? .white.opacity(0.8) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CaseAccessButtonStyle())
        .focused($focused)
        .help("Choose projects and access mode for \(client.displayName)")
        .accessibilityLabel("\(client.displayName), set up key access")
        .accessibilityIdentifier("case.connect.\(client.rawValue)")
    }
}

private struct CaseAccessDraft {
    var appID: UUID?
    var identity: CaseAppIdentity
    var name: String
    var mode: CaseAccessMode = .approve
    var allProjects = true
    var projectIDs: Set<UUID> = []
    var projectModes: [UUID: CaseAccessMode] = [:]

    init(identity: CaseAppIdentity, name: String) {
        self.identity = identity
        self.name = name
    }

    init(_ app: CaseAppRegistration) {
        appID = app.id
        identity = app.identity
        name = app.displayName
        mode = app.defaultMode
        allProjects = app.allowedProjectIDs == nil
        projectIDs = app.allowedProjectIDs ?? []
        projectModes = app.projectModes
    }

    var scope: Set<UUID>? { allProjects ? nil : projectIDs }
    var registration: CaseAppRegistration {
        CaseAppRegistration(id: appID ?? UUID(), displayName: name, identity: identity, defaultMode: mode,
                            projectModes: projectModes, createdAt: .distantPast, allowedProjectIDs: scope)
    }
}

/// All custom/plain Case controls share feedback over their entire hit target.
struct CaseAccessButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                CaseAccessInteractionOverlay(hovering: hovering, pressed: configuration.isPressed,
                                             focused: isFocused, enabled: isEnabled, cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

/// Explicit states also support deterministic offscreen fixtures.
struct CaseAccessInteractionOverlay: View {
    let hovering: Bool
    let pressed: Bool
    let focused: Bool
    let enabled: Bool
    var cornerRadius: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.white.opacity(enabled ? (pressed ? 0.16 : (hovering ? 0.09 : 0)) : 0))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(enabled && focused ? .white.opacity(0.9) : .clear, lineWidth: 1))
    }
}
