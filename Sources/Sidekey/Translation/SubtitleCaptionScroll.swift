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

    /// The caption's height on screen: how many pairs following lays out.
    @Published private(set) var viewportHeight: CGFloat = 0

    func setViewport(_ size: CGSize) {
        geometry.viewport = size
        if abs(viewportHeight - size.height) > 0.5 { viewportHeight = size.height }
    }

    /// Points a mouse wheel's line scrolls (a trackpad reports points).
    static let lineHeight: CGFloat = 24

    /// Scrolls by `delta` points: positive toward older pairs (content moves
    /// down), negative toward newer. Stops at the oldest pair; reaching the
    /// newest follows again, also when it is already in view.
    func scroll(by delta: CGFloat) {
        guard delta != 0, let placed = geometry.current, let first = placed.rows.first, let last = placed.rows.last else {
            return
        }
        let hiddenAbove = max(0, -first.top)
        let hiddenBelow = max(0, last.bottom - placed.height)
        let shift = min(max(delta, -hiddenBelow), hiddenAbove)
        if delta < 0, hiddenBelow + shift <= 0.5 {
            // Toward the newest with the newest in view (a taller window
            // brought it there): following again.
            follow()
            return
        }
        guard shift != 0 else { return }
        let rows = placed.rows.map { SubtitleCaptionGeometry.Row(id: $0.id, top: $0.top + shift, bottom: $0.bottom + shift) }
        geometry.record(.init(rows: rows, height: placed.height, width: placed.width))
        if hiddenBelow + shift <= 0.5 {
            follow()
        } else if let top = rows.first(where: { $0.bottom > 0 }) {
            anchor = Anchor(id: top.id, top: top.top)
        }
    }

    /// The pairs left (Clear, a new session or mode): nothing to scroll and
    /// no geometry of rows that are gone.
    func reset() {
        follow()
        geometry.clear()
    }

    /// How many of the newest pairs the caption lays out while following: at
    /// least `minimum`, and enough to fill `height` with the shortest rows, so
    /// every retained pair is either in view or above it, reachable by
    /// scrolling, at any window size.
    static func followedLimit(height: CGFloat, minimum: Int) -> Int {
        max(minimum, Int((height / shortestRow).rounded(.up)) + 2)
    }

    /// The lowest a pair row can be: one 13 pt line, its band and spacing.
    static let shortestRow: CGFloat = 26

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
///
/// SwiftUI may also place the rows for a measurement at another size (the
/// hosting view's ideal 146 pt, for example), so a placement is kept per
/// size and a scroll reads the one at the caption's size on screen,
/// `viewport`, reported by the caption itself.
final class SubtitleCaptionGeometry: @unchecked Sendable {
    struct Row: Equatable {
        var id: UUID
        var top: CGFloat
        var bottom: CGFloat
    }
    struct Placed: Equatable {
        var rows: [Row]
        var height: CGFloat
        var width: CGFloat = 0
    }
    private let lock = NSLock()
    private var placements: [Placed] = []
    private var _viewport: CGSize?

    /// The caption's size on screen.
    var viewport: CGSize? {
        get { lock.withLock { _viewport } }
        set { lock.withLock { _viewport = newValue } }
    }

    /// The last placement at the caption's on-screen size, or the last one
    /// before that size is known.
    var current: Placed? {
        lock.withLock {
            guard let viewport = _viewport else { return placements.last }
            return placements.last {
                abs($0.height - viewport.height) <= 0.5 && ($0.width == 0 || abs($0.width - viewport.width) <= 0.5)
            }
        }
    }

    /// The latest placement (tests and the last layout pass).
    var placed: Placed? { lock.withLock { placements.last } }

    func record(_ placed: Placed) {
        lock.withLock {
            placements.removeAll { abs($0.height - placed.height) <= 0.5 && abs($0.width - placed.width) <= 0.5 }
            placements.append(placed)
            if placements.count > 4 { placements.removeFirst(placements.count - 4) }
        }
    }

    func clear() { lock.withLock { placements.removeAll() } }
}

/// A caption row's identity, carried by its band so the layout can keep the
/// anchored pair in place.
struct SubtitleRowID: LayoutValueKey {
    static let defaultValue: UUID? = nil
}
