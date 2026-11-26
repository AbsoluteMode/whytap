import SwiftUI

/// A place in the Settings window that Lil Bro knows by name: where he lives,
/// a sidebar row, a feature's row in the list, the detail pane.
enum LilBroSpot: Hashable {
    /// The "Lil Bro" entry at the bottom of the sidebar: his home.
    case home
    case sidebar
    case pane
    case tab(SettingsWindowTab)
    case feature(AppFeature)
    /// One row of a tab he can lead to (`LilBroRow.id`).
    case row(String)
    /// What opens one part of a tab, by the screen it shows
    /// (`apiAndModels/keys`: the API keys tab; `toolbox/vocab`: the Vocab tile).
    case part(String)
}

/// The window as Lil Bro sees it: named spots and the blocks (cards) he can
/// stand on, all in the Settings shell's coordinates. Built from what the
/// views report about themselves, so it follows every screen without those
/// screens knowing about him.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
struct LilBroMap: Equatable {
    var bounds: CGRect = .zero
    var spots: [LilBroSpot: CGRect] = [:]
    /// Every card on screen, visible or scrolled away.
    var blocks: [CGRect] = []

    /// Where a block's top edge can be stood on: inside the visible pane or
    /// sidebar, not under the title bar or below the bottom.
    var platforms: [CGRect] {
        let areas = [spots[.pane], spots[.sidebar]].compactMap { $0 }
        return blocks.compactMap { block in
            for area in areas where block.minY >= area.minY + 6 && block.minY <= area.maxY - 40 {
                let clipped = CGRect(x: max(block.minX, area.minX), y: block.minY,
                                     width: min(block.maxX, area.maxX) - max(block.minX, area.minX),
                                     height: block.height)
                if clipped.width >= 60 { return clipped }
            }
            return nil
        }
    }

    /// The top edge of a spot, if it is on screen.
    func visible(_ spot: LilBroSpot) -> CGRect? {
        guard let rect = spots[spot], rect.width > 0 else { return nil }
        let areas = [spots[.pane], spots[.sidebar]].compactMap { $0 }
        guard areas.isEmpty || areas.contains(where: { rect.minY >= $0.minY + 2 && rect.minY <= $0.maxY - 20 })
        else { return nil }
        return rect
    }

    /// The line he stands on at home: the top of his sidebar entry.
    var home: CGRect? { spots[.home] }

    /// Where he waits at home: on the entry, near its right end.
    var homeStand: CGPoint {
        guard let home else { return CGPoint(x: 60, y: max(bounds.maxY - 10, 0)) }
        return CGPoint(x: home.maxX - 34, y: home.minY + 1)
    }

    /// The lowest line he can always drop to: the bottom of the window.
    var floorY: CGFloat { max(bounds.maxY - 6, 0) }

    /// The platform under a point he stands on, if any.
    func platform(under point: CGPoint) -> CGRect? {
        if let home, abs(home.minY - point.y) < 4, point.x >= home.minX - 2, point.x <= home.maxX + 2 { return home }
        return platforms.first { abs($0.minY - point.y) < 4 && point.x >= $0.minX - 2 && point.x <= $0.maxX + 2 }
    }
}

enum LilBroSpace {
    static let name = "lilBro.window"
}

struct LilBroSpotsKey: PreferenceKey {
    static let defaultValue: [LilBroSpot: CGRect] = [:]
    static func reduce(value: inout [LilBroSpot: CGRect], nextValue: () -> [LilBroSpot: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LilBroBlocksKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Tells Lil Bro where this view is, by name.
    func lilBroSpot(_ spot: LilBroSpot) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: LilBroSpotsKey.self,
                                   value: [spot: proxy.frame(in: .named(LilBroSpace.name))])
        })
    }

    /// A row Lil Bro can lead to: scrolled to by its id, and while it is the
    /// one he brought the person to, a block he stands on and outlines.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 12, REV 14)
    func lilBroRow(_ id: String) -> some View {
        modifier(LilBroRowModifier(id: id))
    }

    /// A Settings row (`MacRow`, `HotkeySettingRow`, `ConcreteSettingPicker`)
    /// with its title: if the catalog lists it on this screen, Lil Bro can
    /// lead to it; either way the row says it was drawn, so the coverage
    /// test sees a row missing from the catalog. Outside Settings it does
    /// nothing.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 14)
    func lilBroCatalogRow(_ title: String) -> some View {
        modifier(LilBroCatalogRowModifier(title: title))
    }

    /// `lilBroCatalogRow(title)`, or nothing for nil.
    @ViewBuilder
    func lilBroCatalogRow(_ title: String?) -> some View {
        if let title { lilBroCatalogRow(title) } else { self }
    }

    /// Rows inside are data (one per app, tool, server or dashboard), not
    /// settings of their own: they are not listed and Lil Bro does not lead
    /// to them one by one.
    func lilBroItems() -> some View {
        environment(\.lilBroItems, true)
    }

    /// A control (switch, pop-up, segments, menu) says where it was drawn:
    /// inside a row or loose on a Settings screen. Loose ones fail
    /// `LilBroRowCoverageTests`.
    func lilBroControl(_ label: String) -> some View {
        modifier(LilBroControlModifier(label: label))
    }

    /// Tells Lil Bro this view is a block he can stand on.
    func lilBroBlock() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: LilBroBlocksKey.self,
                                   value: [proxy.frame(in: .named(LilBroSpace.name))])
        })
    }
}

