import SwiftUI

struct IslandHoverNavigationContext {
    let bridge: IslandHoverHitBridge
    let context: String
}

private struct IslandHoverNavigationKey: EnvironmentKey {
    static let defaultValue: IslandHoverNavigationContext? = nil
}

extension EnvironmentValues {
    var islandHoverNavigation: IslandHoverNavigationContext? {
        get { self[IslandHoverNavigationKey.self] }
        set { self[IslandHoverNavigationKey.self] = newValue }
    }
}

/// Keep the native Button for keyboard/accessibility, and report its complete
/// label bounds to the window's existing first-mouse dispatcher. The destination
/// identifies the current page so a press cannot navigate a replacement page.
struct IslandHoverBackButton: View {
    let destination: String
    var title: String? = nil
    var accessibilityLabel = "Back to tools"
    var width: CGFloat = 32
    var height: CGFloat = 26
    let action: () -> Void
    @Environment(\.islandHoverNavigation) private var navigation
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let navigation, enabled {
                button.islandHoverHitTarget(bridge: navigation.bridge, id: .init(back: destination),
                    context: navigation.context, action: action)
            } else {
                button
            }
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                if let title { Text(title).lineLimit(1) }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandHoverBackButtonStyle(focused: focused))
        .focused($focused)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

private struct IslandHoverBackButtonStyle: ButtonStyle {
    let focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.islandHoverNativePressed) private var nativePressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.96))
            .background(IslandHoverBackSurface(hovered: hovered,
                pressed: configuration.isPressed || nativePressed, focused: focused, enabled: enabled))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovered = enabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: enabled && hovered)
    }
}

struct IslandHoverBackSurface: View {
    var hovered = false
    var pressed = false
    var focused = false
    var enabled = true

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(.white.opacity(enabled && pressed ? 0.23 : enabled && hovered ? 0.15 : 0.06))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(enabled && focused ? 0.85 : 0), lineWidth: 1.5))
            .allowsHitTesting(false)
    }
}
