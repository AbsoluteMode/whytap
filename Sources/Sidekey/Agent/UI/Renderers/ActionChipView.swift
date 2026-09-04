import AppKit
import SwiftUI

/// Pure presentation model for one `ActionItem` chip: which icon to show, what
/// title to render, and which action a click on the chip performs. Split out
/// from the view so the per-type mapping is unit-testable without rendering.
///
/// - link: routes to the rich favicon/provider chip (`UsefulLinkChipView`), so
///   it carries no SF Symbol of its own (`symbolName == nil`, `isLink == true`).
///   Primary click opens the URL.
/// - path: a file icon (`doc`); title is the description, else the path's last
///   component. Primary click opens the file in its default app.
/// - copy: a text/snippet icon (`text.alignleft`); title is the description,
///   else a single-line preview of the text. Primary click inserts (no open).
struct ActionChipPresentation: Equatable {
    let item: ActionItem

    /// Which action a click on the chip performs: link/path open, copy inserts.
    var primaryAction: ActionKind {
        item.availableActions.contains(.open) ? .open : .insert
    }

    /// `true` when the item is a link — links render via `UsefulLinkChipView`,
    /// reusing the favicon/provider machinery.
    var isLink: Bool {
        if case .link = item { return true }
        return false
    }

    /// SF Symbol for non-link items; `nil` for links (they use a favicon /
    /// brand asset instead).
    var symbolName: String? {
        switch item {
        case .link:
            return nil
        case .path:
            return "doc"
        case .copy:
            return "text.alignleft"
        }
    }

    /// Title shown on the chip. Links / paths / copy all prefer their explicit
    /// description; a path falls back to its basename, copy to a text preview.
    var title: String {
        switch item {
        case .link(_, let description, _):
            return description
        case .path(let path, let description):
            if let description, !description.isEmpty { return description }
            let basename = (path as NSString).lastPathComponent
            return basename.isEmpty ? path : basename
        case .copy(let text, let description):
            if let description, !description.isEmpty { return description }
            return text
        }
    }
}

/// Compact pill ("chip") for one `ActionItem`. Link items defer to the existing
/// `UsefulLinkChipView` (favicon / provider icon + open-in-browser). Path and
/// copy items render here directly: an SF Symbol icon + title, with a primary
/// click that opens the file (path) or inserts the text (copy).
///
/// Opening a path is a Finder-style launch in the default app — it NEVER runs
/// the path's contents. Copy chips have no open affordance at all; their click
/// inserts.
struct ActionChipView: View {
    let item: ActionItem
    /// Invoked when the chip's primary action is "open" (link / path). The host
    /// wires this to `NSWorkspace`-style open; the default opens `openTarget`.
    var onOpen: (ActionItem) -> Void
    /// Invoked when the chip's primary action is "insert" (copy). The host
    /// wires this to the paste path; default is a no-op (click still safe).
    var onInsert: (ActionItem) -> Void

    @State private var hovered = false

    /// Icon column width — matches `UsefulLinkChipView.iconSize` so link and
    /// non-link chips line up in a mixed column.
    private static let iconSize = UsefulLinkChipView.iconSize

    init(
        item: ActionItem,
        onOpen: @escaping (ActionItem) -> Void = { item in
            if let target = item.openTarget { NSWorkspace.shared.open(target) }
        },
        onInsert: @escaping (ActionItem) -> Void = { _ in }
    ) {
        self.item = item
        self.onOpen = onOpen
        self.onInsert = onInsert
    }

    private var presentation: ActionChipPresentation {
        ActionChipPresentation(item: item)
    }

    var body: some View {
        // Link items reuse the rich favicon/provider chip wholesale so the
        // existing brand-icon behaviour and accessibility carry over unchanged.
        if case let .link(url, description, provider) = item {
            UsefulLinkChipView(
                link: UsefulLink(url: url, description: description, provider: provider)
            )
        } else {
            nonLinkChip
        }
    }

    private var nonLinkChip: some View {
        Button(action: primaryAction) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: presentation.symbolName ?? "doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                Text(presentation.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private func primaryAction() {
        switch presentation.primaryAction {
        case .open:
            onOpen(item)
        case .insert:
            onInsert(item)
        }
    }

    private var accessibilityLabel: String {
        switch presentation.primaryAction {
        case .open:
            return "\(presentation.title). Open"
        case .insert:
            return "\(presentation.title). Insert"
        }
    }
}
