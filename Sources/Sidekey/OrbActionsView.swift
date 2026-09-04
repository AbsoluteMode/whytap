import AppKit
import SwiftUI

/// Three-row action cluster rendered inside the darkened rounded-rect
/// frame of `OrbActionsOverlayPanel`. Each row's click opens the
/// unified history strip with the matching filter pre-selected
/// (`.agent` → Agent / `.drop` → Drop / `.clipboard` → Clipboard) via
/// `HistoryStripController.toggle(_:)` — same path the in-strip
/// sidebar would take.
///
/// Layout: vertical 3-row `VStack`, each row is one hit-test target
/// (`Button` wrapping the inner `HStack` with
/// `.contentShape(Rectangle())`). The whole row scales up together on
/// per-row hover.
///
///   [ agent PDF orb ]
///   [ drop  PDF orb ]
///   [ copy  PDF icon ]
///
/// Pre-ROO-208 each row also rendered an inline `⌥ 1` / `⌥ 2` / `⌥ 3`
/// helper chip; those per-mode hotkeys were collapsed into a single
/// `⌥V` unified-strip hotkey and the chips removed.
struct OrbActionsView: View {
    /// Stable identifier for each row slot. Pinned as an enum (rather
    /// than an integer index) so anti-regression tests can assert the
    /// row order without depending on internal layout.
    enum IconID: String, CaseIterable, Equatable {
        case agent
        case drop
        case clipboard
    }

    /// Canonical row order (top → bottom). Public for tests; the view
    /// body reads this constant so the visual order can't drift from
    /// the spec without flipping a test.
    static let iconOrder: [IconID] = [.agent, .drop, .clipboard]

    /// Visible side of each icon's square. Round 4 bumped from 22pt
    /// to 28pt (~27%) per Maxim's "В рамке иконки орбов сделал бы
    /// чуть-чуть больше, процентов на 20–25". The keycap chip column
    /// still uses `KeycapView.canonicalSize` (22pt), so the icon now
    /// reads as the heavier element in each row — the visual hierarchy
    /// matches the user's mental model where the icon IS the action
    /// and the chip is just the hint.
    static let iconSize: CGFloat = 28
    /// Inter-row vertical gap. With 28pt icons + ~4pt buffer the
    /// magnification headroom never collides with the neighbouring row.
    static let rowSpacing: CGFloat = 6
    /// Gap between the helper chip and the icon inside a single row.
    static let rowSpacingInner: CGFloat = 6

    /// Magnification peaks for the Dock-style scale. Pinned as
    /// constants so the value and the unit test agree.
    static let magnificationPeak: CGFloat = 1.30
    static let magnificationNeighborPeak: CGFloat = 1.10

    /// Horizontal content padding inside the rounded-rect frame —
    /// space between the rounded edge and the magnified row. Sized
    /// so that at peak scale (`magnificationPeak`) with `.center`
    /// anchor, the row's growth on EACH side
    /// (`approximateRowWidth × (peak - 1) / 2`) still fits inside
    /// this padding without clipping. Round 4 raised this from 10pt
    /// to 16pt because round 3's `.trailing` anchor pushed the helper
    /// chip out the left side of the frame at peak scale.
    static let frameContentHorizontalPadding: CGFloat = 16
    /// Vertical counterpart of `frameContentHorizontalPadding`. Smaller
    /// because the cluster's vertical extent grows less on per-row
    /// magnification (only one row hits peak at a time; neighbours
    /// get the smaller `magnificationNeighborPeak`).
    static let frameContentVerticalPadding: CGFloat = 10

    /// Approximate intrinsic width of a single row (helper chip +
    /// inner spacing + icon). The chip's actual width depends on
    /// `HotkeyHintView`'s capsule + two `KeycapView`s; the value here
    /// is a conservative estimate used only for tests + for sizing
    /// the overlay panel's minimum cluster width so the magnified
    /// row never clips. Computed as:
    ///   chip ≈ 2 × KeycapView.canonicalSize (22) + chip horizontal
    ///          padding (~20) ≈ 64pt
    ///   + rowSpacingInner (6) + iconSize (28) = ~98pt
    /// Conservative round-up to 100pt so the test math always passes
    /// even if `HotkeyHintView`'s chip drifts a few points.
    static let approximateRowWidth: CGFloat = 100

