import SwiftUI

enum IslandUpdateAvailablePillStyle {
    /// SF Symbol shown in the compact pill when the update is available
    /// but not yet downloaded. Matches the downloading icon family.
    static let availableSystemImage = "arrow.down.circle"
    /// SF Symbol shown in the compact pill while Sparkle is still
    /// downloading the update. Hollow circle keeps it visibly distinct
    /// from the readyToInstall checkmark.
    static let downloadingSystemImage = "arrow.down.circle"
    /// SF Symbol shown in the compact pill once the update has been
    /// downloaded and Sparkle is waiting for the user to install.
    static let readyToInstallSystemImage = "checkmark.circle.fill"
    /// Hover-expanded primary action — Download (for .available stage).
    static let downloadActionSystemImage = "arrow.down.circle.fill"
    /// Hover-expanded secondary action — ✕ Skip this version (for .available
    /// stage). Skips THIS build in Sparkle; future versions still prompt.
    /// Replaces the old "Later" dismiss — `xmark` keeps the same icon family.
    static let skipActionSystemImage = "xmark"
    static let actionSpacing: CGFloat = 5
    static let actionButtonSize: CGFloat = 24
    static let actionIconFrameSize: CGFloat = 12
    static let primaryActionIconFontSize: CGFloat = 11.5
    static let secondaryActionIconFontSize: CGFloat = 12.6
    static let actionStrokeLineWidth: CGFloat = 0.85
}

/// Stage-tag used by the SwiftUI layer to switch rendering without
/// importing the `PendingUpdate.Stage` enum (whose `available` and
/// `readyToInstall` cases carry closures, which is awkward for view
/// equality and previews).
///
/// `IslandView` derives this from `PendingUpdate.stage`; tests construct
/// it directly.
enum IslandUpdateAvailablePillStage: Equatable {
    /// Update discovered; download not yet started. Pill shows «Update»
    /// with [Update ↓] [✕ Skip this version] in hover-expanded layout.
    case available
    /// Download (and the brief auto-install that follows) in progress.
    /// Compact-only, ICON-ONLY (no text); no hover actions.
    case downloading
    /// Download complete. With one-button update the host auto-installs and
    /// relaunches, so this tag is normally never forwarded to the pill; it
    /// is kept only so the stage mapping in `IslandView` stays exhaustive.
    /// No user-actionable restart UI.
    case readyToInstall
}

/// Right-band slot rendered in the Dynamic Island when
/// `AppState.updateAvailable` is set and no meeting layer is active.
///
/// Visual stages, driven by `stage`:
///   - `.available` — compact download icon + «Update» label. Hover-
///     expanded layout shows [Update ↓] [✕ Skip this version].
///   - `.downloading` — compact-only, ICON-ONLY (no text — "Updating" breaks
///     ugly in the ~70pt right band). Covers the download AND the brief
///     auto-install that follows. Hover-expanded layout shows the same
///     compact body because the user has nothing to act on.
///   - `.readyToInstall` — normally never reached: the host auto-installs +
///     relaunches (one-button update). No user-actionable restart UI.
///
/// Callbacks are stored as plain closures so they can be invoked
/// directly from `IslandUpdateAvailablePillTests` without ViewInspector.
/// Wiring lives in `IslandView` — see the `IslandWrapRow` ZStack layer
/// that pipes `PendingUpdate.startDownload` / `.skip` into
/// `onDownload` / `onSkip`.
struct IslandUpdateAvailablePill: View {
    /// `SUAppcastItem.displayVersionString` (e.g. "1.2.3") forwarded
    /// from `PendingUpdate.displayVersion`.
    let displayVersion: String

    let stage: IslandUpdateAvailablePillStage

    /// Driven from the Dynamic Island's hover-expanded state. Honoured
    /// only for `.available` (shows [Update ↓] [✕ Skip this version]).
    /// `.downloading` always renders the compact body to keep the UI calm
    /// while bytes are in flight, and `.readyToInstall` auto-installs.
    let hoverExpanded: Bool

    /// Invoked when the user taps the download affordance in
    /// `.available` stage. Wiring should call `PendingUpdate.startDownload()`.
    /// This single tap downloads, installs, and relaunches (one-button update).
    let onDownload: () -> Void

    /// Invoked when the user taps ✕ ("Skip this version") in `.available`
    /// stage. Wiring should call `PendingUpdate.skip()`, which routes to
    /// `driver.invokeSkip()` so Sparkle records THIS build as skipped and
    /// stops re-prompting for it; future versions still surface.
    let onSkip: () -> Void

    // MARK: - Testable computed properties

    /// Primary text label for the compact pill. `.downloading` is empty:
    /// the word "Updating" breaks ugly in the ~70pt right band ("U"/"pdating"),
    /// so the download/auto-install phase is icon-only.
    var primaryLabel: String {
        switch stage {
        case .available: "Update"
        case .downloading: ""
        case .readyToInstall: "v\(displayVersion)"
        }
    }

