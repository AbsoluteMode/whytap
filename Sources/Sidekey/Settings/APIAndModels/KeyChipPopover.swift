import SwiftUI

/// What a click on a key chip opens: the check result, a new key, a re-check
/// and removal. The key itself is never shown or read back.
@MainActor
struct KeyChipPopover: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let account: ProviderAccount
    let onDismiss: () -> Void

    @State private var newKey = ""
    @State private var message: String?
    @State private var replacing = false
    @State private var checking = false
    @State private var confirmingRemoval = false

    var body: some View {
        if let chip = viewModel.chips.first(where: { $0.account == account }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProviderKindIcon(kind: account.kind)
                    Text(chip.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(chip.statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text)
                    if let checkedAt = chip.checkedAt {
                        Text("Checked \(Self.relative(checkedAt))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                    }
                }
                replaceSection
                HStack(spacing: 8) {
                    MacButton(title: "Check now", style: .default, isEnabled: !checking) {
                        checking = true
                        Task {
                            await viewModel.checkKey(account)
                            checking = false
                        }
                    }
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    if !confirmingRemoval {
                        MacButton(title: "Remove", style: .danger) { confirmingRemoval = true }
                    }
                }
                if confirmingRemoval { removalConfirmation }
            }
            .padding(14)
            .frame(width: 290)
        }
    }

    private var replaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
            SecureField("New API key", text: $newKey)
                .textFieldStyle(.roundedBorder)
                .disabled(replacing)
            HStack(spacing: 8) {
                MacButton(
                    title: "Replace key", style: .tinted,
                    isEnabled: !replacing && !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    replace()
                }
                if replacing { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(MacSettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var removalConfirmation: some View {
        let features = viewModel.featuresUsing(account)
        return VStack(alignment: .leading, spacing: 8) {
            Text(features.isEmpty
                 ? "No features use this key."
                 : "\(features.map(\.title).joined(separator: ", ")) will have no model.")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                MacButton(title: "Cancel", style: .default) { confirmingRemoval = false }
                MacButton(title: "Remove", style: .danger) {
                    viewModel.remove(account)
                    onDismiss()
                }
            }
        }
    }

    private func replace() {
        replacing = true
        message = nil
        let candidate = newKey
        Task {
            let error = await viewModel.replaceKey(candidate, for: account)
            replacing = false
            if let error {
                message = error
            } else {
                newKey = ""
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
