import SwiftUI

/// Standalone repair surface shown to a returning user when a required
/// permission (Accessibility and/or Microphone) has been revoked. This
/// is NOT part of the onboarding tour — it's a narrow window that lives
/// until all required permissions are re-granted, then auto-closes.
@MainActor
struct PermissionRepairView: View {
    @ObservedObject var viewModel: PermissionsSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Enable Drop")
                    Text("Allow the items below, then press your Drop shortcut again. This window closes when Drop is ready.")
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 12)
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacCard {
                        MacRow(
                            title: "Keyboard control",
                            subtitle: viewModel.keyboardNeedsRestart && viewModel.restartBlocked != nil ? viewModel.restartBlocked!
                                : viewModel.settingsOnly ? PermissionsSettingsViewModel.keyboardSettingsGuide
                                : "Required for Drop and the Agent. macOS asks first; after that, turn on Whytap under Accessibility in System Settings.",
                            leading: {
                                Image(systemName: "keyboard.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(MacSettingsTheme.text2)
                                    .frame(width: 22)
                            },
                            trailing: {
                                HStack(spacing: 10) {
                                    let ready = viewModel.keyboardReady && !viewModel.keyboardNeedsRestart
                                    MacPill(
                                        text: ready ? "Allowed" : "Required",
                                        tone: ready ? .green : .orange,
                                        showsDot: true
                                    )
                                    // 27.3: a grant made in System Settings works after a restart.
                                    // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
                                    if viewModel.keyboardNeedsRestart {
                                        MacButton(title: "Restart Whytap", style: .default) { viewModel.restartWhytap() }
                                    } else if !ready {
                                        // The first press asks macOS; later ones (and every press on 27.3) open System Settings.
                                        MacButton(title: viewModel.keyboardOpensSettings ? "Open Settings" : "Allow",
                                                  style: .default, action: viewModel.requestAccessibility)
                                    }
                                }
                            }
                        )
                        MacRowSeparator()
                        MacRow(
                            title: "Microphone",
                            subtitle: "Required to record your voice.",
                            leading: {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(MacSettingsTheme.text2)
                                    .frame(width: 22)
                            },
                            trailing: {
                                HStack(spacing: 10) {
                                    MacPill(
                                        text: viewModel.snapshot.microphoneGranted ? "Allowed" : viewModel.microphoneLabel,
                                        tone: viewModel.snapshot.microphoneGranted ? .green : .orange,
                                        showsDot: true
                                    )
                                    if !viewModel.snapshot.microphoneGranted {
                                        MacButton(title: "Allow", style: .default, action: viewModel.requestMicrophone)
                                    }
                                }
                            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The shared window chrome is transparent; paint an opaque surface.
        .background(Color(red: 0.10, green: 0.10, blue: 0.11).ignoresSafeArea())
    }
}
