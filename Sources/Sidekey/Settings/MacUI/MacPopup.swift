import SwiftUI

/// Shared geometry for SwiftUI menus and the screenshot editor's native popups.
enum MacPopupMetrics {
    static let height: CGFloat = 30
    static let radius: CGFloat = 8
    static let horizontalPadding: CGFloat = 10
    static let arrowWidth: CGFloat = 10
    static let spacing: CGFloat = 12
    static let fontSize: CGFloat = 12
}

/// Settings and floating tools follow macOS appearance with their own surface roles.
enum MacPopupAppearance {
    case settings, adaptive

    var text: Color { self == .settings ? MacSettingsTheme.text : .primary }
    var secondary: Color { self == .settings ? MacSettingsTheme.text2 : .secondary }
    var background: Color { self == .settings ? MacSettingsTheme.controlBg : Color(nsColor: .controlBackgroundColor) }
    var border: Color { self == .settings ? MacSettingsTheme.sepStrong : Color.primary.opacity(0.08) }
}

/// One compact label with a single down chevron. The menu itself stays native.
// WHY: .project-docs/decisions/2026-10-20-compact-selection-menus.md
struct MacMenu<Content: View>: View {
    let title: String
    var minWidth: CGFloat = 90
    var maxWidth: CGFloat? = 300
    var appearance: MacPopupAppearance = .settings
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            MacPopupLabel(title: title, minWidth: minWidth, maxWidth: maxWidth, appearance: appearance)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityValue(title)
        .help(title)
        .lilBroControl(title)
    }
}

/// Also used by the searchable model popover, keeping its closed control identical.
struct MacPopupLabel: View {
    let title: String
    var minWidth: CGFloat = 90
    var maxWidth: CGFloat? = 300
    var appearance: MacPopupAppearance = .settings
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: MacPopupMetrics.spacing) {
            Text(title)
                .font(.system(size: MacPopupMetrics.fontSize, weight: .medium))
                .foregroundStyle(appearance.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(appearance.secondary)
                .frame(width: MacPopupMetrics.arrowWidth)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, MacPopupMetrics.horizontalPadding)
        .frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: MacPopupMetrics.height,
               maxHeight: MacPopupMetrics.height)
        .background(appearance.background, in: RoundedRectangle(cornerRadius: MacPopupMetrics.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MacPopupMetrics.radius, style: .continuous)
                .strokeBorder(appearance.border, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: MacPopupMetrics.radius, style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Value selection using the same label as richer model/provider menus.
struct MacPopup<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    let items: [Item]
    @Binding var selection: Value
    var minWidth: CGFloat = 90
    var maxWidth: CGFloat? = 300
    var appearance: MacPopupAppearance = .settings

    private var currentLabel: String {
        items.first { $0.value == selection }?.label ?? "Choose…"
    }

    var body: some View {
        MacMenu(title: currentLabel, minWidth: minWidth, maxWidth: maxWidth, appearance: appearance) {
            ForEach(items) { item in
                Button {
                    selection = item.value
                } label: {
                    if item.value == selection {
                        Label(item.label, systemImage: "checkmark")
                    } else {
                        Text(item.label)
                    }
                }
            }
        }
    }
}
