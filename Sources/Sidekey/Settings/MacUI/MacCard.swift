import SwiftUI

/// iOS-style inset group. Rows share one surface with quiet, inset separators.
struct MacCard<Content: View>: View {
    var needsSetup: Bool = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                MacSettingsTheme.bgCard,
                in: RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                    .strokeBorder(needsSetup ? MacSettingsTheme.setupOutline : MacSettingsTheme.sep,
                                  lineWidth: needsSetup ? 1 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous))
            .shadow(color: needsSetup && !reduceTransparency
                    ? MacSettingsTheme.setupGlow.opacity(colorScheme == .dark ? 0.18 : 0.12) : .clear,
                    radius: 5)
    }
}

/// One row inside a `MacCard`: optional leading view, title (+ subtitle), trailing control.
/// Mirrors the mockup's `.mac-row` (min-height 42, padding 9×14).
struct MacRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 11) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 42)
    }
}

extension MacRow where Leading == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}

/// A full-point inset divider with breathing room between adjacent settings.
struct MacRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(MacSettingsTheme.rowSeparator)
            .frame(height: 1)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
    }
}

/// Small caption above a card, mirroring the mockup's `.group-title`.
struct MacGroupTitle: View {
    let title: String
    var trailing: String?

    init(title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text2)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text3)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 7)
    }
}