    /// Minimum overlay-panel width needed to fit the magnified cluster
    /// (row width × peak scale + frame padding on both sides + a
    /// small safety margin). Used by `OrbActionsOverlayPanel` to
    /// expand its envelope when the raw orb+helper union is narrower
    /// than the cluster's intrinsic width.
    static let minimumOverlayClusterWidth: CGFloat =
        approximateRowWidth * magnificationPeak
        + frameContentHorizontalPadding * 2
    /// Minimum overlay-panel height — three rows + spacing + vertical
    /// content padding on both sides.
    static let minimumOverlayClusterHeight: CGFloat =
        iconSize * 3
        + rowSpacing * 2
        + frameContentVerticalPadding * 2

    /// ROO-208: orb-action rows no longer carry an inline `⌥N` helper
    /// chip — the per-mode hotkeys were collapsed into a single `⌥V`
    /// unified-strip hotkey, and filter selection happens inside the
    /// strip's left sidebar. Returning `nil` for every row preserves
    /// the static helper signature for tests while removing the visual.
    static func helperContents(for id: IconID) -> [KeycapContent]? {
        _ = id
        return nil
    }

    /// Which row the cursor currently hovers over. `nil` when the
    /// cursor is outside every row — all rows return to baseline.
    @State private var hoveredIcon: IconID?

    /// `displayPreferences.hideHelpers` is observed for parity with the
    /// other helper-chip surfaces. ROO-208 removed the per-row chips
    /// themselves, but the dependency stays plugged so a future
    /// per-row hint reintroduction lands without re-plumbing.
    @ObservedObject private var displayPreferences: DisplayPreferences

    /// Click handler injected by `OrbActionsOverlayPanel` so the view
    /// stays decoupled from concrete `HistoryStripController` while still
    /// driving the strip on a click. Defaults to a no-op for previews +
    /// tests that don't care about wire-up.
    let onAction: (IconID) -> Void

