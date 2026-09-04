import AppKit
import SwiftUI

/// A crisp, continuously-rotating spinner shown inside the Dynamic Island
/// update pill while Sparkle is downloading (and briefly auto-installing) an
/// update.
///
/// The rotation is a Core Animation animation on a plain `CALayer`, NOT a
/// SwiftUI `.animation(.repeatForever)`: SwiftUI animations advance frame-by-
/// frame on the main thread, and this spinner appears exactly while the main
/// thread is doing the download/extract work — every progress chunk mutates
/// `AppState.updateAvailable` (`@Published`) and re-renders the island. A
/// render-server animation keeps spinning smoothly through those stalls.
/// Same rationale (and the same re-attach-on-window handling) as
/// `IslandProviderBreathingIcon`.
struct IslandUpdateSpinner: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> UpdateSpinnerMarkView {
        UpdateSpinnerMarkView(reduceMotion: reduceMotion)
    }

    func updateNSView(_ nsView: UpdateSpinnerMarkView, context: Context) {
        nsView.apply(reduceMotion: reduceMotion)
    }
}

/// CALayer-backed implementation of the update download spinner (see
/// `IslandUpdateSpinner` for why this is not SwiftUI-animated).
final class UpdateSpinnerMarkView: NSView {
    static let spinAnimationKey = "sidekey.updateSpinner"
    /// One full turn per revolution. A hair over a second reads as a calm,
    /// deliberate "working" spin rather than a frantic loader.
    static let spinDuration: TimeInterval = 1.05

    /// Slot / glyph sizing matches the compact pill's icon
    /// (`.font(.system(size: 13.5))`) so the spinner sits where the static
    /// `arrow.down.circle` used to.
    private static let slotSide: CGFloat = 16
    private static let glyphPointSize: CGFloat = 13.5
    private static let glyphColor = NSColor.white

    private(set) var reduceMotion: Bool
    private let glyphLayer = CALayer()

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(x: 0, y: 0, width: Self.slotSide, height: Self.slotSide))
        wantsLayer = true
        layer?.masksToBounds = false
        glyphLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(glyphLayer)
        layoutGlyphLayer()
        reloadContents()
        applyMotionState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.slotSide, height: Self.slotSide)
    }

    func apply(reduceMotion: Bool) {
        guard reduceMotion != self.reduceMotion else { return }
        self.reduceMotion = reduceMotion
        applyMotionState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Backing scale is only known once attached — re-render crisp contents.
        reloadContents()
        // CA drops animations when a layer leaves the render tree — re-attach.
        applyMotionState()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reloadContents()
    }

    override func layout() {
        super.layout()
        layoutGlyphLayer()
    }

    private func layoutGlyphLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.bounds = CGRect(x: 0, y: 0, width: Self.slotSide, height: Self.slotSide)
        glyphLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Rotate around the layer's own centre.
        glyphLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        CATransaction.commit()
    }

    private func reloadContents() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let image = Self.glyphImage()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.contentsScale = scale
        glyphLayer.contents = image?.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    /// Static (reduce-motion) glyph, or the infinite render-server spin.
    private func applyMotionState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        glyphLayer.removeAnimation(forKey: Self.spinAnimationKey)
        glyphLayer.transform = CATransform3DIdentity
        if reduceMotion { return }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = CGFloat(0)
        spin.toValue = CGFloat.pi * 2
        spin.duration = Self.spinDuration
        spin.repeatCount = .greatestFiniteMagnitude
        spin.isRemovedOnCompletion = false
        // Linear so the sweep is perfectly even — an eased spinner visibly
        // hitches at each cycle boundary.
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        glyphLayer.add(spin, forKey: Self.spinAnimationKey)
    }

    /// The arrow glyph bitmap, tinted white. `arrow.triangle.2.circlepath` is
    /// the canonical macOS "refresh / in progress" mark and reads as a loader
    /// while spinning.
    private static func glyphImage() -> NSImage? {
        let base = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: nil
        )?
        .withSymbolConfiguration(.init(pointSize: glyphPointSize, weight: .semibold))
        guard let base, base.size.width > 0, base.size.height > 0 else { return nil }

        let canvas = NSSize(width: slotSide, height: slotSide)
        let fit = min(canvas.width / base.size.width, canvas.height / base.size.height)
        let drawSize = NSSize(width: base.size.width * fit, height: base.size.height * fit)
        let drawOrigin = NSPoint(
            x: (canvas.width - drawSize.width) / 2,
            y: (canvas.height - drawSize.height) / 2
        )

        let rendered = NSImage(size: canvas)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(
            in: NSRect(origin: drawOrigin, size: drawSize),
            from: NSRect(origin: .zero, size: base.size),
            operation: .sourceOver,
            fraction: 1
        )
        glyphColor.set()
        NSRect(origin: .zero, size: canvas).fill(using: .sourceAtop)
        rendered.unlockFocus()
        return rendered
    }

    var spinnerLayerForTesting: CALayer { glyphLayer }
}
