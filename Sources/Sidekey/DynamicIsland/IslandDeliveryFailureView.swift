import AppKit
import SwiftUI

/// The failed Drop face hugs its message and two independent actions. The
/// host's transparent window reservation never determines the black surface.
// WHY: docs/DESIGN.md — Failed dictation: Close and content width.
struct IslandDeliveryFailureView: View {
    let message: String
    let height: CGFloat
    var hitBridge: IslandHoverHitBridge? = nil
    let onRetry: () -> Void
    let onDismiss: () -> Void

    static let horizontalPadding: CGFloat = 12
    static let spacing: CGFloat = 8
    static let controlHeight: CGFloat = 22
    static let closeWidth: CGFloat = 22
    static let retryIconWidth: CGFloat = 12
    static let retryLabel = "Retry"
    static var retryWidth: CGFloat {
        ceil((retryLabel as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ]).width) + retryIconWidth + 4 + 16
    }

    /// Shared by the rendered face, black surface and host hit zone. Long
    /// errors truncate the message; both controls keep their full footprint.
    static func faceWidth(message: String) -> CGFloat {
        let textWidth = ceil((message as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]).width)
        return min(IslandFrameLayout.agentWingDeliveryFailedWidth,
                   textWidth + horizontalPadding * 2 + spacing * 2 + retryWidth + closeWidth)
    }

    var body: some View {
        Group {
            if let hitBridge {
                content.islandHoverHitRegion(bridge: hitBridge, surface: .deliveryFailure)
            } else { content }
        }
    }

    private var content: some View {
        HStack(spacing: Self.spacing) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            DeliveryFailureAction(label: "Retry delivery", symbol: "arrow.clockwise",
                width: Self.retryWidth, hitBridge: hitBridge, hitAction: .retry, action: onRetry)
            DeliveryFailureAction(label: "Dismiss failed dictation", symbol: "xmark",
                width: Self.closeWidth, hitBridge: hitBridge, hitAction: .dismiss, action: onDismiss)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(width: Self.faceWidth(message: message), height: height)
        .accessibilityElement(children: .contain)
    }
}

private struct DeliveryFailureAction: View {
    let label: String
    let symbol: String
    let width: CGFloat
    let hitBridge: IslandHoverHitBridge?
    let hitAction: IslandHoverHitTargetID.DeliveryFailureAction
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Group {
            if let hitBridge, enabled {
                button.islandHoverHitTarget(bridge: hitBridge, id: .init(deliveryFailure: hitAction),
                    context: hitBridge.context, action: action)
            } else { button }
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: IslandDeliveryFailureView.retryIconWidth)
                if hitAction == .retry {
                    Text(IslandDeliveryFailureView.retryLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: width, height: IslandDeliveryFailureView.controlHeight)
        }
        .buttonStyle(DeliveryFailureActionStyle(focused: focused))
        .focused($focused)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct DeliveryFailureActionStyle: ButtonStyle {
    let focused: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.islandHoverNativePressed) private var nativePressed

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(.white.opacity(enabled
                ? ((configuration.isPressed || nativePressed) ? 0.36 : hovered ? 0.26 : 0.16) : 0.05)))
            .overlay(Capsule().strokeBorder(.white.opacity(enabled && focused ? 0.9 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = enabled && $0 }
            .onChange(of: enabled) { _, value in if !value { hovered = false } }
    }
}