    @MainActor
    init(
        onAction: @escaping (IconID) -> Void = { _ in },
        displayPreferences: DisplayPreferences? = nil
    ) {
        self.onAction = onAction
        self.displayPreferences = displayPreferences ?? .shared
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.rowSpacing) {
            ForEach(Array(Self.iconOrder.enumerated()), id: \.element) { index, id in
                row(for: id, index: index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Whytap actions")
    }

    @ViewBuilder
    private func row(for id: IconID, index: Int) -> some View {
        let hoveredIndex = Self.iconOrder.firstIndex(where: { $0 == hoveredIcon })
        let scale = OrbHoverDetector.magnificationScale(
            iconIndex: index,
            hoveredIndex: hoveredIndex,
            peak: Self.magnificationPeak,
            neighborPeak: Self.magnificationNeighborPeak
        )

        // Whole row is one `Button` so clicking anywhere along the
        // helper chip + icon HStack triggers the action — Maxim's
        // explicit "хелпер + иконка как одна сущность для клика".
        // `.contentShape(Rectangle())` makes the entire row's bounding
        // box hit-test, not just the cap glyphs / icon body.
        Button(action: { perform(id) }) {
            HStack(spacing: Self.rowSpacingInner) {
                // ROO-208: helper chips removed — `helperContents(for:)`
                // returns `nil` for every row now. Branch retained so a
                // future re-introduction of a per-row chip lands here
                // without re-plumbing the wrapper.
                if !displayPreferences.hideHelpers,
                   let contents = Self.helperContents(for: id) {
                    HotkeyHintView(contents: contents)
                }
                iconImage(for: id)
                    .frame(width: Self.iconSize, height: Self.iconSize)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Round 4 Fix A: anchor is `.center` (was `.trailing` in
        // round 3). Symmetric growth means each side extends by only
        // `rowWidth × (peak - 1) / 2` — half the round-3 leftward
        // overflow. Combined with the wider `frameContentHorizontalPadding`
        // and the wider overlay envelope (see `minimumOverlayClusterWidth`),
        // the magnified row stays inside the rounded-rect frame on
        // both sides instead of poking the helper chip out the left.
        .scaleEffect(scale, anchor: .center)
        .animation(
            .spring(response: 0.25, dampingFraction: 0.7),
            value: hoveredIcon
        )
        .onHover { inside in
            // `.onHover` fires here because the overlay panel accepts
            // mouse events (it is NOT click-through). When the cursor
            // crosses the row's bounds, scale the whole row up; when
            // it leaves, restore baseline.
            if inside {
                hoveredIcon = id
                NSCursor.pointingHand.set()
            } else if hoveredIcon == id {
                hoveredIcon = nil
                NSCursor.arrow.set()
            }
        }
        .accessibilityLabel(accessibilityLabel(for: id))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func iconImage(for id: IconID) -> some View {
        if let nsImage = OrbActionIcon(from: id).image() {
            // PDF assets are vector — `.resizable()` + `.fit` gives
            // crisp render at the 22pt frame regardless of underlying
            // PDF document size.
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Defensive fallback if the PDF asset is missing from the
            // bundle (e.g. build-dmg.sh forgot to copy it). A simple
            // placeholder so the row layout doesn't collapse — better
            // than a hard crash on the user's first hover.
            Image(systemName: "questionmark.circle")
                .font(.system(size: Self.iconSize * 0.7, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Step 2: forwards the row click to the injected `onAction`
    /// handler, which `OrbActionsOverlayPanel` binds to a call into
    /// `HistoryStripController.toggle(_:)` for the matching mode.
    /// Without a wired handler this is a no-op (preview / test paths).
    private func perform(_ id: IconID) {
        onAction(id)
    }

    private func accessibilityLabel(for id: IconID) -> String {
        switch id {
        case .agent:     return "Agent"
        case .drop:      return "Drop voice"
        case .clipboard: return "Clipboard"
        }
    }
}

/// Bundled PDF asset for each row's icon. The PDFs were converted
/// from Maxim's hand-drawn SVGs via `rsvg-convert -f pdf` (see
/// `scripts/dev-run.sh` + `scripts/build-dmg.sh` for the bundle
/// copy step). Vector PDFs scale crisp at any size — `.resizable()`
/// + `.aspectRatio(contentMode: .fit)` on the SwiftUI side is enough
/// to get a clean glyph at 22pt.
enum OrbActionIcon: Equatable {
    case agent
    case drop
    case clipboard

    /// Maps `OrbActionsView.IconID` into this asset enum — small
    /// adapter so the view layer stays unaware of the resource pipeline
    /// detail.
    init(from id: OrbActionsView.IconID) {
        switch id {
        case .agent:     self = .agent
        case .drop:      self = .drop
        case .clipboard: self = .clipboard
        }
    }

    /// PDF resource name (no extension) inside the app bundle's
    /// `Contents/Resources/`. The build scripts copy these in.
    var pdfResourceName: String {
        switch self {
        case .agent:     return "orb-icon-agent"
        case .drop:      return "orb-icon-drop"
        case .clipboard: return "copy-icon-neon"
        }
    }

    /// Loads the bundled PDF into an `NSImage` once and caches the
    /// result for the lifetime of the process. NSImage internally
    /// caches the parsed CGImage so repeated draws don't re-parse.
    /// Returns `nil` if the resource is missing — the icon view
    /// renders a placeholder rather than crashing.
    func image() -> NSImage? {
        if let cached = Self.cache[pdfResourceName] { return cached }
        guard let url = Bundle.main.url(
            forResource: pdfResourceName,
            withExtension: "pdf"
        ) else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        // Crucially DO NOT set `isTemplate = true` — the orb icons
        // carry their pink/violet (Agent) and white (Drop) palette in
        // the PDF; template-mode would discard the colours and render
        // them as monochrome tinted glyphs.
        if let image = image {
            Self.cache[pdfResourceName] = image
        }
        return image
    }

    private static var cache: [String: NSImage] = [:]
}
