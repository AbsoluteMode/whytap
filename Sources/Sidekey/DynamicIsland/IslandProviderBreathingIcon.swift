import AppKit
import SwiftUI

/// Subtle "breathing" provider mark shown before live drop dictation chunks.
///
/// The pulse is a Core Animation animation on a plain `CALayer`, NOT a SwiftUI
/// `.animation(.repeatForever)`: SwiftUI animations advance frame-by-frame on
/// the main thread, and this mark appears exactly when the main thread is
/// busiest — dictation start (AX target capture, Keychain JWT, WS handshake,
/// audio-engine spin-up) and per-word transcript updates. The SwiftUI version
/// visibly stuttered on every first drop after launch (everything cold) and
/// intermittently afterwards; a render-server animation keeps breathing
/// through main-thread stalls.
struct IslandProviderBreathingIcon: NSViewRepresentable {
    let brand: TranscriptionProviderBrand

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ProviderBreathingMarkView {
        ProviderBreathingMarkView(brand: brand, reduceMotion: reduceMotion)
    }

    func updateNSView(_ nsView: ProviderBreathingMarkView, context: Context) {
        nsView.apply(brand: brand, reduceMotion: reduceMotion)
    }
}

/// CALayer-backed implementation of the breathing provider mark (see
/// `IslandProviderBreathingIcon` for why this is not SwiftUI-animated).
final class ProviderBreathingMarkView: NSView {
    static let breathingAnimationKey = "sidekey.providerBreathing"
    static let pulseDuration: TimeInterval = 1.15
    static let reducedMotionOpacity: Float = 0.78

    /// Mark size inside the fixed 16×16 slot — matches the prior SwiftUI
    /// layout (`ProviderBrandIcon(size: 15)` inside a 16pt frame).
    private static let slotSide: CGFloat = 16
    private static let markSide: CGFloat = 15
    private static let markColor = NSColor.white.withAlphaComponent(0.72)

    private(set) var brand: TranscriptionProviderBrand
    private(set) var reduceMotion: Bool
    private let markLayer = CALayer()

    init(brand: TranscriptionProviderBrand, reduceMotion: Bool) {
        self.brand = brand
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(x: 0, y: 0, width: Self.slotSide, height: Self.slotSide))
        wantsLayer = true
        // The scale peak (1.08) pokes past the 16pt slot by a fraction of a
        // point — let it, like SwiftUI's scaleEffect did.
        layer?.masksToBounds = false
        markLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(markLayer)
        layoutMarkLayer()
        reloadContents()
        applyMotionState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.slotSide, height: Self.slotSide)
    }

    func apply(brand: TranscriptionProviderBrand, reduceMotion: Bool) {
        if brand != self.brand {
            self.brand = brand
            reloadContents()
        }
        if reduceMotion != self.reduceMotion {
            self.reduceMotion = reduceMotion
            applyMotionState()
        }
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
        layoutMarkLayer()
    }

    private func layoutMarkLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.bounds = CGRect(x: 0, y: 0, width: Self.markSide, height: Self.markSide)
        markLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private func reloadContents() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let image = Self.markImage(for: brand)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.contentsScale = scale
        markLayer.contents = image?.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    /// Static (reduce-motion) values or the infinite render-server pulse.
    /// The animated ranges mirror the prior SwiftUI modifiers:
    /// scale 0.94→1.08, opacity 0.58→0.96, easeInOut 1.15s autoreversing.
    private func applyMotionState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        markLayer.removeAnimation(forKey: Self.breathingAnimationKey)
        markLayer.transform = CATransform3DIdentity
        if reduceMotion {
            markLayer.opacity = Self.reducedMotionOpacity
            return
        }
        // Model value parks at the bright end; presentation is owned by the
        // infinite animation, so this only shows if the animation is removed.
        markLayer.opacity = 0.96

        let pulseScale = CABasicAnimation(keyPath: "transform.scale")
        pulseScale.fromValue = CGFloat(0.94)
        pulseScale.toValue = CGFloat(1.08)

        let pulseOpacity = CABasicAnimation(keyPath: "opacity")
        pulseOpacity.fromValue = Float(0.58)
        pulseOpacity.toValue = Float(0.96)

        let pulse = CAAnimationGroup()
        pulse.animations = [pulseScale, pulseOpacity]
        pulse.duration = Self.pulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .greatestFiniteMagnitude
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        markLayer.add(pulse, forKey: Self.breathingAnimationKey)
    }

    /// Mark bitmap for the breathing ticker. Most brands are flattened to the
    /// monochrome white tint the way SwiftUI's
    /// `.renderingMode(.template).foregroundStyle(...)` did. Full-color brands
    /// (the Qwen on-device mark) instead keep their native colors: the asset is
    /// loaded non-template and the `.sourceAtop` white wash is skipped, so the
    /// genuine blue glyph survives rather than reading as a generic white blob.
    private static func markImage(for brand: TranscriptionProviderBrand) -> NSImage? {
        let base: NSImage?
        if brand.isFullColor, let assetName = brand.assetName {
            base = ProviderBrandIconAsset.fullColorImage(named: assetName)
        } else if let assetName = brand.assetName {
            base = ProviderBrandIconAsset.image(named: assetName, pointSize: markSide)
        } else if let systemName = brand.systemName {
            base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: markSide * 0.72, weight: .semibold)
                )
        } else {
            base = nil
        }
        guard let base, base.size.width > 0, base.size.height > 0 else { return nil }

        let canvas = NSSize(width: markSide, height: markSide)
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
        if !brand.isFullColor {
            markColor.set()
            NSRect(origin: .zero, size: canvas).fill(using: .sourceAtop)
        }
        rendered.unlockFocus()
        return rendered
    }

    var markLayerForTesting: CALayer { markLayer }

    /// The composited mark bitmap (post tint / full-color decision) for the
    /// given brand. Lets tests assert the Qwen mark keeps its blue glyph rather
    /// than being flattened to the monochrome white tint.
    static func markImageForTesting(brand: TranscriptionProviderBrand) -> NSImage? {
        markImage(for: brand)
    }
}