    /// Whether the hover-expanded layout should show a download affordance.
    var showsDownloadAffordance: Bool {
        hoverExpanded && stage == .available
    }

    /// Whether the hover-expanded layout should show a restart affordance.
    /// Always `false` — one-button update auto-installs, so there is no
    /// user-actionable restart step. Retained as a regression guard.
    var showsRestartAffordance: Bool {
        false
    }

    var body: some View {
        if showsDownloadAffordance {
            expandedDownloadBody
        } else {
            compactBody
        }
    }

    private var compactBody: some View {
        HStack(spacing: 4) {
            // `.downloading` shows a continuously-spinning loader (a render-
            // server rotation that survives the download-time main-thread
            // stalls — see `IslandUpdateSpinner`); the other stages show a
            // static SF Symbol. Both occupy the same 16pt icon slot so the
            // pill width does not jump between stages.
            if stage == .downloading {
                IslandUpdateSpinner()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: compactIcon)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // Render the label only when non-empty: `.downloading` is
            // icon-only, and laying out an empty Text would add stray padding
            // and an empty a11y node in the narrow band.
            if !primaryLabel.isEmpty {
                Text(primaryLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactAccessibilityLabel)
    }

    private var compactIcon: String {
        switch stage {
        case .available:
            IslandUpdateAvailablePillStyle.availableSystemImage
        case .downloading:
            IslandUpdateAvailablePillStyle.downloadingSystemImage
        case .readyToInstall:
            IslandUpdateAvailablePillStyle.readyToInstallSystemImage
        }
    }

    private var compactAccessibilityLabel: String {
        switch stage {
        case .available:
            "Update available, version \(displayVersion)"
        case .downloading:
            "Downloading update, version \(displayVersion)"
        case .readyToInstall:
            "Update ready, version \(displayVersion)"
        }
    }

    /// Hover-expanded layout for `.available` — [Update ↓] [✕ Skip this
    /// version]. The single ↓ tap downloads + auto-installs + relaunches;
    /// ✕ skips THIS build (future versions still prompt). There is no
    /// `.readyToInstall` hover layout anymore — install is automatic.
    private var expandedDownloadBody: some View {
        HStack(spacing: IslandUpdateAvailablePillStyle.actionSpacing) {
            IslandUpdatePillAction(
                label: "Update",
                systemImage: IslandUpdateAvailablePillStyle.downloadActionSystemImage,
                role: .primary,
                action: {
                    onDownload()
                }
            )
            IslandUpdatePillAction(
                label: "Skip this version",
                systemImage: IslandUpdateAvailablePillStyle.skipActionSystemImage,
                role: .secondary,
                action: {
                    onSkip()
                }
            )
        }
        .accessibilityElement(children: .contain)
    }
}

/// Internal icon action button used by `IslandUpdateAvailablePill`'s
/// hover-expanded layout. Sized to fit two side-by-side actions inside the
/// 70pt right band.
///
/// Click handling goes through `.onTapGesture` instead of `Button`
/// because `IslandPanel` is a non-key, nonactivating NSPanel; SwiftUI
/// `Button(action:)` does not reliably receive `mouseDown` events in
/// that context on macOS 15 — see the equivalent comment in
/// `IslandView.swift` for context on when
/// `.onTapGesture` vs `Button` is appropriate in this panel.
private struct IslandUpdatePillAction: View {
    enum Role { case primary, secondary }

    let label: String
    let systemImage: String
    let role: Role
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(
                size: iconFontSize,
                weight: .bold,
                design: .rounded
            ))
            .foregroundStyle(.white.opacity(role == .primary ? 0.96 : 0.82))
            .frame(
                width: IslandUpdateAvailablePillStyle.actionIconFrameSize,
                height: IslandUpdateAvailablePillStyle.actionIconFrameSize
            )
            .frame(
                width: IslandUpdateAvailablePillStyle.actionButtonSize,
                height: IslandUpdateAvailablePillStyle.actionButtonSize
            )
            .background(actionBackground)
            .contentShape(Circle())
            .scaleEffect(hovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    private var iconFontSize: CGFloat {
        switch role {
        case .primary:
            IslandUpdateAvailablePillStyle.primaryActionIconFontSize
        case .secondary:
            IslandUpdateAvailablePillStyle.secondaryActionIconFontSize
        }
    }

    @ViewBuilder
    private var actionBackground: some View {
        let fillOpacity: Double = {
            switch role {
            case .primary:
                hovering ? 0.24 : 0.18
            case .secondary:
                hovering ? 0.15 : 0.08
            }
        }()

        Circle()
            .fill(.white.opacity(fillOpacity))
            .overlay {
                Circle()
                    .stroke(
                        .white.opacity(role == .primary ? 0.28 : 0.18),
                        lineWidth: IslandUpdateAvailablePillStyle.actionStrokeLineWidth
                    )
            }
    }
}
