import SwiftUI

@MainActor
struct SettingsPermissionsView: View {
    @ObservedObject var viewModel: PermissionsSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Permissions")
                    MacCard {
                        permissionRow(
                            icon: "keyboard.fill",
                            title: "Keyboard control",
                            granted: viewModel.snapshot.accessibilityGranted,
                            action: viewModel.requestAccessibility
                        )
                        MacRowSeparator()
                        permissionRow(
                            icon: "mic.fill",
                            title: "Microphone",
                            granted: viewModel.snapshot.microphoneGranted,
                            action: viewModel.requestMicrophone
                        )
                        MacRowSeparator()
                        permissionRow(
                            icon: "rectangle.dashed.badge.record",
                            title: "Screen Recording",
                            subtitle: "For screenshots. If macOS asks to reopen Whytap, finish your current work first.",
                            granted: viewModel.screenRecordingGranted,
                            isRequesting: viewModel.isRequestingScreenRecording,
                            action: { Task { await viewModel.requestScreenRecording() } }
                        )
                    }
                }

                DropShortcutStatusSection(viewModel: viewModel)
                MacButton(title: "Refresh", style: .default) { viewModel.refresh() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { viewModel.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refresh(restartRecoveryPolling: false)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        granted: Bool,
        isRequesting: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        MacRow(
            title: title,
            subtitle: subtitle,
            leading: {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 22)
            },
            trailing: {
                Group {
                    if granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(MacSettingsTheme.green)
                            .accessibilityLabel("\(title): Allowed")
                    } else if isRequesting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Waiting for \(title) permission")
                    } else {
                        MacButton(title: "Allow", style: .default, action: action)
                            .accessibilityLabel("Allow \(title)")
                    }
                }
                .frame(width: 60, height: 26)
            }
        )
    }
}
