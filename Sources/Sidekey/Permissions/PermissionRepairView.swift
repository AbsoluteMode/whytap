import SwiftUI

/// Standalone repair surface shown to a returning user when a required
/// permission (Accessibility and/or Microphone) has been revoked. This
/// is NOT part of the onboarding tour — it's a narrow window that lives
/// until all required permissions are re-granted, then auto-closes.
@MainActor
struct PermissionRepairView: View {
    @ObservedObject var viewModel: OnboardingPermissionsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Whytap needs permission again")
                    Text("Whytap lost a permission it needs to run. Re-grant the items below — Drop and the Agent stay disabled until then.")
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 12)
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacCard {
                        MacRow(
                            title: "Accessibility",
                            subtitle: "Required for Drop (hold Space) and the Agent (Right Cmd).",
                            leading: {
                                Image(systemName: "keyboard.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(MacSettingsTheme.text2)
                                    .frame(width: 22)
                            },
                            trailing: {
                                HStack(spacing: 10) {
                                    MacPill(
                                        text: viewModel.snapshot.accessibilityGranted ? "Allowed" : "Required",
                                        tone: viewModel.snapshot.accessibilityGranted ? .green : .orange,
                                        showsDot: true
                                    )
                                    if !viewModel.snapshot.accessibilityGranted {
                                        MacButton(title: "Open Settings", style: .default, action: viewModel.requestAccessibility)
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
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { viewModel.refresh() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // SidekeyWindowChrome renders this window transparent (clear background,
        // isOpaque = false, no shadow), so the hosted content MUST paint its own
        // opaque fill — otherwise the window is see-through and reads as "no
        // window at all" even after makeKeyAndOrderFront. Every onboarding screen
        // does the same via OnboardingTheme.bg; this repair surface shares that
        // palette because it reuses OnboardingPermissionsViewModel.
        // WHY: docs/decisions/2026-06-15-permission-repair-invisible-window.md
        .background(OnboardingTheme.bg.ignoresSafeArea())
    }
}