// MARK: Rows on every Settings screen (REV 14)

/// What the Settings window tells its rows: the screen they are on (`tab` or
/// `features/feature`, as `LilBroRow.screen`), the row Lil Bro led to and
/// how to scroll there.
extension EnvironmentValues {
    var lilBroScreen: String? {
        get { self[LilBroScreenKey.self] }
        set { self[LilBroScreenKey.self] = newValue }
    }
    var lilBroFocusedRow: String? {
        get { self[LilBroFocusedRowKey.self] }
        set { self[LilBroFocusedRowKey.self] = newValue }
    }
    var lilBroScroll: LilBroScroll {
        get { self[LilBroScrollKey.self] }
        set { self[LilBroScrollKey.self] = newValue }
    }
    var lilBroItems: Bool {
        get { self[LilBroItemsKey.self] }
        set { self[LilBroItemsKey.self] = newValue }
    }
    var lilBroInRow: Bool {
        get { self[LilBroInRowKey.self] }
        set { self[LilBroInRowKey.self] = newValue }
    }
}

private struct LilBroScreenKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct LilBroFocusedRowKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct LilBroScrollKey: EnvironmentKey { static let defaultValue = LilBroScroll() }
private struct LilBroItemsKey: EnvironmentKey { static let defaultValue = false }
private struct LilBroInRowKey: EnvironmentKey { static let defaultValue = false }

/// Scrolls the Settings pane to a row by its id: into the middle, or a row
/// taller than that to its top so its top edge stays in view.
struct LilBroScroll {
    var to: @MainActor (String, UnitPoint) -> Void = { _, _ in }
}

/// A row drawn on a Settings screen, as the coverage test sees it.
struct LilBroSeenRow: Hashable {
    let screen: String
    let title: String
    /// Its catalog entry; nil when the catalog does not list it.
    let id: String?
    /// One of a list of data rows (`lilBroItems`), not a setting.
    let item: Bool
}

/// A control drawn on a Settings screen.
struct LilBroSeenControl: Hashable {
    let screen: String
    let label: String
    let inRow: Bool
}

struct LilBroSeenRowsKey: PreferenceKey {
    static let defaultValue: [LilBroSeenRow] = []
    static func reduce(value: inout [LilBroSeenRow], nextValue: () -> [LilBroSeenRow]) {
        value.append(contentsOf: nextValue())
    }
}

struct LilBroSeenControlsKey: PreferenceKey {
    static let defaultValue: [LilBroSeenControl] = []
    static func reduce(value: inout [LilBroSeenControl], nextValue: () -> [LilBroSeenControl]) {
        value.append(contentsOf: nextValue())
    }
}

private struct LilBroRowModifier: ViewModifier {
    let id: String
    @Environment(\.lilBroFocusedRow) private var focused
    @Environment(\.lilBroScroll) private var scroll
    @State private var height: CGFloat = 0

    /// A tall row (API keys, a Toolbox tool, Costs) goes to the top: in the
    /// middle its top edge, where he stands, would be above the pane.
    private var anchor: UnitPoint { height > 220 ? UnitPoint(x: 0.5, y: 0.02) : .center }

    func body(content: Content) -> some View {
        content
            .id(id)
            .lilBroSpot(.row(id))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: LilBroBlocksKey.self,
                                       value: focused == id ? [proxy.frame(in: .named(LilBroSpace.name))] : [])
                    .onAppear { height = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, now in height = now }
            })
            // The pane scrolls the row Lil Bro led to into view, also when its
            // screen has just opened.
            // After the row has measured itself.
            .onAppear { if focused == id { DispatchQueue.main.async { scroll.to(id, anchor) } } }
            .onChange(of: focused) { _, now in if now == id { scroll.to(id, anchor) } }
    }
}

private struct LilBroCatalogRowModifier: ViewModifier {
    let title: String
    @Environment(\.lilBroScreen) private var screen
    @Environment(\.lilBroItems) private var items

    func body(content: Content) -> some View {
        let row = screen.flatMap { items ? nil : LilBroRow.at(screen: $0, title: title) }
        Group {
            if let row {
                content.lilBroRow(row.id)
            } else {
                content
            }
        }
        .environment(\.lilBroInRow, true)
        .transformPreference(LilBroSeenRowsKey.self) { seen in
            if let screen { seen.append(LilBroSeenRow(screen: screen, title: title, id: row?.id, item: items)) }
        }
    }
}

private struct LilBroControlModifier: ViewModifier {
    let label: String
    @Environment(\.lilBroScreen) private var screen
    @Environment(\.lilBroInRow) private var inRow
    @Environment(\.lilBroItems) private var items

    func body(content: Content) -> some View {
        content.transformPreference(LilBroSeenControlsKey.self) { seen in
            if let screen { seen.append(LilBroSeenControl(screen: screen, label: label, inRow: inRow || items)) }
        }
    }
}
