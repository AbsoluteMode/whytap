import SwiftUI

/// Add key: pick a provider that has no key yet, enter the key (or, for your
/// own server, its name and base URL) and save. The key is checked first; a
/// refusal shows under the field and the window stays open.
@MainActor
struct AddKeySheet: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let onClose: () -> Void

    @State private var kind: AIProviderKind?
    @State private var key = ""
    @State private var name = ""
    @State private var baseURL = ""
    @State private var error: String?
    @State private var saving = false

    private var selectedKind: AIProviderKind? { kind ?? viewModel.addableKinds.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add key")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
            HStack {
                Text("Provider").font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                Spacer()
                MacPopup(items: viewModel.addableKinds.map { .init(value: Optional($0), label: $0.displayName) },
                         selection: Binding(get: { selectedKind }, set: { kind = $0; error = nil }),
                         maxWidth: 260)
                    .accessibilityLabel("Provider")
                    .disabled(saving)
            }
            fields
            if let error {
                Text(error).font(.caption).foregroundStyle(MacSettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                MacButton(title: "Cancel", style: .default, isEnabled: !saving, action: onClose)
                MacButton(title: "Save", style: .primary, isEnabled: canSave, action: save)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isServer: Bool { selectedKind == .openAICompatible }

    private var canSave: Bool {
        guard !saving, selectedKind != nil else { return false }
        if isServer {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var fields: some View {
        if isServer {
            MacField(placeholder: "Name", text: $name)
            MacField(placeholder: "Base URL", text: $baseURL, monospaced: true)
            Text("For example http://localhost:8000/v1")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
            SecureField("API key (optional)", text: $key)
                .textFieldStyle(.roundedBorder)
                .disabled(saving)
        } else {
            // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .disabled(saving)
            Text("Saved in your Mac Keychain and checked before it is kept.")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
        }
    }

    private func save() {
        guard let kind = selectedKind else { return }
        saving = true
        error = nil
        let candidate = key
        Task {
            let failure: String?
            if kind == .openAICompatible {
                failure = await viewModel.addServer(name: name, baseURL: baseURL, key: candidate)
            } else {
                failure = await viewModel.addKey(candidate, kind: kind)
            }
            saving = false
            if let failure {
                error = failure
            } else {
                key = ""
                onClose()
            }
        }
    }
}
