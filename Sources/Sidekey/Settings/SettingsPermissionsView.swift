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
                            subtitle: viewModel.keyboardUnavailable ? PermissionsSettingsViewModel.unavailableLine : nil,
                            granted: viewModel.snapshot.accessibilityGranted,
                            requested: viewModel.keyboardOpensSettings,
                            checking: viewModel.refusals.checking.contains(.keyboard),
                            unavailable: viewModel.keyboardUnavailable,
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
                            subtitle: viewModel.screenUnavailable ? PermissionsSettingsViewModel.unavailableLine
                                : "For screenshots. If macOS asks to reopen Whytap, finish your current work first.",
                            granted: viewModel.screenRecordingGranted,
                            requested: viewModel.screenRecordingRequested,
                            isRequesting: viewModel.isRequestingScreenRecording,
                            unavailable: viewModel.screenUnavailable,
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
        requested: Bool = false,
        isRequesting: Bool = false,
        checking: Bool = false,
        unavailable: Bool = false,
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
                    } else if unavailable {
                        // 27.3 beta refused the request without a dialog: no
                        // button that would lead to the pane's "+".
                        // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
                        Text("Not available yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize()
                            .accessibilityLabel("\(title): not available on this macOS beta yet")
                    } else if isRequesting || checking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Waiting for \(title) permission")
                    } else {
                        // After the system request the same button leads to the pane.
                        MacButton(title: requested ? "Open Settings" : "Allow", style: .default, action: action)
                            .fixedSize()
                            .accessibilityLabel(requested ? "Open System Settings for \(title)" : "Allow \(title)")
                    }
                }
                .frame(minWidth: 60, minHeight: 26)
            }
        )
    }
}
