import AppKit
import SwiftUI

enum IslandHoverGlass {
    /// Offscreen review renders draw the macOS 14/15 path on a newer Mac.
    /// The app never sets it.
    nonisolated(unsafe) static var drawsLegacyPathForReview = false

    /// Whether the current runtime supports native macOS 26 Liquid Glass.
    static var usesNativeLiquidGlass: Bool {
        if drawsLegacyPathForReview { return false }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }
}

/// Which backdrop a hover drawer card draws behind its content.
enum IslandHoverBackdrop: Equatable {
    /// macOS 26+ `glassEffect(.regular)`.
    case nativeGlass
    /// macOS 14/15 (or an older SDK): `IslandDetachedHoverPanelBackground`.
    case legacyMaterial
    /// A solid dark card: Reduce transparency is on.
    case opaque
}

/// Every hover drawer card, History included, always has a readable
/// backdrop. History on macOS 14/15 used to opt out and left its gaps
/// see-through over other windows.
// WHY: .project-docs/decisions/2026-11-21-history-backdrop-always.md
enum IslandHoverBackdropPolicy {
    static func backdrop(nativeGlassAvailable: Bool, reduceTransparency: Bool) -> IslandHoverBackdrop {
        if reduceTransparency { return .opaque }
        return nativeGlassAvailable ? .nativeGlass : .legacyMaterial
    }

    /// The island window is always dark; this matches its compact pill.
    static let opaqueFill = Color(nsColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
}

/// The backdrop shape alone, so offscreen checks can render each kind.
struct IslandHoverBackdropView: View {
    let backdrop: IslandHoverBackdrop
    var cornerRadius: CGFloat = IslandDropModeControl.detachedPanelCornerRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch backdrop {
        case .opaque:
            shape.fill(IslandHoverBackdropPolicy.opaqueFill)
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
        case .legacyMaterial:
            IslandDetachedHoverPanelBackground(cornerRadius: cornerRadius)
        case .nativeGlass:
            nativeGlass(shape)
        }
    }

    @ViewBuilder
    private func nativeGlass(_ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Keep the optical backdrop separate from the foreground
            // lenses, matching the reference's independent layers.
            shape.fill(Color.clear)
                // Regular retains adaptive contrast over bright
                // desktops when this panel becomes key for search.
                .glassEffect(.regular, in: shape)
                // Active appearance only; the utility stays non-key.
                .environment(\.appearsActive, true)
        } else {
            IslandDetachedHoverPanelBackground(cornerRadius: cornerRadius)
        }
        #else
        IslandDetachedHoverPanelBackground(cornerRadius: cornerRadius)
        #endif
    }
}

/// Applies a native macOS 26+ optical backdrop separately from foreground
/// lenses and icons, preserving their colors. Earlier systems retain the
/// layered `IslandDetachedHoverPanelBackground` fallback; Reduce transparency
/// gets an opaque dark card on every system.
struct IslandHoverGlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = IslandDropModeControl.detachedPanelCornerRadius
    /// The hover drawer: its glass reports its own frame (`.drawer`), the
    /// frame a dragged tile must leave to be removed.
    var drawerBridge: IslandHoverHitBridge?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    private func backdropView(_ backdrop: IslandHoverBackdrop) -> some View {
        if let drawerBridge {
            IslandHoverBackdropView(backdrop: backdrop, cornerRadius: cornerRadius)
                .islandHoverHitRegion(bridge: drawerBridge, surface: .drawer)
        } else {
            IslandHoverBackdropView(backdrop: backdrop, cornerRadius: cornerRadius)
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let backdrop = IslandHoverBackdropPolicy.backdrop(
            nativeGlassAvailable: IslandHoverGlass.usesNativeLiquidGlass,
            reduceTransparency: reduceTransparency
        )
        if backdrop == .nativeGlass {
            content
                .background { backdropView(backdrop) }
                .overlay {
                    IslandHoverGlassRim(shape: shape)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background(backdropView(backdrop))
                .clipShape(shape)
        }
    }
}

/// Thin specular edge and inner lens, inspired by the user's LiquidButton
/// reference. Keep the native backdrop visible and every decorative layer
/// outside mouse routing.
struct IslandHoverGlassRim<S: InsettableShape>: View {
    let shape: S
    var highlighted = false

    var body: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(highlighted ? 0.95 : 0.75), location: 0),
                        .init(color: .white.opacity(0.12), location: 0.35),
                        .init(color: .white.opacity(0.08), location: 0.65),
                        .init(color: .white.opacity(highlighted ? 0.70 : 0.45), location: 1)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
            .overlay {
                shape.inset(by: 1)
                    .strokeBorder(.white.opacity(highlighted ? 0.22 : 0.12), lineWidth: 2)
                    .blur(radius: 1.2)
                    .clipShape(shape)
            }
    }
}

/// Preserves the shared controls container on macOS 26+. Circular foreground
/// lenses remain distinct 44pt controls without nested native glass effects.
/// Passes content through unchanged on earlier macOS versions.
struct IslandHoverGlassControlsContainer<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

extension View {
    /// A foreground input lens shares its card's backdrop rather than adding
    /// nested native glass. Its interior stays transparent while editing.
    @ViewBuilder
    func islandHoverInputLens(cornerRadius: CGFloat) -> some View {
        if IslandHoverGlass.usesNativeLiquidGlass {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background {
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(0.14), .white.opacity(0.055)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .allowsHitTesting(false)
                }
                .overlay {
                    IslandHoverGlassRim(shape: shape).allowsHitTesting(false)
                }
        } else {
            self
        }
    }

    func islandHoverGlassSurface(
        cornerRadius: CGFloat = IslandDropModeControl.detachedPanelCornerRadius,
        reportingDrawerTo drawerBridge: IslandHoverHitBridge? = nil
    ) -> some View {
        modifier(IslandHoverGlassSurfaceModifier(cornerRadius: cornerRadius, drawerBridge: drawerBridge))
    }
}
