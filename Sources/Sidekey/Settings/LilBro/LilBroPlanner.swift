import CoreGraphics
import Foundation

/// One step of Lil Bro's way across the window. Points are where his feet are.
enum LilBroMove: Equatable {
    /// Run (or stroll) along the block he stands on.
    case run(to: CGPoint, stroll: Bool = false)
    /// Jump in an arc to another block's top edge.
    case jump(to: CGPoint)
    /// Take out the ladder at `from` and climb it to `to` (same x).
    case ladder(from: CGPoint, to: CGPoint)
    /// Reduced motion: appear there.
    case appear(at: CGPoint)
}

/// How Lil Bro gets from where he stands to a point on a block: run along his
/// block, jump to a near block, and fetch the ladder when the block is higher
/// than he can jump. Pure, so the route is tested without drawing.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
enum LilBroPlanner {
    /// The highest he jumps, in points.
    static let maxJumpRise: CGFloat = 90
    /// The farthest he jumps across without running first.
    static let maxJumpAcross: CGFloat = 280

    static func route(from start: CGPoint, to goal: CGPoint, in map: LilBroMap,
                      reduceMotion: Bool) -> [LilBroMove] {
        if hypot(goal.x - start.x, goal.y - start.y) < 2 { return [] }
        if reduceMotion { return [.appear(at: goal)] }
        let current = map.platform(under: start)
        if abs(goal.y - start.y) < 4, let current, goal.x >= current.minX - 2, goal.x <= current.maxX + 2 {
            return [.run(to: goal)]
        }

        var moves: [LilBroMove] = []
        var here = start
        let rise = start.y - goal.y
        let goalBlock = map.platform(under: goal)

        if rise > maxJumpRise {
            // Too high to jump: stand under the goal, prop the ladder, climb.
            let span = goalBlock.map { ($0.minX + 12)...max($0.minX + 12, $0.maxX - 24) }
                ?? (goal.x - 1)...(goal.x + 1)
            if let current, let foot = overlap(current, span) {
                let ladderX = clamp(goal.x - 8, to: foot)
                if abs(ladderX - here.x) > 2 { moves.append(.run(to: CGPoint(x: ladderX, y: here.y))) }
                here.x = ladderX
            } else {
                // Not under it: drop to the window floor beneath the goal first.
                let ladderX = clamp(goal.x - 8, to: span)
                let floor = CGPoint(x: ladderX, y: map.floorY)
                if abs(floor.y - here.y) >= 4 || abs(floor.x - here.x) > 2 {
                    moves.append(contentsOf: approach(from: here, to: floor, current: current))
                }
                here = floor
            }
            let top = CGPoint(x: here.x, y: goal.y)
            moves.append(.ladder(from: here, to: top))
            here = top
            if abs(goal.x - here.x) > 2 { moves.append(.run(to: goal)) }
            return moves
        }
        moves.append(contentsOf: approach(from: here, to: goal, current: current))
        return moves
    }

    /// A jump to `goal`, run first to the edge of his block if the gap is wide.
    private static func approach(from start: CGPoint, to goal: CGPoint, current: CGRect?) -> [LilBroMove] {
        var moves: [LilBroMove] = []
        var here = start
        if abs(goal.x - here.x) > maxJumpAcross, let current {
            let edgeX = goal.x > here.x ? current.maxX - 6 : current.minX + 6
            let runTo = goal.x > here.x ? min(edgeX, goal.x) : max(edgeX, goal.x)
            if abs(runTo - here.x) > 2 {
                here = CGPoint(x: runTo, y: here.y)
                moves.append(.run(to: here))
            }
        }
        moves.append(.jump(to: goal))
        return moves
    }

    private static func overlap(_ block: CGRect, _ span: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
        let lo = max(block.minX + 8, span.lowerBound), hi = min(block.maxX - 8, span.upperBound)
        return lo <= hi ? lo...hi : nil
    }

    private static func clamp(_ x: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(x, range.lowerBound), range.upperBound)
    }

    /// Where he stands to press something: on its top edge, at its right end
    /// where the button of a row lives.
    static func perch(on rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX + 14, rect.maxX - 46), y: rect.minY + 1)
    }
}

/// One stretch of movement in time, drawn by sampling `position(at:)`.
struct LilBroSegment: Equatable {
    enum Path: Equatable { case line, arc(height: CGFloat) }
    let from: CGPoint
    let to: CGPoint
    let start: Date
    let duration: TimeInterval
    let path: Path

    func progress(at date: Date) -> Double {
        duration <= 0 ? 1 : min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    func position(at date: Date) -> CGPoint {
        let t = CGFloat(progress(at: date))
        let x = from.x + (to.x - from.x) * t
        var y = from.y + (to.y - from.y) * t
        if case .arc(let height) = path { y -= height * 4 * t * (1 - t) }
        return CGPoint(x: x, y: y)
    }

    /// Speeds and arcs from the approved mockup.
    static func run(from: CGPoint, to: CGPoint, stroll: Bool, at start: Date) -> LilBroSegment {
        let distance = hypot(to.x - from.x, to.y - from.y)
        return LilBroSegment(from: from, to: to, start: start,
                             duration: Double(distance / (stroll ? 70 : 340)), path: .line)
    }

    static func jump(from: CGPoint, to: CGPoint, at start: Date) -> LilBroSegment {
        let distance = hypot(to.x - from.x, to.y - from.y)
        return LilBroSegment(from: from, to: to, start: start,
                             duration: Double(min(0.76, 0.28 + distance * 0.00085)),
                             path: .arc(height: min(96, 28 + distance * 0.17)))
    }

    static func climb(from: CGPoint, to: CGPoint, at start: Date) -> LilBroSegment {
        LilBroSegment(from: from, to: to, start: start, duration: Double(abs(from.y - to.y) / 230), path: .line)
    }
}
