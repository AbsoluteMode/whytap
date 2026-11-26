import SwiftUI

/// The same actionable shortcut state appears in normal Settings and repair.
/// A failed Carbon registration is not labelled as a missing OS permission.
@MainActor
struct DropShortcutStatusSection: View {
    @ObservedObject var viewModel: PermissionsSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacGroupTitle(title: "Drop shortcut")
            MacCard {
                MacRow(
                    title: viewModel.dropHotkeyStatus.title,
                    subtitle: viewModel.dropHotkeyStatus.message,
                    leading: {
                        Image(systemName: viewModel.dropHotkeyStatus == .ready ? "checkmark.circle.fill" : "keyboard")
                            .foregroundStyle(viewModel.dropHotkeyStatus == .ready ? Color.green : Color.orange)
                            .frame(width: 22)
                    },
                    trailing: { EmptyView() }
                )
            }
            // The status line names itself; the section is the row Lil Bro leads to.
            .lilBroItems()

            if viewModel.dropHotkeyStatus != .ready {
                HStack(spacing: 10) {
                    MacButton(title: "Retry shortcut", style: .default, action: viewModel.retryDropShortcut)
                    if viewModel.dropHotkeyStatus == .inputMonitoringRequired {
                        MacButton(title: "Open Settings", style: .default, action: viewModel.requestInputMonitoring)
                    } else if viewModel.dropHotkeyStatus == .accessibilityRequired {
                        MacButton(title: "Show Whytap in Finder", style: .default, action: PermissionsHelper.revealCurrentAppBundle)
                    } else if viewModel.dropHotkeyStatus == .shortcutInUse || viewModel.dropHotkeyStatus == .unavailable {
                        MacButton(title: "Hotkeys…", style: .default, action: viewModel.openHotkeys)
                    }
                }
            }
        }
        .lilBroCatalogRow("Drop shortcut")
    }
}
