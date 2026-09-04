import CoreGraphics
import Foundation

enum CaseDragAutoScrollPolicy {
    static let defaultEdgeBand: CGFloat = 28
    static let defaultMaxVelocity: CGFloat = 18

    static func velocity(
        pointerY: CGFloat,
        viewportHeight: CGFloat,
        edgeBand: CGFloat = defaultEdgeBand,
        maxVelocity: CGFloat = defaultMaxVelocity
    ) -> CGFloat {
        guard viewportHeight > 0, edgeBand > 0, maxVelocity > 0 else { return 0 }
        let clampedY = min(max(pointerY, 0), viewportHeight)

        if clampedY < edgeBand {
            let progress = 1 - (clampedY / edgeBand)
            return -maxVelocity * progress
        }

        if clampedY > viewportHeight - edgeBand {
            let progress = 1 - ((viewportHeight - clampedY) / edgeBand)
            return maxVelocity * progress
        }

        return 0
    }
}
