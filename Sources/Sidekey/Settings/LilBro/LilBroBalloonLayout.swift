import CoreGraphics

/// Where the balloon and the reply field go around Lil Bro: above him when
/// there is room, below when he stands near the top, beside him at the
/// window's edges; the reply field next to his feet. Pure, so every edge of
/// the window is tested without drawing.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
struct LilBroBalloonLayout: Equatable {
    enum Tail: Equatable { case down, up, left, right }

    var balloon: CGRect
    var tail: Tail
    /// Along the balloon's edge: x for down/up, y for left/right.
    var tailOffset: CGFloat
    var field: CGRect

    static let boySize = CGSize(width: 28, height: 32)
    static let pad: CGFloat = 10
    static let gap: CGFloat = 9

    /// Around the boy standing with his feet at `feet`.
    static func around(feet: CGPoint, balloon size: CGSize, field fieldSize: CGSize,
                       bounds: CGRect, target: CGRect?) -> LilBroBalloonLayout {
        let boy = CGRect(x: feet.x - 14, y: feet.y - 31, width: boySize.width, height: boySize.height)
        let minX = bounds.minX + pad, maxX = bounds.maxX - pad
        let minY = bounds.minY + pad, maxY = bounds.maxY - pad

        // The reply field at his feet: right of him if it fits, else left.
        let fitsRight = boy.maxX + 4 + fieldSize.width <= maxX
        let fieldX = fitsRight ? boy.maxX + 4 : max(minX, boy.minX - 6 - fieldSize.width)
        let fieldBase = target.map { min(feet.y, $0.minY - 3) } ?? feet.y
        var field = CGRect(x: fieldX, y: clamp(fieldBase - fieldSize.height, minY, maxY - fieldSize.height),
                           width: fieldSize.width, height: fieldSize.height)

        let preferLeft = feet.x > bounds.midX
        let candidateX = clamp(preferLeft ? boy.maxX - size.width : boy.minX - 8, minX, maxX - size.width)
        let ceiling = min(boy.minY, field.minY, target.map { $0.minY - 6 } ?? .infinity) - gap

        var balloon: CGRect
        var tail: Tail
        if ceiling - size.height >= minY {
            balloon = CGRect(x: candidateX, y: ceiling - size.height, width: size.width, height: size.height)
            tail = .down
        } else if boy.maxY + gap + size.height + fieldSize.height + 8 <= maxY {
            balloon = CGRect(x: candidateX, y: boy.maxY + gap, width: size.width, height: size.height)
            tail = .up
            field.origin = CGPoint(x: clamp(balloon.minX, minX, maxX - fieldSize.width), y: balloon.maxY + 8)
        } else if boy.minX - gap - size.width >= minX {
            balloon = CGRect(x: boy.minX - gap - size.width, y: clamp(boy.midY - size.height / 2, minY, maxY - size.height),
                             width: size.width, height: size.height)
            tail = .right
        } else {
            balloon = CGRect(x: clamp(boy.maxX + gap, minX, maxX - size.width),
                             y: clamp(boy.midY - size.height / 2, minY, maxY - size.height),
                             width: size.width, height: size.height)
            tail = .left
        }
        if tail == .left || tail == .right, field.intersects(balloon) {
            field.origin.y = clamp(balloon.maxY + 8, minY, maxY - fieldSize.height)
        }
        let offset: CGFloat
        switch tail {
        case .down, .up: offset = clamp(feet.x - balloon.minX, 16, max(16, balloon.width - 16))
        case .left, .right: offset = clamp(boy.midY - balloon.minY, 12, max(12, balloon.height - 12))
        }
        return LilBroBalloonLayout(balloon: balloon, tail: tail, tailOffset: offset, field: field)
    }

    /// The little guy is hidden: grow from the sidebar entry, field first.
    static func above(entry: CGRect, balloon size: CGSize, field fieldSize: CGSize,
                      bounds: CGRect) -> LilBroBalloonLayout {
        let minY = bounds.minY + pad
        let field = CGRect(x: entry.minX, y: max(minY, entry.minY - 6 - fieldSize.height),
                           width: fieldSize.width, height: fieldSize.height)
        let balloon = CGRect(x: entry.minX, y: max(minY, field.minY - gap - size.height),
                             width: size.width, height: size.height)
        return LilBroBalloonLayout(balloon: balloon, tail: .down,
                                   tailOffset: clamp(34, 16, max(16, size.width - 16)), field: field)
    }

    /// The tallest balloon that fits above the boy, so long answers scroll
    /// instead of covering the window.
    static func maxHeight(feet: CGPoint, bounds: CGRect, fieldHeight: CGFloat) -> CGFloat {
        let above = feet.y - 31 - gap - bounds.minY - pad
        let below = bounds.maxY - pad - (feet.y + 1 + gap) - fieldHeight - 8
        return max(150, min(420, max(above, below)))
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), max(lo, hi))
    }
}
