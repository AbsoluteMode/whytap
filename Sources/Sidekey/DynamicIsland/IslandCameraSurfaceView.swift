import AppKit
import SwiftUI

/// The island's single black surface (compact capsule + the agent wing's
/// rightward extension), drawn on a `CAShapeLayer` with the same continuous
/// uneven-rounded geometry SwiftUI uses to clip the overlaid content.
///
/// WIDTH GROWTH animates on the render server (`CASpringAnimation` on the
/// layer's `path`), NOT via a SwiftUI width spring: SwiftUI animations are
/// time-based and advance on the main thread, and dictation start stalls
/// that thread (AX target capture, Keychain JWT, WS handshake, audio
/// spin-up) — the spring's whole flight window could pass without a single
/// rendered frame, so the island's edge visibly teleported from compact to
/// extended instead of growing. The render server draws every frame no
/// matter what the app's main thread is doing.
struct IslandCameraSurface: NSViewRepresentable {
    let compactWidth: CGFloat
    let compactHeight: CGFloat
    let meetingSuggestionActive: Bool
    var trailingExtension: CGFloat = 0
    /// When `false`, width changes apply INSTANTLY (no `CASpringAnimation`), so
    /// the surface stays in lockstep with a SwiftUI width that is itself
    /// snapping. The acting slot snaps its width (its live progress label
    /// changes too rapidly to spring without shaking); springing the surface
    /// while the content snapped made the text briefly overflow the wing before
    /// the surface caught up. `true` keeps the render-server spring for the
    /// recording/composing grow, where the width changes monotonically.
    var animatesWidthChange: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var surfaceWidth: CGFloat {
        IslandFrameLayout.mergedCapsuleWidth(
            compactWidth: compactWidth,
            extension: trailingExtension
        )
    }

    private var bottomRadius: CGFloat {
        IslandFrameLayout.cameraBottomCornerRadius(
            compactHeight: compactHeight,
            meetingSuggestionActive: meetingSuggestionActive
        )
    }

    func makeNSView(context: Context) -> IslandCameraSurfaceLayerView {
        let view = IslandCameraSurfaceLayerView()
        view.apply(
            surfaceWidth: surfaceWidth,
            height: compactHeight,
            bottomRadius: bottomRadius,
            animated: false
        )
        return view
    }

    func updateNSView(_ view: IslandCameraSurfaceLayerView, context: Context) {
        view.apply(
            surfaceWidth: surfaceWidth,
            height: compactHeight,
            bottomRadius: bottomRadius,
            animated: !reduceMotion && animatesWidthChange
        )
    }
}

/// CAShapeLayer host for `IslandCameraSurface`. The view itself never
/// resizes with the island (the SwiftUI host frame is static at the widest
/// form) — only the layer's path morphs, so every width change is pure
/// render-server work.
final class IslandCameraSurfaceLayerView: NSView {
    static let growAnimationKey = "sidekey.surfaceGrow"

    /// `CASpringAnimation` tuned to read like the body's `widthGrowth`
    /// SwiftUI spring (response 0.32, dampingFraction 0.9): stiffness =
    /// (2π/response)², damping = 2·dampingFraction·(2π/response), mass 1.
    /// Keeping the curves close means the SwiftUI-driven content clip/offset
    /// and this surface stay visually in step during per-word growth.
    private static let springStiffness: CGFloat = 385.5
    private static let springDamping: CGFloat = 35.3

    private let shape = CAShapeLayer()
    private(set) var surfaceWidth: CGFloat = 0
    private(set) var surfaceHeight: CGFloat = 0
    private(set) var bottomRadius: CGFloat = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = NSColor.black.cgColor
        shape.anchorPoint = .zero
        shape.position = .zero
        layer?.masksToBounds = false
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(
        surfaceWidth: CGFloat,
        height: CGFloat,
        bottomRadius: CGFloat,
        animated: Bool
    ) {
        guard surfaceWidth != self.surfaceWidth
            || height != self.surfaceHeight
            || bottomRadius != self.bottomRadius
        else { return }

        let hadPath = shape.path != nil
        // Animate from what is ON SCREEN right now (the in-flight
        // presentation), so a mid-growth retarget never jumps.
        let fromPath = (shape.presentation() ?? shape).path

        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = height
        self.bottomRadius = bottomRadius

        let newPath = Self.surfacePath(
            width: surfaceWidth,
            height: height,
            topRadius: IslandFrameLayout.cameraTopCornerRadius,
            bottomRadius: bottomRadius
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = newPath
        CATransaction.commit()

        guard animated, hadPath, let fromPath else {
            shape.removeAnimation(forKey: Self.growAnimationKey)
            return
        }

        let spring = CASpringAnimation(keyPath: "path")
        spring.fromValue = fromPath
        spring.toValue = newPath
        spring.mass = 1
        spring.stiffness = Self.springStiffness
        spring.damping = Self.springDamping
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        shape.add(spring, forKey: Self.growAnimationKey)
    }

    /// Continuous uneven-rounded path in layer coordinates (origin
    /// bottom-left): the SCREEN-bottom corners carry `bottomRadius`, the
    /// screen-top corners `topRadius` (0 today — the surface meets the
    /// screen edge flush). The SwiftUI shape's y-axis is top-down, while
    /// this layer path is y-up, so top/bottom radii are intentionally
    /// swapped when building the path. `UnevenRoundedRectangle` keeps a
    /// stable element topology, so CA can interpolate any two of these paths.
    static func surfacePath(
        width: CGFloat,
        height: CGFloat,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> CGPath {
        // Clamp radii into (0, side/2]: a literal 0 degenerates the corner
        // arc into a line and CHANGES the path's element topology, which
        // breaks CA's path interpolation. 0.01pt is visually square.
        let bottom = min(max(bottomRadius, 0.01), min(width, height) / 2)
        let top = min(max(topRadius, 0.01), min(width, height) / 2)
        return UnevenRoundedRectangle(
            topLeadingRadius: bottom,
            bottomLeadingRadius: top,
            bottomTrailingRadius: top,
            topTrailingRadius: bottom,
            style: .continuous
        )
        .path(in: CGRect(x: 0, y: 0, width: width, height: height))
        .cgPath
    }

    var shapeLayerForTesting: CAShapeLayer { shape }
}
