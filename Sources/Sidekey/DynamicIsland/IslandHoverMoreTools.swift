import AppKit
import SwiftUI

// Unpinning a tool from the drawer and adding one back from More.
// WHY: .project-docs/decisions/2026-11-26-hover-unpin-and-more-tools.md

/// Keeps the drawer open after its tools changed. Removing a tile (by
/// throwing it out or from its menu), adding one from More or opening a
/// tool's menu changes the drawer's size or takes the pointer elsewhere, so
/// the pointer can end up outside the new hover zone without the person
/// meaning to leave. After such an edit the drawer closes only on a click
/// outside it (or Escape), or once the pointer has been outside, come back
/// in and left again. A pointer that was inside at the edit has to leave and
/// re-enter first: a hover edge the edit itself caused (a tile vanishing
/// under it, the menu closing over it) never counts as the return.
// WHY: .project-docs/decisions/2026-11-27-hover-drag-out-and-smooth-edits.md
struct IslandHoverEditHold: Equatable {
    enum Phase: Equatable {
        /// No edit to protect; the normal hover rules apply.
        case free
        /// Edited with the pointer over the hover; waiting for it to leave.
        case held
        /// The pointer is outside after the edit; waiting for it to return.
        case away
        /// The pointer came back after the edit; the next leave releases.
        case reentered
    }

    private(set) var phase: Phase = .free

    var holdsDrawer: Bool { phase != .free }

    /// The tools changed (or a tool's menu opened or closed), with the
    /// pointer over the hover or not.
    mutating func edited(pointerInside: Bool) { phase = pointerInside ? .held : .away }

    /// The pointer is, or is not, over the island and its drawer.
    mutating func pointer(inside: Bool) {
        switch phase {
        case .free: break
        case .held: if !inside { phase = .away }
        case .away: if inside { phase = .reentered }
        case .reentered: if !inside { phase = .free }
        }
    }

    /// A click outside, Escape, or the drawer closed for another reason.
    mutating func release() { phase = .free }
}

/// What a right-click or Control-click on a tool offers.
enum IslandHoverToolMenu {
    enum Item: Equatable {
        case remove(HoverTool)
        case add(HoverTool)
        /// Settings is the way back to every tool; shown disabled.
        case settingsStays

        var title: String {
            switch self {
            case .remove: return "Remove from Hover"
            case .add: return "Add to Hover"
            case .settingsStays: return "Settings always stays in Hover"
            }
        }

        var isEnabled: Bool { self != .settingsStays }
    }

    static func items(for target: IslandHoverHitTargetID, slots: [HoverTool]) -> [Item] {
        guard let tool = target.tool else { return [] }
        switch target.surface {
        case .tile:
            guard slots.contains(tool) else { return [] }
            return HoverLayoutStore.canUnpin(tool) ? [.remove(tool)] : [.settingsStays]
        case .moreTools:
            return HoverLayoutStore.canUnpin(tool) && !slots.contains(tool) ? [.add(tool)] : []
        default:
            return []
        }
    }

    @MainActor
    @discardableResult
    static func perform(_ item: Item, bridge: IslandHoverHitBridge) -> Bool {
        switch item {
        case .remove(let tool): return bridge.unpin(tool)
        case .add(let tool): return bridge.pin(tool)
        case .settingsStays: return false
        }
    }

    @MainActor
    static func menu(for items: [Item], bridge: IslandHoverHitBridge) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(IslandHoverToolMenuItem(item: item) { [weak bridge] in
                guard let bridge else { return }
                perform(item, bridge: bridge)
            })
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure; the island has no responder chain to
/// carry an action to.
final class IslandHoverToolMenuItem: NSMenuItem {
    private let run: () -> Void

