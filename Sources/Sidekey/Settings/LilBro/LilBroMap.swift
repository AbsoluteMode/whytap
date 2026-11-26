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
    /// A row of a feature's "What it needs", by requirement id ("model.drop").
    case need(String)
}

/// A setup step a feature screen offers in its "What it needs" rows. Lil Bro
/// may press it only after the person says yes; pressing runs the same
/// `FeatureScreenContext.perform` as the row's own button.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
struct LilBroPressable: Equatable {
    /// The feature whose screen shows the row; an offer belongs to it alone.
    let feature: AppFeature
    /// The requirement id, also the row's `LilBroSpot.need` name.
    let id: String
    let action: FeatureSetupAction
    /// An optional step is never offered unasked.
    let optional: Bool
    /// The row shows a button for `action`. A model row that shows its
    /// picker instead ("Choose a model") is never pressed for the person.
    let hasButton: Bool
    let perform: @MainActor (FeatureSetupAction) -> Void

    static func == (lhs: LilBroPressable, rhs: LilBroPressable) -> Bool {
        lhs.feature == rhs.feature && lhs.id == rhs.id && lhs.action == rhs.action
            && lhs.optional == rhs.optional && lhs.hasButton == rhs.hasButton
    }

    /// Whether this is still the step the person said yes to.
    func isSameStep(as other: LilBroPressable) -> Bool {
        feature == other.feature && id == other.id && action == other.action
    }

    /// The rule `FeatureRequirementRow` uses for its button: every row but a
    /// model row, where only the on-device and key steps are buttons next to
    /// the model picker.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md
    static func rowHasButton(_ check: FeatureCheck, action: FeatureSetupAction) -> Bool {
        guard case .model = check.requirement.kind else { return true }
        switch action {
        case .downloadOnDeviceModel, .useOnDeviceModel, .addKey, .fixKey, .addOpenAIKey: return true
        default: return false
        }
    }
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

struct LilBroPressablesKey: PreferenceKey {
    static let defaultValue: [LilBroPressable] = []
    static func reduce(value: inout [LilBroPressable], nextValue: () -> [LilBroPressable]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// A "What it needs" row of `feature`'s screen: where it is, and the step
    /// it offers while unmet.
    func lilBroNeed(_ check: FeatureCheck, of feature: AppFeature,
                    perform: @escaping @MainActor (FeatureSetupAction) -> Void) -> some View {
        var offered: [LilBroPressable] = []
        if case .unmet(_, let action?) = check.state {
            offered = [LilBroPressable(feature: feature, id: check.id, action: action,
                                       optional: check.requirement.optional,
                                       hasButton: LilBroPressable.rowHasButton(check, action: action),
                                       perform: perform)]
        }
        return lilBroSpot(.need(check.id))
            .preference(key: LilBroPressablesKey.self, value: offered)
    }

    /// Tells Lil Bro where this view is, by name.
    func lilBroSpot(_ spot: LilBroSpot) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: LilBroSpotsKey.self,
                                   value: [spot: proxy.frame(in: .named(LilBroSpace.name))])
        })
    }

    /// Tells Lil Bro this view is a block he can stand on.
    func lilBroBlock() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: LilBroBlocksKey.self,
                                   value: [proxy.frame(in: .named(LilBroSpace.name))])
        })
    }
}
