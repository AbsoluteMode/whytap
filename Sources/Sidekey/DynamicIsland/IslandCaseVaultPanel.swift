import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum IslandCaseVaultStyle {
    static let horizontalPadding: CGFloat = 10
    static let topPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 5
    static let inputHeight: CGFloat = 28
    static let rowHeight: CGFloat = 26
    static let childRowHeight: CGFloat = 24
    static let iconButtonSize: CGFloat = 18
    static let inputFontSize: CGFloat = 11
    static let nameFontSize: CGFloat = 10
    static let errorFontSize: CGFloat = 9
}

struct IslandCaseVaultPanel: View {
    @ObservedObject var viewModel: CaseViewModel

    @State private var valueDraft = ""
    @State private var editSecretID: UUID?
    @State private var editName = ""
    @State private var editValue = ""
    @State private var addingGroupID: UUID?
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var pendingGroupCreation: PendingGroupCreation?
    @State private var groupNameDraft = ""
    @State private var dragContext: DragContext?
    @State private var lastError: String?
    @FocusState private var inputFocused: Bool

    private let topScrollID = "case-list-top"
    private let bottomScrollID = "case-list-bottom"
    @State private var isUnlocking = false
    @State private var hasTriggeredInitialUnlock = false

    var body: some View {
        Group {
            if viewModel.isUnlocked {
                unlockedPanel
            } else {
                lockedPanel
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                inputFocused = true
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
                    unlockPill(title: viewModel.isResetArmed ? "Confirm Reset" : "Reset Case")
                }
                .buttonStyle(.plain)
                .disabled(isUnlocking)

                // Armed: spell out the stakes — the second press is irreversible.
                Text(viewModel.isResetArmed
                    ? "This permanently deletes this Case. Press again to confirm."
                    : message)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
            } else if case let .needsNewerApp(message) = viewModel.unlockState {
                unlockPill(title: "Update Required")

                Text(message)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
            } else {
                if isUnlocking || !hasTriggeredInitialUnlock {
                    unlockPill(title: "Unlocking...")
                } else {
                    Button(action: unlock) {
                        unlockPill(title: "Retry Unlock")
                    }
                    .buttonStyle(.plain)
                    .disabled(isUnlocking)
                }

                Text("Touch ID / macOS password")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))

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
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 0.8))
    }

    private var unlockedPanel: some View {
        VStack(spacing: IslandCaseVaultStyle.rowSpacing) {
            inputBar
                .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
                .padding(.top, IslandCaseVaultStyle.topPadding)

            if let pendingGroupCreation {
                groupCreationPrompt(pendingGroupCreation)
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
            } else if let lastError {
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
                .padding(.bottom, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if activeInputText.isEmpty {
                    Text(inputPlaceholder)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }

                inputField
                    .font(.system(size: IslandCaseVaultStyle.inputFontSize, weight: .medium))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .focused($inputFocused)
                    .onSubmit(submitInput)
            }
            .frame(height: IslandCaseVaultStyle.inputHeight)
            .background(Capsule().fill(Color.white.opacity(0.13)))
            .overlay(Capsule().stroke(inputBorderColor, lineWidth: 0.8))

            if viewModel.inputMode != .name || addingGroupID != nil {
                iconButton(systemImage: "xmark", accessibilityLabel: "Cancel key input") {
                    valueDraft = ""
                    addingGroupID = nil
                    viewModel.cancelInput()
                    lastError = nil
                }
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        switch viewModel.inputMode {
        case .name:
            TextField("", text: $viewModel.query)
        case .value:
            SecureField("", text: $valueDraft)
        }
    }

    private var activeInputText: String {
        switch viewModel.inputMode {
        case .name:
            return viewModel.query
        case .value:
            return valueDraft
        }
    }

    private var inputPlaceholder: String {
        switch viewModel.inputMode {
        case .name:
            if let addingGroupID {
                let groupName = viewModel.rows.first { $0.id == addingGroupID }?.displayName ?? "group"
                return "Add key to \(groupName)"
            }
            return "Search or add key"
        case .value:
            return "Enter value"
        }
    }

    private var inputBorderColor: Color {
        lastError == nil ? Color.white.opacity(0.18) : Color.red.opacity(0.60)
    }

    private var caseList: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        Color.clear.frame(height: 1).id(topScrollID)

                        ForEach(viewModel.rows) { row in
                            switch row.kind {
                            case .secret:
                                secretRow(row, groupID: nil)
                                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                                        handleSecretDrop(on: row.id)
                                    }
                            case .group:
                                groupRow(row)
                            }
                        }

                        Color.clear.frame(height: 1).id(bottomScrollID)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    handleBackgroundDrop()
                }
                .onContinuousHover { phase in
                    guard dragContext != nil else { return }
                    if case let .active(location) = phase {
                        scrollIfNeeded(
                            pointerY: location.y,
                            viewportHeight: geometry.size.height,
                            proxy: proxy
                        )
                    }
                }
            }
        }
    }

    private func groupRow(_ row: CaseDisplayRow) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: expandedGroupIDs.contains(row.id) ? "folder.fill" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 14)

                Text(row.displayName)
                    .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                iconButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy all keys in group") {
                    runCaseAction { try viewModel.copyAll(row.id) }
                }
                .help("Copy all")

                iconButton(systemImage: "plus", accessibilityLabel: "Add key to group") {
                    addingGroupID = row.id
                    valueDraft = ""
                    viewModel.cancelInput()
                    inputFocused = true
                }
                .help("Add key")

                Image(systemName: expandedGroupIDs.contains(row.id) ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 12)
            }
            .padding(.horizontal, 8)
            .frame(height: IslandCaseVaultStyle.rowHeight)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.7))
            .contentShape(Rectangle())
            .onTapGesture {
                toggleGroup(row.id)
            }
            .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                handleGroupDrop(on: row.id)
            }

            if expandedGroupIDs.contains(row.id) {
                VStack(spacing: 3) {
                    ForEach(viewModel.childRows(forGroupID: row.id)) { child in
                        secretRow(child, groupID: row.id)
                            .padding(.leading, 12)
                            .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                                handleSecretDrop(on: child.id)
                            }
                    }
                }
            }
        }
    }

    private func secretRow(_ row: CaseDisplayRow, groupID: UUID?) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.64))
                    .frame(width: 14)

                Text(row.displayName)
                    .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                iconButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy key") {
                    runCaseAction { try viewModel.copySecret(row.id) }
                }
                .help("Copy")

                iconButton(systemImage: "pencil", accessibilityLabel: "Edit key") {
                    editSecretID = row.id
                    editName = row.displayName
                    editValue = ""
                    lastError = nil
                }
                .help("Edit")

                iconButton(systemImage: "trash", accessibilityLabel: "Delete key") {
                    runCaseAction { try viewModel.deleteSecret(row.id) }
                }
                .help("Delete")
            }
            .padding(.horizontal, 8)
            .frame(height: groupID == nil ? IslandCaseVaultStyle.rowHeight : IslandCaseVaultStyle.childRowHeight)
            .background(Capsule().fill(Color.white.opacity(groupID == nil ? 0.08 : 0.06)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.7))
            .contentShape(Rectangle())
            .onDrag {
                dragContext = DragContext(secretID: row.id, startedInsideGroup: groupID != nil)
                return NSItemProvider(object: row.id.uuidString as NSString)
            }

            if editSecretID == row.id {
                editControls(row)
            }
        }
    }

    private func editControls(_ row: CaseDisplayRow) -> some View {
        HStack(spacing: 5) {
            TextField("Name", text: $editName)
                .textFieldStyle(.plain)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.90))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.10)))

            SecureField("New value", text: $editValue)
                .textFieldStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.90))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .onSubmit {
                    saveEdit(row.id)
                }

            iconButton(systemImage: "checkmark", accessibilityLabel: "Save key") {
                saveEdit(row.id)
            }

            iconButton(systemImage: "xmark", accessibilityLabel: "Cancel edit") {
                editSecretID = nil
                editValue = ""
                lastError = nil
            }
        }
        .padding(.leading, 18)
    }

    private func groupCreationPrompt(_ pending: PendingGroupCreation) -> some View {
        HStack(spacing: 6) {
            TextField("Group name", text: $groupNameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.90))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.11)))
                .onSubmit {
                    confirmGroupCreation(pending)
                }

            iconButton(systemImage: "checkmark", accessibilityLabel: "Create group") {
                confirmGroupCreation(pending)
            }

            iconButton(systemImage: "xmark", accessibilityLabel: "Cancel group") {
                pendingGroupCreation = nil
                groupNameDraft = ""
                lastError = nil
            }
        }
    }

    private func iconButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.74))
                .frame(
                    width: IslandCaseVaultStyle.iconButtonSize,
                    height: IslandCaseVaultStyle.iconButtonSize
                )
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
                inputFocused = true
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
                try viewModel.submitName(viewModel.query, groupID: addingGroupID)
                valueDraft = ""
                // Name accepted -> inputMode flips to .value and the field
                // rebuilds as a SecureField. Re-assert focus on the next runloop
                // tick so the cursor lands in the value field without a click.
                DispatchQueue.main.async { inputFocused = true }
            case .value:
                try viewModel.submitValue(valueDraft)
                valueDraft = ""
                addingGroupID = nil
            }
            lastError = nil
        } catch {
            lastError = caseErrorMessage(for: error)
        }
    }

    private func saveEdit(_ secretID: UUID) {
        runCaseAction {
            if editValue.isEmpty {
                try viewModel.renameSecret(secretID, rawName: editName)
            } else {
                try viewModel.replaceSecret(secretID, rawName: editName, newValue: editValue)
            }
            editSecretID = nil
            editValue = ""
        }
    }

    private func confirmGroupCreation(_ pending: PendingGroupCreation) {
        runCaseAction {
            let groupID = try viewModel.createGroup(
                sourceSecretID: pending.sourceSecretID,
                targetSecretID: pending.targetSecretID,
                name: groupNameDraft
            )
            expandedGroupIDs.insert(groupID)
            pendingGroupCreation = nil
            groupNameDraft = ""
        }
    }

    private func handleSecretDrop(on targetSecretID: UUID) -> Bool {
        defer { dragContext = nil }
        guard let dragContext, dragContext.secretID != targetSecretID else {
            return false
        }

        if dragContext.startedInsideGroup {
            runCaseAction { try viewModel.removeSecretFromGroup(dragContext.secretID) }
            return true
        }

        pendingGroupCreation = PendingGroupCreation(
            sourceSecretID: dragContext.secretID,
            targetSecretID: targetSecretID
        )
        groupNameDraft = ""
        lastError = nil
        return true
    }

    private func handleGroupDrop(on groupID: UUID) -> Bool {
        defer { dragContext = nil }
        guard let dragContext else {
            return false
        }

        if dragContext.startedInsideGroup {
            runCaseAction { try viewModel.removeSecretFromGroup(dragContext.secretID) }
            return true
        }

        runCaseAction {
            try viewModel.addSecretToGroup(secretID: dragContext.secretID, groupID: groupID)
            expandedGroupIDs.insert(groupID)
        }
        return true
    }

    private func handleBackgroundDrop() -> Bool {
        defer { dragContext = nil }
        guard let dragContext, dragContext.startedInsideGroup else {
            return false
        }

        runCaseAction { try viewModel.removeSecretFromGroup(dragContext.secretID) }
        return true
    }

    private func scrollIfNeeded(
        pointerY: CGFloat,
        viewportHeight: CGFloat,
        proxy: ScrollViewProxy
    ) {
        let velocity = CaseDragAutoScrollPolicy.velocity(
            pointerY: pointerY,
            viewportHeight: viewportHeight
        )
        guard velocity != 0 else {
            return
        }

        withAnimation(.linear(duration: 0.12)) {
            proxy.scrollTo(velocity < 0 ? topScrollID : bottomScrollID, anchor: velocity < 0 ? .top : .bottom)
        }
    }

    private func toggleGroup(_ groupID: UUID) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
    }

    private func runCaseAction(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = caseErrorMessage(for: error)
        }
    }

    private func caseErrorMessage(for error: Error) -> String {
        switch error {
        case CaseNameValidationError.empty:
            return "Name is required"
        case CaseNameValidationError.rawTooLong:
            return "Name is too long"
        case CaseNameValidationError.nonASCII:
            return "Use A-Z, 0-9 and separators"
        case CaseNameValidationError.normalizedTooLong:
            return "Normalized name is too long"
        case CaseViewModelError.duplicateName:
            return "Key already exists"
        case CaseViewModelError.emptyValue:
            return "Value is required"
        case CaseViewModelError.valueTooLong:
            return "Value is too long"
        case CaseViewModelError.invalidGroupName:
            return "Group name is invalid"
        case CaseViewModelError.invalidGroupOperation:
            return "Cannot move this key"
        case CaseViewModelError.locked:
            return "Case is locked"
        default:
            return "Action failed"
        }
    }
}

private struct PendingGroupCreation: Equatable {
    let sourceSecretID: UUID
    let targetSecretID: UUID
}

private struct DragContext: Equatable {
    let secretID: UUID
    let startedInsideGroup: Bool
}
