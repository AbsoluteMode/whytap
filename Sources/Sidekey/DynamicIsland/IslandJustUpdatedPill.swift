import SwiftUI

enum IslandJustUpdatedPillStyle {
    /// SF Symbol shown in the compact pill — the same checkmark family as the
    /// update pill's readyToInstall glyph, so "an update finished" reads
    /// consistently across the two surfaces.
    static let systemImage = "checkmark.circle.fill"
}

/// Right-band slot rendered in the Dynamic Island right after an update
/// applied (variant A). Driven by `AppState.justUpdatedVersion`; shown on the
/// first launch of the new binary and self-clears after ~5 s (owned by
/// `JustUpdatedIndicator`) or when the user taps it.
///
/// Compact-only: a ✓ + "Updated". The marketing version does not fit alongside
/// in the ~70 pt band (mirrors the update pill's "Updating" → icon-led
/// treatment), so it lives only in the accessibility label.
///
/// The whole pill taps to dismiss and goes through `.onTapGesture` (not
/// `Button`): `IslandPanel` is a non-key, nonactivating NSPanel and SwiftUI
/// `Button(action:)` does not reliably receive `mouseDown` there — the same
/// constraint documented on `IslandUpdateAvailablePill`. The closure is stored
/// plainly so `IslandJustUpdatedPillTests` can invoke it without ViewInspector.
struct IslandJustUpdatedPill: View {
    /// `CFBundleShortVersionString` that just applied (e.g. "1.18.0"). Announced
    /// by VoiceOver; not shown visually (no room in the band).
    let displayVersion: String

    /// Invoked when the user taps the pill. Wiring calls
    /// `UpdateController.dismissJustInstalledIndicator()`, which clears
    /// `AppState.justUpdatedVersion` and cancels the pending auto-dismiss.
    let onDismiss: () -> Void

    // MARK: - Testable computed properties

    /// Visible label — just the word; the version rides in the a11y label.
    var label: String { "Updated" }

    var accessibilityLabelText: String { "Updated to version \(displayVersion)" }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: IslandJustUpdatedPillStyle.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(.isButton)
    }
}