    init(item: IslandHoverToolMenu.Item, run: @escaping () -> Void) {
        self.run = run
        super.init(title: item.title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = item.isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { run() }
}

/// Geometry of the More section; the drawer height and the AppKit hover band
/// both read it.
enum IslandHoverMoreToolsLayout {
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 6
    static let verticalInset: CGFloat = 8
    static let maxVisibleRows = 3
    /// "Every tool is in Hover." after the last one was added.
    static let emptyHeight: CGFloat = 40
    static let dividerHeight: CGFloat = 1

    static func rowCount(toolCount: Int) -> Int {
        toolCount <= 0 ? 0 : (toolCount - 1) / HoverLayoutStore.columns + 1
    }

    static func requiresScrolling(toolCount: Int) -> Bool {
        rowCount(toolCount: toolCount) > maxVisibleRows
    }

    /// The scroll viewport of the rows (or the empty message).
    static func listHeight(toolCount: Int) -> CGFloat {
        let rows = min(maxVisibleRows, rowCount(toolCount: toolCount))
        guard rows > 0 else { return emptyHeight }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing + verticalInset * 2
    }

    /// Everything the expanded section adds below the footer.
    static func sectionHeight(toolCount: Int) -> CGFloat {
        dividerHeight + listHeight(toolCount: toolCount)
    }
}

/// The drawer's bottom strip as one button: the whole strip shows and hides
/// More tools. It reads the hovered tool's description while the pointer is
/// on a tile (the strip itself is then not under the pointer), otherwise
/// "More tools", with the chevron at the right.
// WHY: .project-docs/decisions/2026-11-27-hover-drag-out-and-smooth-edits.md
@MainActor
struct IslandHoverMoreToolsStrip: View {
    let expanded: Bool
    /// The hovered tool's description, or nil.
    let description: String?
    @ObservedObject var bridge: IslandHoverHitBridge
    let hitContext: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    static let title = "More tools"

    var body: some View {
        let pressed = bridge.pressedID == .moreToolsToggle
        Button(action: action) {
            HStack(spacing: 6) {
                Text(description ?? Self.title)
                    .font(.system(size: description == nil ? 11 : 12, weight: description == nil ? .medium : .regular))
                    .foregroundStyle(.white.opacity(description == nil ? (hovering || pressed ? 0.92 : 0.66) : 0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.15), value: description)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering || pressed ? 0.9 : 0.6))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(pressed ? 0.16 : (hovering ? 0.08 : 0)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: expanded)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .islandHoverHitTarget(bridge: bridge, id: .moreToolsToggle, context: hitContext, action: action)
        .accessibilityLabel(Self.title)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the tools that are not in Hover")
    }
}

/// The tools that are not in the island. A click adds one at the end of the
/// island (before Settings); it leaves this list at once.
@MainActor
struct IslandHoverMoreToolsSection: View {
    let tools: [HoverTool]
    let panelWidth: CGFloat
    @ObservedObject var bridge: IslandHoverHitBridge
    let hitContext: String
    let onHover: (HoverTool, Bool) -> Void

    static let emptyMessage = "Every tool is in Hover."

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: IslandHoverMoreToolsLayout.dividerHeight)
            Group {
                if tools.isEmpty {
                    Text(Self.emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let rows = IslandHoverTileGridLayout(columnSpacing: IslandHoverControlsLayout.columnSpacing,
                                                         rowSpacing: IslandHoverMoreToolsLayout.rowSpacing,
                                                         rowHeight: IslandHoverMoreToolsLayout.rowHeight) {
                        ForEach(tools, id: \.self) { tool in
                            IslandHoverMoreToolRow(
                                tool: tool,
                                width: IslandHoverControlsLayout.tileWidth(panelWidth: panelWidth),
                                bridge: bridge,
                                hitContext: hitContext,
                                onHover: { onHover(tool, $0) }
                            )
                            .transition(IslandDropModeHoverPanel.tileTransition)
                        }
                    }
                    .padding(.horizontal, IslandHoverControlsLayout.horizontalInset)
                    .padding(.vertical, IslandHoverMoreToolsLayout.verticalInset)
                    // A scroll container only when the rows overflow; laid out
                    // directly it costs nothing extra per animation frame.
                    if IslandHoverMoreToolsLayout.requiresScrolling(toolCount: tools.count) {
                        ScrollView(.vertical) { rows }
                    } else {
                        rows.frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .frame(height: IslandHoverMoreToolsLayout.listHeight(toolCount: tools.count))
            .clipped()
            // Measure the clipped viewport, never the whole scrolling list.
            .islandHoverHitRegion(bridge: bridge, surface: .moreTools)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(IslandHoverMoreToolsStrip.title)
    }
}

@MainActor
private struct IslandHoverMoreToolRow: View {
    let tool: HoverTool
    let width: CGFloat
    @ObservedObject var bridge: IslandHoverHitBridge
    let hitContext: String
    let onHover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let info = HoverToolRegistry.info(for: tool)
        let id = IslandHoverHitTargetID(surface: .moreTools, tool: tool)
        let pressed = bridge.pressedID == id
        let add: () -> Void = { _ = bridge.pin(tool) }
        Button { add() } label: {
            HStack(spacing: 5) {
                Image(systemName: hovering ? "plus.circle.fill" : info.sfSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
                Text(info.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white.opacity(tool.isComingSoon ? 0.45 : 0.9))
            .padding(.horizontal, 6)
            .frame(width: width, height: IslandHoverMoreToolsLayout.rowHeight)
            .background(Capsule().fill(.white.opacity(pressed ? 0.24 : (hovering ? 0.16 : 0.08))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .islandHoverHitTarget(bridge: bridge, id: id, context: hitContext, action: { add() })
        .accessibilityLabel("Add \(info.title) to Hover")
        .accessibilityHint(info.description)
    }
}
