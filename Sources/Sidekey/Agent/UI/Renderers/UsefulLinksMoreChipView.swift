import AppKit
import SwiftUI

/// Page-down affordance shown below the three-row useful_links viewport
/// when the client has more links available below the fold.
struct UsefulLinksMoreChipView: View {
    let hiddenCount: Int
    let action: () -> Void

    @State private var hovered = false

    private static let verticalPadding: CGFloat = 4
    private static let minHeight = UsefulLinkChipView.iconSize + verticalPadding * 2

    var body: some View {
        Button(action: action) {
            Text("+\(hiddenCount) more")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, Self.verticalPadding)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.minHeight,
                    alignment: .leading
                )
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.thickMaterial)
                        if hovered {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            hovered = isInside
            if isInside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("+\(hiddenCount) more links")
        .accessibilityHint("Scrolls useful links down")
        .accessibilityAddTraits(.isButton)
    }
}
