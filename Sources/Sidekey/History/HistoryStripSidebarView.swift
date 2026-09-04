import SwiftUI

/// Vertical filter sidebar for the unified history strip (ROO-208).
///
/// Renders three buttons — Clipboard / Drop / Agent — stacked top-to-
/// bottom on the strip's left edge. The active filter draws as a
/// highlighted pill so the user can tell at a glance which content set
/// the strip is showing. Tapping a filter calls back through
/// `onSelect` so the host can drive `HistoryStripController.setFilter`.
///
/// Dark-glass aesthetic matches the cards' backdrop. Buttons are real
/// SwiftUI `Button`s (not tap-gestures on rectangles) so VoiceOver picks
/// up the trait, keyboard nav still works, and the focus ring renders
/// without extra plumbing.
struct HistoryStripSidebarView: View {
    /// Top-to-bottom order of the filter buttons. Pinned as a static
    /// constant so the visual order can't drift from the spec without
    /// flipping a test.
    static let filterOrder: [HistoryStripMode] = [.clipboard, .drop, .agent]

    /// First-open default. Mirrors `HistoryStripController.toggleUnified`
    /// — pinned here so the view's own default-active state and the
    /// controller's first-open behavior can't disagree silently.
    static let defaultFilter: HistoryStripMode = .clipboard

    /// User-facing label per filter. Title-case follows the project's
    /// hotkey-UI capitalization rule (`docs/hotkey.md` — "Capitalize
    /// labels").
    static func title(for filter: HistoryStripMode) -> String {
        switch filter {
        case .clipboard: return "Clipboard"
        case .drop:      return "Drop"
        case .agent:     return "Agent"
        }
    }

    /// SF Symbol name per filter. Reuses the same glyph family already
    /// used in `HistoryStripView.emptyStateIcon(for:)` so the sidebar
    /// icon and empty-state icon read as the same concept.
    static func iconName(for filter: HistoryStripMode) -> String {
        switch filter {
        case .clipboard: return "doc.on.clipboard"
        case .drop:      return "mic"
        case .agent:     return "sparkles"
        }
    }

    let activeFilter: HistoryStripMode
    /// Invoked when the user taps any of the three filter buttons. The
    /// host (`HistoryStripView`) wires this to
    /// `HistoryStripController.setFilter(_:)`. Default no-op so previews
    /// + smoke tests can construct the view without a controller.
    let onSelect: (HistoryStripMode) -> Void

    init(
        activeFilter: HistoryStripMode,
        onSelect: @escaping (HistoryStripMode) -> Void = { _ in }
    ) {
        self.activeFilter = activeFilter
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.filterOrder, id: \.self) { filter in
                filterButton(for: filter)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: Self.sidebarWidth, alignment: .leading)
        .background {
            // Subtle dark-glass column so the sidebar reads as a
            // distinct surface from the cards' transparent backdrop
            // without painting a hard divider line.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.black.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History filter")
    }

    /// Outer width of the sidebar column. Sized so the longest label
    /// ("Clipboard") fits at the system body font without truncation
    /// while keeping the cards' area as wide as possible.
    static let sidebarWidth: CGFloat = 110

    @ViewBuilder
    private func filterButton(for filter: HistoryStripMode) -> some View {
        let isActive = (filter == activeFilter)
        Button(action: { onSelect(filter) }) {
            HStack(spacing: 8) {
                Image(systemName: Self.iconName(for: filter))
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(Self.title(for: filter))
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.62))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Visible indicator combines fill, border, AND icon
                // weight — not color alone, so the active state remains
                // distinguishable for users with limited color vision
                // (WCAG SC 1.4.1 "use of color").
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.18) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isActive ? Color.white.opacity(0.28) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.title(for: filter))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}
