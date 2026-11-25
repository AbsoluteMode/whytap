import AppKit
import SwiftUI

/// Scrolling the subtitle overlay back through the session's pairs. While it
/// follows (the usual state) the newest pair stays at the bottom and new
/// lines push older ones up. A wheel or trackpad scroll toward older pairs
/// anchors the caption to the pair at its top: new lines then arrive below
/// without moving what is being read, and "Latest" brings the caption back.
/// Scrolling down to the newest pair follows again.
///
/// The panel's `sendEvent` hands scroll events here: the overlay is never key
/// and floats over another app's video, where a SwiftUI scroll view could
/// lose them to the window below and would not keep the steady layout.
// WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
@MainActor
final class SubtitleCaptionScroll: ObservableObject {
    /// The pair with `id` has its top `top` points below the caption's top.
    struct Anchor: Equatable {
        var id: UUID
        var top: CGFloat
    }

    /// nil: following the newest pair.
    @Published private(set) var anchor: Anchor?
    var isFollowing: Bool { anchor == nil }

    /// What the caption's layout last placed, for the next scroll.
    let geometry = SubtitleCaptionGeometry()

    /// Points a mouse wheel's line scrolls (a trackpad reports points).
    static let lineHeight: CGFloat = 24

    /// Scrolls by `delta` points: positive toward older pairs (content moves
    /// down), negative toward newer. Stops at the oldest pair; reaching the
    /// newest follows again.
    func scroll(by delta: CGFloat) {
        guard delta != 0, let placed = geometry.placed, let first = placed.rows.first, let last = placed.rows.last else {
            return
        }
        let hiddenAbove = max(0, -first.top)
        let hiddenBelow = max(0, last.bottom - placed.height)
        let shift = min(max(delta, -hiddenBelow), hiddenAbove)
        guard shift != 0 else { return }
        let rows = placed.rows.map { SubtitleCaptionGeometry.Row(id: $0.id, top: $0.top + shift, bottom: $0.bottom + shift) }
        geometry.placed = .init(rows: rows, height: placed.height)
        if hiddenBelow + shift <= 0.5 {
            follow()
        } else if let top = rows.first(where: { $0.bottom > 0 }) {
            anchor = Anchor(id: top.id, top: top.top)
        }
    }

    /// Scrolls by a scroll-wheel event's vertical delta.
    func scroll(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.lineHeight
        scroll(by: delta)
    }

    /// Back to the newest pair.
    func follow() {
        if anchor != nil { anchor = nil }
    }
}

/// Where the caption's rows were placed, in points from the caption's top
/// (y down). Written by `SteadyPairsLayout` while it places the rows, read
/// on the main thread by the next scroll.
final class SubtitleCaptionGeometry: @unchecked Sendable {
    struct Row: Equatable {
        var id: UUID
        var top: CGFloat
        var bottom: CGFloat
    }
    struct Placed: Equatable {
        var rows: [Row]
        var height: CGFloat
    }
    var placed: Placed?
}

/// A caption row's identity, carried by its band so the layout can keep the
/// anchored pair in place.
struct SubtitleRowID: LayoutValueKey {
    static let defaultValue: UUID? = nil
}
