import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum IslandCaseVaultStyle {
    // WHY: docs/decisions/2026-10-19-case-secrets-broker.md
    static let panelHeight: CGFloat = 320
    static let horizontalPadding: CGFloat = 10
    static let topPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 5
    static let inputHeight: CGFloat = 32
    static let rowHeight: CGFloat = 30
    static let childRowHeight: CGFloat = 28
    static let iconButtonSize: CGFloat = 22
    static let inputFontSize: CGFloat = 12
    static let nameFontSize: CGFloat = 11
    static let errorFontSize: CGFloat = 9
    static let descriptionFontSize: CGFloat = 9
    static let rowCornerRadius: CGFloat = 9
    static let childIndent: CGFloat = 12
}

struct IslandCaseVaultPanel: View {
    @ObservedObject var viewModel: CaseViewModel

    /// Connected app icons open access settings in place.
    static let isAccessScreenAvailable = true

    /// While searching every matching project is shown expanded.
    static func isExpanded(_ section: CaseProjectSection, expandedIDs: Set<UUID>, isSearching: Bool) -> Bool {
        isSearching || expandedIDs.contains(section.id)
    }

    var onDismiss: () -> Void = {}
    var onOpenAccessScreen: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    @State private var valueDraft = ""
    @State private var nameDraft = ""
    @State private var editSecretID: UUID?
    @State private var editName = ""
    @State private var editValue = ""
    @State private var editDescription = ""
    @State private var addingProjectID: UUID?
    @State private var projectEditor: ProjectEditor?
    @State private var projectNameDraft = ""
    @State private var projectDescriptionDraft = ""
    @State private var pendingDeleteProjectID: UUID?
    @State private var dragState = CaseDragState()
    @State private var lastError: String?
    @State private var showingAccess = false
    @State private var accessAppID: UUID?
    private enum InputFocus: Hashable { case search, newKey }
    @FocusState private var inputFocused: InputFocus?

    private let topScrollID = "case-list-top"
    private let bottomScrollID = "case-list-bottom"
    @State private var isUnlocking = false
    @State private var hasTriggeredInitialUnlock = false

    var body: some View {
        Group {
            if viewModel.isUnlocked {
                if showingAccess {
                    IslandCaseAccessPanel(viewModel: viewModel, onBack: {
                        viewModel.dismissClientSetupProblems()
                        showingAccess = false
                    }, appID: accessAppID)
                } else {
                    unlockedPanel
                }
            } else {
                lockedPanel
            }
        }
        .onExitCommand {
            if !viewModel.isSystemInteractionActive { onDismiss() }
        }
        .onAppear {
            DispatchQueue.main.async {
                inputFocused = .search
            }
            // Clear any stale armed-reset state from a previous panel open so
            // the user always starts the two-step confirm fresh.
            viewModel.disarmResetVault()
            unlockIfNeededOnOpen()
        }
    }

