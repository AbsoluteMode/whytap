import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The island's black surface grows via a CAShapeLayer path animation on the
/// render server — NOT a SwiftUI width spring. The SwiftUI spring is
/// time-based on the main thread, and dictation start stalls that thread
/// (AX capture, Keychain JWT, WS handshake, audio spin-up): the spring's
/// flight window passes with no frames rendered, so the edge visibly
/// teleported from compact to extended. The render server draws every frame
/// regardless of main-thread stalls.
@MainActor
final class IslandCameraSurfaceViewTests: XCTestCase {
    func test_surfacePathBoundsMatchRequestedSize() {
        let path = IslandCameraSurfaceLayerView.surfacePath(
            width: 277, height: 38, topRadius: 0, bottomRadius: 10
        )
        XCTAssertEqual(path.boundingBox.width, 277, accuracy: 0.001)
        XCTAssertEqual(path.boundingBox.height, 38, accuracy: 0.001)
        XCTAssertEqual(path.boundingBox.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingBox.origin.y, 0, accuracy: 0.001)
    }

    func test_surfacePathUsesSystemContinuousCornerGeometry() {
        let width: CGFloat = 277
        let height: CGFloat = 38
        let bottomRadius: CGFloat = 10

        let path = IslandCameraSurfaceLayerView.surfacePath(
            width: width,
            height: height,
            topRadius: 0,
            bottomRadius: bottomRadius
        )
        let expected = UnevenRoundedRectangle(
            topLeadingRadius: bottomRadius,
            bottomLeadingRadius: 0.01,
            bottomTrailingRadius: 0.01,
            topTrailingRadius: bottomRadius,
            style: .continuous
        )
        .path(in: CGRect(x: 0, y: 0, width: width, height: height))
        .cgPath

        XCTAssertEqual(
            path.elementSnapshots,
            expected.elementSnapshots,
            "The black surface must use the same continuous corner geometry as the SwiftUI clip."
        )
    }

    func test_widthChangeRunsRenderServerSpring() {
        let view = IslandCameraSurfaceLayerView()
        view.apply(surfaceWidth: 240, height: 38, bottomRadius: 10, animated: false)

        view.apply(surfaceWidth: 277, height: 38, bottomRadius: 10, animated: true)

        let animation = view.shapeLayerForTesting.animation(
            forKey: IslandCameraSurfaceLayerView.growAnimationKey
        )
        let spring = animation as? CASpringAnimation
        XCTAssertNotNil(spring, "width growth must be a render-server spring")
        XCTAssertEqual(spring?.keyPath, "path")
        XCTAssertEqual(
            view.shapeLayerForTesting.path?.boundingBox.width ?? 0,
            277,
            accuracy: 0.001,
            "model path lands at the target width"
        )
    }

    func test_sameWidthDoesNotRestartAnimation() {
        let view = IslandCameraSurfaceLayerView()
        view.apply(surfaceWidth: 240, height: 38, bottomRadius: 10, animated: false)
        view.apply(surfaceWidth: 277, height: 38, bottomRadius: 10, animated: true)
        view.shapeLayerForTesting.removeAllAnimations()

        view.apply(surfaceWidth: 277, height: 38, bottomRadius: 10, animated: true)

        XCTAssertNil(
            view.shapeLayerForTesting.animation(
                forKey: IslandCameraSurfaceLayerView.growAnimationKey
            ),
            "a no-op apply must not restart the grow animation"
        )
    }

    func test_reducedMotionAppliesWidthWithoutAnimation() {
        let view = IslandCameraSurfaceLayerView()
        view.apply(surfaceWidth: 240, height: 38, bottomRadius: 10, animated: false)

        view.apply(surfaceWidth: 277, height: 38, bottomRadius: 10, animated: false)

        XCTAssertNil(
            view.shapeLayerForTesting.animation(
                forKey: IslandCameraSurfaceLayerView.growAnimationKey
            )
        )
        XCTAssertEqual(
            view.shapeLayerForTesting.path?.boundingBox.width ?? 0,
            277,
            accuracy: 0.001
        )
    }

    func test_meetingSquareCornersChangeAnimatesPathToo() {
        let view = IslandCameraSurfaceLayerView()
        view.apply(surfaceWidth: 240, height: 38, bottomRadius: 10, animated: false)

        view.apply(surfaceWidth: 240, height: 38, bottomRadius: 0, animated: true)

        XCTAssertNotNil(
            view.shapeLayerForTesting.animation(
                forKey: IslandCameraSurfaceLayerView.growAnimationKey
            ),
            "radius changes ride the same render-server animation"
        )
    }
}

private extension CGPath {
    var elementSnapshots: [PathElementSnapshot] {
        var elements: [PathElementSnapshot] = []
        applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let pointCount: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                pointCount = 1
            case .addQuadCurveToPoint:
                pointCount = 2
            case .addCurveToPoint:
                pointCount = 3
            case .closeSubpath:
                pointCount = 0
            @unknown default:
                pointCount = 0
            }
            let points = (0..<pointCount).map { index in
                CGPoint(
                    x: (element.points[index].x * 1_000).rounded() / 1_000,
                    y: (element.points[index].y * 1_000).rounded() / 1_000
                )
            }
            elements.append(PathElementSnapshot(type: element.type, points: points))
        }
        return elements
    }
}

private struct PathElementSnapshot: Equatable {
    let type: CGPathElementType
    let points: [CGPoint]
}
