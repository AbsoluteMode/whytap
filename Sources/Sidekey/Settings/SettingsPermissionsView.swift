import SwiftUI

@MainActor
struct SettingsPermissionsView: View {
    @ObservedObject var viewModel: OnboardingPermissionsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Permissions")
                    MacCard {
                        permissionRow(
                            icon: "keyboard.fill",
                            title: "Universal Access",
                            granted: viewModel.snapshot.accessibilityGranted,
                            status: viewModel.snapshot.accessibilityGranted ? "Allowed" : "Required",
                            actionTitle: "Open",
                            action: viewModel.requestAccessibility
                        )
                        MacRowSeparator()
                        permissionRow(
                            icon: "mic.fill",
                            title: "Microphone",
                            granted: viewModel.snapshot.microphoneGranted,
                            status: viewModel.microphoneLabel,
                            actionTitle: "Allow",
                            action: viewModel.requestMicrophone
                        )
                    }
                }

                MacButton(title: "Refresh", style: .default) { viewModel.refresh() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { viewModel.refresh() }
    }

    private func permissionRow(
        icon: String,
        title: String,
        granted: Bool,
        status: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        MacRow(
            title: title,
            leading: {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 22)
            },
            trailing: {
                HStack(spacing: 10) {
                    MacPill(text: status, tone: granted ? .green : .orange, showsDot: true)
                    MacButton(title: actionTitle, style: .default, action: action)
                }
            }
        )
    }
}
