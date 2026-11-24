import SwiftUI

/// One icon action on a Case row. The order of a row's `actions` is the order
/// of its buttons, left to right.
struct IslandCaseRowAction: Equatable, Identifiable {
    let systemImage: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String

    var id: String { accessibilityIdentifier }
}

/// A Case key: monospace name, optional description, then pencil / copy /
/// delete. Never receives or renders the stored value.
struct IslandCaseSecretRow: View {
    static let edit = IslandCaseRowAction(systemImage: "pencil", accessibilityIdentifier: "case.secret.edit", accessibilityLabel: "Edit key")
    static let copy = IslandCaseRowAction(systemImage: "doc.on.doc", accessibilityIdentifier: "case.secret.copy", accessibilityLabel: "Copy key")
    static let delete = IslandCaseRowAction(systemImage: "trash", accessibilityIdentifier: "case.secret.delete", accessibilityLabel: "Delete key")
    static let actions = [edit, copy, delete]
    /// Under a key whose value is too short for `whytap case run` to mask.
    static let notMaskedHint = "Not masked in output"

    let row: CaseDisplayRow
    var isDropTargeted = false
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("case.secret.name")

                if !row.description.isEmpty {
                    Text(row.description)
                        .font(.system(size: IslandCaseVaultStyle.descriptionFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if row.valueNotMasked {
                    Label(Self.notMaskedHint, systemImage: "eye")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: IslandCaseVaultStyle.descriptionFontSize, weight: .medium))
                        .foregroundStyle(Color.orange.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("case.secret.notMasked")
                        .help("This value is under 4 bytes, so whytap case run can’t mask it in output")
                }
            }
            .layoutPriority(-1)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                ForEach(Self.actions) { action in
                    IslandCaseIconButton(action: action, perform: perform(action))
                }
            }
            .fixedSize()
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, row.description.isEmpty && !row.valueNotMasked ? 0 : 3)
        .frame(minHeight: IslandCaseVaultStyle.childRowHeight)
        .background(RoundedRectangle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius, style: .continuous)
            .fill(Color.white.opacity(isDropTargeted ? 0.14 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 0.7))
        .contentShape(Rectangle())
    }

    private func perform(_ action: IslandCaseRowAction) -> () -> Void {
        switch action {
        case Self.edit: return onEdit
        case Self.copy: return onCopy
        default: return onDelete
        }
    }
}

/// "+ Key in <project>": the first row of an expanded project, above its keys.
struct IslandCaseAddKeyRow: View {
    let projectName: String
    let action: () -> Void

    static func title(projectName: String) -> String {
        "+ Key in \(projectName)"
    }

    var body: some View {
        Button(action: action) {
            Text(Self.title(projectName: projectName))
                .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: IslandCaseVaultStyle.childRowHeight, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
                .contentShape(Rectangle())
        }
        .buttonStyle(CaseAccessButtonStyle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius))
        .accessibilityIdentifier("case.project.addKey")
    }
}

struct IslandCaseIconButton: View {
    let action: IslandCaseRowAction
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.74))
                .frame(width: IslandCaseVaultStyle.iconButtonSize, height: IslandCaseVaultStyle.iconButtonSize)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(CaseAccessButtonStyle(cornerRadius: IslandCaseVaultStyle.iconButtonSize / 2))
        .help(action.accessibilityLabel)
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