    private var lockedPanel: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 6)

            if case let .needsReset(message) = viewModel.unlockState {
                Button(action: resetCase) {
                    unlockPill(title: viewModel.isResetArmed ? "Confirm reset" : "Reset Case")
                }
                .buttonStyle(CaseAccessButtonStyle(cornerRadius: 15))
                .disabled(isUnlocking)

                // Armed: describe the new vault and the encrypted file retained by reset().
                Text(viewModel.isResetArmed
                    ? "Create a new Case? The old encrypted file is kept. Click again to confirm."
                    : message)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(IslandInk.color.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
            } else if case let .needsNewerApp(message) = viewModel.unlockState {
                unlockPill(title: "Update required")

                Text(message)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(IslandInk.color.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
            } else {
                if isUnlocking || !hasTriggeredInitialUnlock {
                    unlockPill(title: "Opening…")
                } else {
                    Button(action: unlock) {
                        unlockPill(title: "Try again")
                    }
                    .buttonStyle(CaseAccessButtonStyle(cornerRadius: 15))
                    .disabled(isUnlocking)
                }

                Text("Touch ID or your Mac password")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(IslandInk.color.opacity(0.46))

                if case let .failed(message) = viewModel.unlockState {
                    Text(message)
                        .font(.system(size: IslandCaseVaultStyle.errorFontSize, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 14)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlockPill(title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.open")
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(IslandInk.color.opacity(0.94))
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(Capsule().fill(IslandInk.color.opacity(0.14)))
        .overlay(Capsule().stroke(IslandInk.color.opacity(0.20), lineWidth: 0.8))
    }

    private var unlockedPanel: some View {
        VStack(spacing: IslandCaseVaultStyle.rowSpacing) {
            inputBar
                .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
                .padding(.top, IslandCaseVaultStyle.topPadding)

            if addingProjectID != nil {
                keyCreationBar
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
            }

            if projectEditor == .create {
                projectEditorControls(isGeneral: false)
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
            }

            if let lastError {
                Text(lastError)
                    .font(.system(size: IslandCaseVaultStyle.errorFontSize, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding + 2)
            }

            caseList
                .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)

            if Self.isAccessScreenAvailable {
                accessRow
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
            }
        }
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if viewModel.query.isEmpty {
                    Text("Search keys and projects")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(IslandInk.color.opacity(0.70))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }

                TextField("", text: $viewModel.query)
                    .accessibilityLabel("Search keys and projects")
                    .accessibilityIdentifier("case.search")
                    .font(.system(size: IslandCaseVaultStyle.inputFontSize, weight: .medium))
                    .textFieldStyle(.plain)
                    .foregroundStyle(IslandInk.color.opacity(0.92))
                    .padding(.horizontal, 10)
                    .focused($inputFocused, equals: .search)
            }
            .frame(height: IslandCaseVaultStyle.inputHeight)
            .background(Capsule().fill(IslandInk.color.opacity(0.13)))
            .modifier(CaseVaultFieldFeedback(focused: inputFocused == .search, border: inputBorderColor))
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { inputFocused = .search } }

            Button(action: startCreatingProject) {
                Text("+ Project")
                    .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold))
                    .foregroundStyle(IslandInk.color.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: IslandCaseVaultStyle.inputHeight)
                    .background(Capsule().fill(IslandInk.color.opacity(0.10)))
                    .overlay(Capsule().stroke(IslandInk.color.opacity(0.14), lineWidth: 0.7))
            }
            .buttonStyle(CaseAccessButtonStyle(cornerRadius: IslandCaseVaultStyle.inputHeight / 2))
            .accessibilityIdentifier("case.project.create")
        }
    }

    private var keyCreationBar: some View {
        HStack(spacing: 6) {
            Group {
                switch viewModel.inputMode {
                case .name:
                    TextField("New key name", text: $nameDraft)
                        .accessibilityLabel("New key name")
                case .value:
                    SecureField("Key value", text: $valueDraft)
                        .accessibilityLabel("Key value")
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: IslandCaseVaultStyle.inputFontSize, weight: .medium))
            .foregroundStyle(IslandInk.color.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: IslandCaseVaultStyle.inputHeight)
            .background(Capsule().fill(IslandInk.color.opacity(0.10)))
            .modifier(CaseVaultFieldFeedback(focused: inputFocused == .newKey, border: inputBorderColor))
            .focused($inputFocused, equals: .newKey)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { inputFocused = .newKey } }
            .onSubmit(submitInput)
            Button(action: submitInput) {
                Image(systemName: "arrow.right.circle")
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(CaseAccessButtonStyle(cornerRadius: 7))
            .foregroundStyle(IslandInk.color.opacity(0.92))
            .accessibilityLabel(viewModel.inputMode == .name ? "Next: key value" : "Add key")
            IslandCaseIconButton(action: Self.cancelInputAction) {
                valueDraft = ""
                nameDraft = ""
                addingProjectID = nil
                viewModel.cancelInput()
                lastError = nil
                inputFocused = .search
            }
        }
    }

    private static let cancelInputAction = IslandCaseRowAction(
        systemImage: "xmark",
        accessibilityIdentifier: "case.input.cancel",
        accessibilityLabel: "Cancel new key"
    )

    private var inputBorderColor: Color {
        lastError == nil ? IslandInk.color.opacity(0.18) : Color.red.opacity(0.60)
    }

    private var caseList: some View {
        let sections = viewModel.projectSections
        let searching = viewModel.isSearching
        return ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        Color.clear.frame(height: 1).id(topScrollID)
                        if sections.isEmpty, searching {
                            Text("No results")
                                .font(.system(size: 11))
                                .foregroundStyle(IslandInk.color.opacity(0.78))
                                .padding(.vertical, 12)
                        }

                        ForEach(sections) { section in
                            projectSection(
                                section,
                                isExpanded: Self.isExpanded(section, expandedIDs: viewModel.expandedProjectIDs, isSearching: searching)
                            )
                        }

                        Color.clear.frame(height: 1).id(bottomScrollID)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onContinuousHover { phase in
                    // Never reset here: the pointer can leave and re-enter mid-drag.
                    if case let .active(location) = phase {
                        scrollIfNeeded(
                            pointerY: location.y,
                            viewportHeight: geometry.size.height,
                            proxy: proxy
                        )
                    }
                }
                // A drag released on empty list space (or cancelled) never reaches a
                // project row's drop handler; clear it here so auto-scroll stops.
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    dragState.reset()
                    return false
                }
                .onDisappear { dragState.reset() }
            }
        }
    }

    @ViewBuilder
    private func projectSection(_ section: CaseProjectSection, isExpanded: Bool) -> some View {
        IslandCaseProjectRow(
            section: section,
            isExpanded: isExpanded,
            isDropTargeted: dragState.dropTargetProjectID == section.id,
            onToggle: { toggleProject(section.id) },
            onEdit: { startEditingProject(section) },
            onDelete: {
                pendingDeleteProjectID = pendingDeleteProjectID == section.id ? nil : section.id
                lastError = nil
            }
        )
        .onDrop(of: [UTType.text], isTargeted: dropTargetBinding(section.id)) { _ in
            handleDrop(onProject: section.id)
        }

        if pendingDeleteProjectID == section.id, !section.isGeneral {
            IslandCaseProjectDeleteConfirmation(
                name: section.name,
                keyCount: section.keyCount,
                onConfirm: { confirmDeleteProject(section.id) },
                onCancel: { pendingDeleteProjectID = nil }
            )
        }

        if projectEditor == .edit(section.id) {
            projectEditorControls(isGeneral: section.isGeneral)
        }

        if isExpanded {
            // First under the project name: a project can hold a hundred keys.
            // WHY: docs/DESIGN.md — Case add-key position.
            IslandCaseAddKeyRow(projectName: section.name) {
                startAddingKey(to: section.id)
            }
            .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                handleDrop(onProject: section.id)
            }
            .padding(.leading, IslandCaseVaultStyle.childIndent)

            ForEach(section.secrets) { secret in
                VStack(spacing: 3) {
                    IslandCaseSecretRow(
                        row: secret,
                        onEdit: { startEditingSecret(secret) },
                        onCopy: { runCaseAction { try viewModel.copySecret(secret.id) } },
                        onDelete: { runCaseAction { try viewModel.deleteSecret(secret.id) } }
                    )
                    .onDrag {
                        dragState.begin(secretID: secret.id, sourceProjectID: secret.projectID)
                        return NSItemProvider(object: secret.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                        handleDrop(onProject: secret.projectID)
                    }

                    if editSecretID == secret.id {
                        secretEditControls(secret)
                    }
                }
                .padding(.leading, IslandCaseVaultStyle.childIndent)
            }
        }
    }

    private func secretEditControls(_ row: CaseDisplayRow) -> some View {
        VStack(spacing: 4) {
            editField {
                TextField("Name", text: $editName)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            }
            editField {
                SecureField("New value", text: $editValue)
                    .font(.system(size: 9.5, weight: .medium))
                    .onSubmit { saveSecretEdit(row) }
            }
            editField {
                TextField("Description", text: $editDescription)
                    .font(.system(size: 9.5, weight: .medium))
                    .onSubmit { saveSecretEdit(row) }
            }
            editButtons(
                onSave: { saveSecretEdit(row) },
                onCancel: {
                    editSecretID = nil
                    editValue = ""
                    lastError = nil
                }
            )
        }
        .padding(.leading, 6)
    }

    private func projectEditorControls(isGeneral: Bool) -> some View {
        VStack(spacing: 4) {
            if !isGeneral {
                editField {
                    TextField("Project name", text: $projectNameDraft)
                        .font(.system(size: 9.5, weight: .medium))
                        .onSubmit(saveProjectEditor)
                }
            }
            editField {
                TextField("Description", text: $projectDescriptionDraft)
                    .font(.system(size: 9.5, weight: .medium))
                    .onSubmit(saveProjectEditor)
            }
            editButtons(
                onSave: saveProjectEditor,
                onCancel: {
                    projectEditor = nil
                    lastError = nil
                }
            )
        }
    }

    private func editField<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        CaseVaultEditField(content: content())
    }

    private func editButtons(onSave: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            IslandCaseIconButton(action: Self.cancelEditAction, perform: onCancel)
            IslandCaseIconButton(action: Self.saveEditAction, perform: onSave)
        }
    }

    private static let saveEditAction = IslandCaseRowAction(
        systemImage: "checkmark",
        accessibilityIdentifier: "case.edit.save",
        accessibilityLabel: "Save"
    )

    private static let cancelEditAction = IslandCaseRowAction(
        systemImage: "xmark",
        accessibilityIdentifier: "case.edit.cancel",
        accessibilityLabel: "Cancel editing"
    )

    private var accessRow: some View {
        IslandCaseConnectedApps(registrations: viewModel.registrations, onOpenAccess: { appID in
            accessAppID = appID
            showingAccess = true
            onOpenAccessScreen?()
        }, onConnect: {
            accessAppID = nil
            showingAccess = true
            onOpenAccessScreen?()
        })
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(IslandInk.color.opacity(0.10)).frame(height: 0.5)
        }
    }

    private func unlock() {
        guard !isUnlocking else { return }
        hasTriggeredInitialUnlock = true
        isUnlocking = true
        Task { @MainActor in
            defer { isUnlocking = false }
            do {
                try await viewModel.unlock()
                lastError = nil
                inputFocused = .search
            } catch {
                lastError = nil
            }
        }
    }

    private func unlockIfNeededOnOpen() {
        guard !viewModel.isUnlocked, !hasTriggeredInitialUnlock else {
            return
        }
        unlock()
    }

    private func resetCase() {
        guard !isUnlocking else { return }
        // Two-step confirm: first press arms (button label flips to "Confirm
        // Reset"), second press executes. armResetVault() returns true when it
        // arms; false if already armed -> proceed to the actual reset.
        let justArmed = viewModel.armResetVault()
        if justArmed {
            // Armed — wait for the second press. Nothing destructive yet.
            return
        }
        do {
            try viewModel.resetVault()
        } catch {
            // Reset failed (e.g. file removal error) — keep the needsReset
            // state so the user can retry; nothing sensitive to surface.
            return
        }
        unlock()
    }

    private func submitInput() {
        do {
            switch viewModel.inputMode {
            case .name:
                // Return in search only searches; adding requires the explicit + Key action.
                guard let addingProjectID else { return }
                try viewModel.submitName(nameDraft, projectID: addingProjectID)
                valueDraft = ""
                // Name accepted -> inputMode flips to .value and the field
                // rebuilds as a SecureField. Re-assert focus on the next runloop
                // tick so the cursor lands in the value field without a click.
                DispatchQueue.main.async { inputFocused = .newKey }
            case .value:
                try viewModel.submitValue(valueDraft)
                valueDraft = ""
                addingProjectID = nil
                nameDraft = ""
                inputFocused = .search
            }
            lastError = nil
        } catch {
            lastError = caseErrorMessage(for: error)
        }
    }

    private func startAddingKey(to projectID: UUID) {
        viewModel.expandedProjectIDs.insert(projectID)
        addingProjectID = projectID
        nameDraft = ""
        valueDraft = ""
        viewModel.cancelInput()
        lastError = nil
        inputFocused = .newKey
    }

    private func startEditingSecret(_ row: CaseDisplayRow) {
        editSecretID = editSecretID == row.id ? nil : row.id
        editName = row.displayName
        editValue = ""
        editDescription = row.description
        lastError = nil
    }

    private func saveSecretEdit(_ row: CaseDisplayRow) {
        runCaseAction {
            if editValue.isEmpty {
                if editName != row.displayName {
                    try viewModel.renameSecret(row.id, rawName: editName)
                }
            } else {
                try viewModel.replaceSecret(row.id, rawName: editName, newValue: editValue)
            }
            if editDescription != row.description {
                try viewModel.setSecretDescription(row.id, editDescription)
            }
            editSecretID = nil
            editValue = ""
        }
    }

    private func startCreatingProject() {
        if projectEditor == .create {
            projectEditor = nil
            return
        }
        projectEditor = .create
        projectNameDraft = ""
        projectDescriptionDraft = ""
        pendingDeleteProjectID = nil
        lastError = nil
    }

    private func startEditingProject(_ section: CaseProjectSection) {
        if projectEditor == .edit(section.id) {
            projectEditor = nil
            return
        }
        projectEditor = .edit(section.id)
        projectNameDraft = section.name
        projectDescriptionDraft = section.description
        pendingDeleteProjectID = nil
        lastError = nil
    }

    private func saveProjectEditor() {
        guard let projectEditor else { return }
        runCaseAction(isProjectAction: true) {
            switch projectEditor {
            case .create:
                try viewModel.createProject(name: projectNameDraft, description: projectDescriptionDraft)
            case let .edit(projectID):
                let current = viewModel.projectSections.first { $0.id == projectID }
                if projectID != CaseProject.generalID, projectNameDraft != current?.name {
                    try viewModel.renameProject(projectID, name: projectNameDraft)
                }
                if projectDescriptionDraft != current?.description {
                    try viewModel.setProjectDescription(projectID, projectDescriptionDraft)
                }
            }
            self.projectEditor = nil
        }
    }

    private func confirmDeleteProject(_ projectID: UUID) {
        runCaseAction {
            try viewModel.deleteProject(projectID)
            pendingDeleteProjectID = nil
            if addingProjectID == projectID {
                addingProjectID = nil
            }
        }
    }

    private func dropTargetBinding(_ projectID: UUID) -> Binding<Bool> {
        Binding(
            get: { dragState.dropTargetProjectID == projectID },
            set: { targeted in
                if targeted {
                    dragState.dropTargetProjectID = projectID
                } else if dragState.dropTargetProjectID == projectID {
                    dragState.dropTargetProjectID = nil
                }
            }
        )
    }

    /// Dropping a dragged key on a project header (or on one of its keys)
    /// moves the key into that project. A name clash there is refused.
    private func handleDrop(onProject projectID: UUID) -> Bool {
        let context = dragState.context
        defer { dragState.reset() }
        guard let dragContext = context, dragContext.sourceProjectID != projectID else {
            return false
        }
        runCaseAction {
            try viewModel.moveSecret(dragContext.secretID, toProject: projectID)
            viewModel.expandedProjectIDs.insert(projectID)
        }
        return true
    }

    private func scrollIfNeeded(
        pointerY: CGFloat,
        viewportHeight: CGFloat,
        proxy: ScrollViewProxy
    ) {
        let velocity = dragState.scrollVelocity(
            pointerY: pointerY,
            viewportHeight: viewportHeight
        )
        guard velocity != 0 else {
            return
        }

        withAnimation(reduceMotion ? nil : .linear(duration: 0.12)) {
            proxy.scrollTo(velocity < 0 ? topScrollID : bottomScrollID, anchor: velocity < 0 ? .top : .bottom)
        }
    }

    private func toggleProject(_ projectID: UUID) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if viewModel.expandedProjectIDs.contains(projectID) {
                viewModel.expandedProjectIDs.remove(projectID)
            } else {
                viewModel.expandedProjectIDs.insert(projectID)
            }
        }
    }

    private func runCaseAction(isProjectAction: Bool = false, _ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = caseErrorMessage(for: error, isProjectAction: isProjectAction)
        }
    }

    private func caseErrorMessage(for error: Error, isProjectAction: Bool = false) -> String {
        switch error {
        case CaseNameValidationError.empty:
            return "Enter a name"
        case CaseNameValidationError.rawTooLong:
            return "Name is too long"
        case CaseNameValidationError.nonASCII:
            return "Only A-Z, 0-9 and separators"
        case CaseNameValidationError.normalizedTooLong:
            return "Name is too long after formatting"
        case CaseViewModelError.duplicateName:
            return isProjectAction ? "This project already exists" : "This key already exists"
        case CaseViewModelError.emptyValue:
            return "Enter a value"
        case CaseViewModelError.valueTooLong:
            return "Value is too long"
        case CaseViewModelError.invalidProjectName:
            return "Invalid project name"
        case CaseViewModelError.invalidProjectOperation:
            return "This project can’t be changed"
        case CaseViewModelError.descriptionTooLong:
            return "Description is too long"
        case CaseViewModelError.missingProject:
            return "Project not found"
        case CaseViewModelError.locked:
            return "Case is locked"
        default:
            return "Something went wrong"
        }
    }
}

private enum ProjectEditor: Equatable {
    case create
    case edit(UUID)
}


/// Shared field feedback changes drawing only; bindings and submission stay with callers.
// WHY: docs/DESIGN.md — Case English copy and interaction feedback.
private struct CaseVaultFieldFeedback: ViewModifier {
    let focused: Bool
    var border: Color = IslandInk.color.opacity(0.18)
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(Capsule().strokeBorder(enabled && focused ? IslandInk.color.opacity(0.8)
                : enabled && hovered ? IslandInk.color.opacity(0.5) : border, lineWidth: 1)
                .allowsHitTesting(false))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = enabled && $0 }
            .onChange(of: enabled) { _, active in if !active { hovered = false } }
    }
}

private struct CaseVaultEditField<Content: View>: View {
    let content: Content
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    var body: some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .foregroundStyle(IslandInk.color.opacity(0.90))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(IslandInk.color.opacity(0.10)))
            .modifier(CaseVaultFieldFeedback(focused: focused))
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { focused = true } }
    }
}
