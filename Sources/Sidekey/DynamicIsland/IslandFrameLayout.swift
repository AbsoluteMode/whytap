import AppKit
import CoreGraphics
import Foundation

/// Pure-function frame math for the Dynamic Island PoC panel. Lives
/// outside `IslandPanel` so the layout decisions (compact pill wraps
/// the physical notch — orb on the left, triggers on the right) can be
/// unit-tested
/// without constructing a real `NSScreen` — XCTest cannot instantiate
/// `NSScreen` directly. The live `IslandPanel` resolves one stable
/// `IslandScreenDescriptor` snapshot and forwards its geometry here.
///
/// Coordinate system: AppKit's bottom-left origin (y-up). `maxY` is the
/// top edge of the rect.
///
/// **Design intent (Maxim, в его словах):**
/// > есть область где физически экран на маках отсутствует где камера
/// > стоит. нужно вот туда поместить нашу панель так что бы слева и
/// > справа от этой области были наши орбы и подсказки
///
/// The pill literally surrounds the notch cutout, the iPhone Dynamic
/// Island pattern. Because the pill background is pure black, the
/// hardware cutout reads as a continuous extension of the pill.
enum IslandFrameLayout {

    // MARK: - Side panel widths (primary tunable knobs)

    /// Width of the LEFT side of the pill (the orb-bearing half).
    /// Sized to fit the main `VoiceOrbView` (`compactHeight - 4` ≈ 34pt
    /// at the default 38pt notch height) with ~18pt horizontal breathing
    /// room across the orb's frame.
    ///
    /// Current visual pass widens the island by 5pt on each side.
    static let leftSideWidth: CGFloat = 70

    /// Width of the RIGHT side of the pill (the trigger-orb half).
    /// Sized to fit the two 28pt PDF mini-orbs + their 8pt inter-slot
    /// spacing (= 64pt) with a little breathing room around the band
    /// after the latest 5pt widening.
    ///
    /// Current visual pass widens the island by 5pt on each side.
    static let rightSideWidth: CGFloat = 70

    /// Whole hover-trigger orb pair offset inside the right band. Was
    /// `-10` to stay well clear of the camera boundary; nudged 7pt
    /// right after the right band gained extra breathing room.
    static let rightTriggerOrbGroupOffsetX: CGFloat = -3

    /// Width the island grows LEFTWARD when a left-side notification is
    /// shown. The notification surface joins the island's left edge,
    /// extending the compact frame in the `-x` direction by this amount
    /// while the right edge stays pinned to the island.
    static let leftNotificationWidth: CGFloat = 300

    // MARK: agent surfaces (island agent flow)

    /// VERTICAL gap between the island capsule row and the agent answer
    /// panel below it (answer-panel top padding + `answerRect.y` offset).
    /// The wing itself no longer uses this as a horizontal seam — it sits
    /// flush against the capsule, reading as the island stretching rather
    /// than a separate component.
    static let agentWingGap: CGFloat = 8
    /// Wing width while voice-recording (live transcript ticker).
    static let agentWingRecordingWidth: CGFloat = 260
    /// Wing width while composing text (R-Cmd tap input field).
    static let agentWingComposingWidth: CGFloat = 300
    /// Collapsed acting-slot width (the "thinking…" activity ticker). Sized to
    /// hug the dot + the longest category label ("transcribing…") so the
    /// leading-aligned content begins flush at the camera's right edge (band
    /// left) and the capsule barely grows — the indicator stays NEXT to the
    /// camera instead of drifting out to the right.
    static let agentWingActingWidth: CGFloat = 120
    /// Close-controls slot width (the `[Esc] [✕]` cluster shown in the wing
    /// while the answer card is up). Sized to hug "Esc" + gap + the ✕ glyph
    /// plus horizontal breathing room.
    static let agentWingAnswerControlsWidth: CGFloat = 76
    /// Transient STT-failure notice width. Wider than the acting slot because
    /// its messages are full sentences ("Connect an agent in Settings"); kept
    /// separate so shrinking the acting slot doesn't truncate the notice.
    static let agentWingFailedWidth: CGFloat = 220
    /// Total-offline Drop-delivery failure wing width (Task 7). Hosts the
    /// "Couldn't deliver — offline" message AND the trailing Retry pill, so it
    /// is wider than the transient `.failed` notice. Kept separate so the two
    /// failure surfaces size independently.
    static let agentWingDeliveryFailedWidth: CGFloat = 290
    /// Horizontal window extension to the right when agent is active. The
    /// agent phase content begins in the right band (inside the capsule) and
    /// the form grows only by the widest face's overflow, so the reserved
    /// rightward zone is the composing face's EXTENSION. (`rightAgentZoneWidth`
    /// keeps the wider value below for window/row reservation — see note.)
    ///
    /// Window reservation note: the host window / row still reserve the full
    /// widest-face width (`agentWingComposingWidth`) so the answer panel and
    /// the transparent agent zone have ample room. The visible island FORM,
    /// however, grows only by the per-face EXTENSION (`agentWingExtension`).
    /// The extra reserved width is transparent and harmless.
    static let rightAgentZoneWidth: CGFloat = agentWingComposingWidth

    /// How much of any agent phase face is hosted INSIDE the compact capsule.
    /// The content begins where the passive hints begin — in the right band,
    /// just after the notch gap — so exactly the right band's width fits
    /// inside the capsule before the island form has to grow.
    static let agentWingInCapsuleWidth: CGFloat = rightSideWidth

    /// How far the island form must grow RIGHTWARD to host a face of
    /// `faceWidth`: only the part that overflows the right band
    /// (`faceWidth - agentWingInCapsuleWidth`), clamped at 0 for faces that
    /// already fit inside the band. The first `agentWingInCapsuleWidth` of
    /// every face sits inside the compact capsule; this is the remainder.
    static func agentWingExtension(faceWidth: CGFloat) -> CGFloat {
        max(0, faceWidth - agentWingInCapsuleWidth)
    }

    // MARK: - Adaptive (content-sized) wing width

    /// Floor for a content-sized wing face — keeps the capsule from
    /// collapsing below a legible minimum (and guards a zero measurement).
    /// Deliberately below the "listening…" placeholder width so the
    /// placeholder itself sets the natural compact start; the floor only
    /// catches shorter transcripts.
    static let adaptiveWingFloor: CGFloat = 72

    /// Adaptive width of a content-sized wing face: the measured content
    /// width (rendered text + horizontal padding) clamped into
    /// `[adaptiveWingFloor, cap]`. `cap` is the face's established maximum
    /// (`agentWingRecordingWidth` 260 / `agentWingComposingWidth` 300). Pure
    /// so the clamp is unit-testable without rendering — the measurement that
    /// feeds it (`NSFont` metrics in `IslandView`) is not.
    static func adaptiveWingWidth(measuredContentWidth: CGFloat, cap: CGFloat) -> CGFloat {
        min(max(measuredContentWidth, adaptiveWingFloor), cap)
    }

    /// Extension of the RECORDING form — the single source of truth for the
    /// answer panel's right-edge alignment (both the rendered trailing pad in
    /// `IslandView.agentAnswerLayer` and the `IslandAgentHitZones.answerRect`
    /// math). Keeping the formula here means the panel and its hit zone can
    /// never drift apart.
    static let agentWingRecordingExtension: CGFloat =
        agentWingExtension(faceWidth: agentWingRecordingWidth)

    /// Width of the SINGLE black island surface once the agent phase content
    /// lives INSIDE the capsule (no separate wing component). The island is
    /// one continuous shape that stretches rightward by the active face's
    /// EXTENSION (the part that overflows the right band): `compactWidth +
    /// extension`. The first `agentWingInCapsuleWidth` of the face is hosted
    /// inside the compact capsule's right band, so only the remainder grows
    /// the form. When there is no extension (`extension == 0`, face fits the
    /// band) this collapses to the bare compact capsule, so the no-agent
    /// island is unchanged. The surface is leading-anchored at the capsule's
    /// left edge, so growing it never moves the camera — only the right edge
    /// (and its bottom-trailing rounded corner) travels.
    static func mergedCapsuleWidth(compactWidth: CGFloat, extension wingExtension: CGFloat) -> CGFloat {
        compactWidth + max(0, wingExtension)
    }
    /// Answer panel column width (matches the legacy response pill width).
    static let agentAnswerPanelWidth: CGFloat = 336
    /// Vertical window extension below the capsule reserved for the answer
    /// panel (content height is hit-test gated, window stays allocated).
    static let agentAnswerZoneHeight: CGFloat = 480

    /// Width of the synthetic notch placeholder on non-notched screens
    /// (external monitors, older Macs). Keeps the design language
    /// (orb on the left, triggers on the right with a gap in the middle)
    /// consistent even without a real hardware notch. Roughly matches
    /// the average physical notch width across shipping MBPs (≈170pt).
    static let syntheticNotchWidth: CGFloat = 170

    // MARK: - Compact-height clamping

    /// Lower bound on compact pill height. Below this the orbs can't be
    /// visually distinguished. 24pt matches
    /// the classic external-monitor menu-bar height.
    static let minCompactHeight: CGFloat = 24

    /// Upper bound on compact pill height. Beyond this the pill starts
    /// to dwarf the actual menu bar.
    static let maxCompactHeight: CGFloat = 44

    /// Fallback when the menu-bar height can't be inferred. 32pt is the
    /// midpoint of `[minCompactHeight, maxCompactHeight]`.
    static let defaultCompactHeight: CGFloat = 32

    // MARK: - Camera-shape radii

    /// The island is pinned to the top screen edge, so the top corners
    /// stay square like the physical camera cutout.
    static let cameraTopCornerRadius: CGFloat = 0

    enum CameraCornerRenderer: Equatable {
        case systemContinuousUnevenRectangle
    }

    /// Use SwiftUI's system continuous uneven-rectangle renderer for
    /// the bottom-only rounding. It produces cleaner antialiasing than
    /// the earlier hand-built `Path` at this tiny menu-bar scale.
    static let cameraCornerRenderer: CameraCornerRenderer = .systemContinuousUnevenRectangle

    /// Bottom corners use the fuller notch/camera radius while the surface
    /// itself is still rendered with SwiftUI's continuous corner geometry.
    static func cameraBottomCornerRadius(compactHeight: CGFloat) -> CGFloat {
        min(10, max(0, compactHeight * 0.32))
    }

    /// While the meeting nudge is attached directly below the island,
    /// the bottom edge becomes square so both panels read as one joined
    /// surface instead of leaving blue wedges at the corners.
    static func cameraBottomCornerRadius(
        compactHeight: CGFloat,
        meetingSuggestionActive: Bool
    ) -> CGFloat {
        meetingSuggestionActive ? 0 : cameraBottomCornerRadius(compactHeight: compactHeight)
    }

    // MARK: - Notch detection

    /// A non-zero `NSScreen.safeAreaInsets.top` is Apple's notched-screen
    /// sentinel on macOS 12+. We additionally require both aux areas to
    /// be present and non-empty before believing in a real notch — see
    /// `notchMetrics(safeAreaTopInset:auxiliaryTopLeftArea:auxiliaryTopRightArea:)`.
    static func hasNotch(safeAreaTopInset: CGFloat) -> Bool {
        safeAreaTopInset > 0
    }

    // MARK: - Menu-bar height

    /// `frame.maxY - visibleFrame.maxY` — canonical way to measure the
    /// menu-bar's vertical contribution on a given screen. On notched
    /// MacBooks this returns ~38pt (matches the notch height); on
    /// non-notched / external monitors it returns 24pt (the classic
    /// menu bar). If the menu bar is auto-hidden, returns 0.
    static func menuBarHeight(frame: NSRect, visibleFrame: NSRect) -> CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    private static func clampedCompactHeight(_ rawHeight: CGFloat) -> CGFloat {
        guard rawHeight > 0 else { return defaultCompactHeight }
        return min(max(rawHeight, minCompactHeight), maxCompactHeight)
    }

    /// Clamps the raw menu-bar height into the compact-pill height
    /// range. If the input is non-positive (e.g. menu bar auto-hidden
    /// or unknown), returns `defaultCompactHeight`.
    static func compactHeight(menuBarHeight: CGFloat) -> CGFloat {
        clampedCompactHeight(menuBarHeight)
    }

    /// Real notched displays report the camera band through
    /// `safeAreaInsets.top`. Prefer that over the menu-bar visible-frame
    /// delta because some scaled/resolution combinations differ by a
    /// point or more.
    static func compactHeight(
        menuBarHeight: CGFloat,
        safeAreaTopInset: CGFloat,
        isRealNotch: Bool
    ) -> CGFloat {
        if isRealNotch {
            return clampedCompactHeight(safeAreaTopInset)
        }
        return compactHeight(menuBarHeight: menuBarHeight)
    }

    // MARK: - Notch metrics

    /// Notch metrics resolved from the screen geometry. The compact
    /// pill wraps around `width`pt of horizontal space — the literal
    /// cutout on notched screens, or a synthetic placeholder on
    /// non-notched ones.
    struct NotchMetrics: Equatable {
        /// Horizontal width of the notch (or synthetic gap on
        /// non-notched screens).
        let width: CGFloat

        /// `true` if both aux areas were present and the safe-area
        /// inset was positive (i.e. there is a real hardware notch).
        /// `false` on external monitors and on degenerate inputs.
        let isRealNotch: Bool

        /// X coordinate of the LEFT edge of the notch in the screen's
        /// frame-relative coordinate system. `nil` when `isRealNotch`
        /// is `false` (caller should center on `frame.midX` instead).
        let leftEdgeX: CGFloat?
    }

    /// Resolves the notch metrics for a given screen. Defensive: even
    /// if `safeAreaTopInset > 0`, we require both aux areas to be
    /// non-empty before treating the layout as notched. On any failure
    /// path we return the synthetic placeholder so callers can fall
    /// back to a centered layout.
    static func notchMetrics(
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) -> NotchMetrics {
        guard
            hasNotch(safeAreaTopInset: safeAreaTopInset),
            let auxLeft = auxiliaryTopLeftArea,
            let auxRight = auxiliaryTopRightArea,
            !auxLeft.isEmpty,
            !auxRight.isEmpty
        else {
            return NotchMetrics(
                width: syntheticNotchWidth,
                isRealNotch: false,
                leftEdgeX: nil
            )
        }
        let leftEdge = auxLeft.maxX
        let rightEdge = auxRight.minX
        let width = max(0, rightEdge - leftEdge)
        // If the aux areas overlap (theoretically impossible but
        // we don't trust AppKit blindly), fall back to synthetic.
        guard width > 0 else {
            return NotchMetrics(
                width: syntheticNotchWidth,
                isRealNotch: false,
                leftEdgeX: nil
            )
        }
        return NotchMetrics(
            width: width,
            isRealNotch: true,
            leftEdgeX: leftEdge
        )
    }

    static func notchMetrics(on screen: IslandScreenDescriptor) -> NotchMetrics {
        notchMetrics(
            safeAreaTopInset: screen.safeAreaTopInset,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    // MARK: - Frame computation

    /// Computes the screen-space frame for the Dynamic Island panel.
    ///
    /// - Pill literally wraps the notch cutout. `pill.minX = notch.minX
    ///   - leftSideWidth`, `pill.maxX = notch.maxX + rightSideWidth`.
    /// - On non-notched screens the pill is top-centered with a
    ///   synthetic notch gap (`syntheticNotchWidth`pt) in the middle
    ///   so the design language stays consistent.
    /// - Compact height = real safe-area notch height on notched MBPs,
    ///   clamped menu-bar height on external monitors.
    /// - Top edge of pill = `frame.maxY` (top of physical screen,
    ///   above the menu bar). `IslandPanel` overrides
    ///   `constrainFrameRect` so AppKit's default menu-bar clamp
    ///   doesn't push it down.
    static func islandFrame(
        frame: NSRect,
        visibleFrame: NSRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) -> NSRect {
        let metrics = notchMetrics(
            safeAreaTopInset: safeAreaTopInset,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )

        let menuBar = menuBarHeight(frame: frame, visibleFrame: visibleFrame)

        let width = leftSideWidth + metrics.width + rightSideWidth
        let height = compactHeight(
            menuBarHeight: menuBar,
            safeAreaTopInset: safeAreaTopInset,
            isRealNotch: metrics.isRealNotch
        )

        let topEdge = frame.maxY
        let originY = topEdge - height

        let originX: CGFloat
        if metrics.isRealNotch, let notchLeft = metrics.leftEdgeX {
            // Pill straddles the notch: left side panel sits to the
            // left of the notch, right side panel sits to the right.
            originX = notchLeft - leftSideWidth
        } else {
            // Non-notched: top-centered with the synthetic notch
            // placeholder in the middle.
            originX = frame.midX - width / 2
        }

        return NSRect(
            x: originX,
            y: originY,
            width: width,
            height: height
        )
    }

    static func islandFrame(on screen: IslandScreenDescriptor) -> NSRect {
        islandFrame(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaTopInset,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    /// Transparent host window frame. The visible compact camera stays
    /// top-flush, while the extra height below it gives hover-only
    /// controls room to render without resizing the AppKit window.
    ///
    /// When `agentActive` is `true` the window also reserves the agent
    /// zones: it grows RIGHTWARD by `rightAgentZoneWidth` for the wing and
    /// DOWNWARD by `agentWingGap + agentAnswerZoneHeight` for the answer
    /// panel. The right edge moves out (`maxX` grows), `minX` is left
    /// untouched so the capsule stays straddling the notch, and — like the
    /// hover-panel expansion above — the origin drops by the added height
    /// so the top edge stays pinned to the menu bar (AppKit y-up: lowering
    /// `origin.y` while growing `height` keeps `maxY` fixed).
    static func hostPanelFrame(
        frame: NSRect,
        visibleFrame: NSRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?,
        expanded: Bool = true,
        agentActive: Bool = false
    ) -> NSRect {
        let compactFrame = islandFrame(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTopInset: safeAreaTopInset,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )
        var result = compactFrame
        if expanded {
            let height = compactFrame.height + IslandDropModeControl.hoverPanelHeight
            result = NSRect(
                x: compactFrame.minX,
                y: compactFrame.maxY - height,
                width: compactFrame.width,
                height: height
            )
        }
        if agentActive {
            let addedHeight = agentWingGap + agentAnswerZoneHeight
            result.size.width += rightAgentZoneWidth
            result.size.height += addedHeight
            result.origin.y -= addedHeight
        }
        return result
    }

    static func hostPanelFrame(
        on screen: IslandScreenDescriptor,
        expanded: Bool = true,
        agentActive: Bool = false
    ) -> NSRect {
        hostPanelFrame(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaTopInset,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            expanded: expanded,
            agentActive: agentActive
        )
    }

    /// Frame for the left-side notification surface that morphs the island
    /// LEFTWARD. The notification reads as one joined surface with the island:
    /// its right edge stays pinned to the compact frame's right edge, its top
    /// edge stays flush with the screen top, and its height stays exactly the
    /// compact island height.
    ///
    /// - When `expanded` is `false` the compact island frame is returned
    ///   unchanged, so callers can drive the morph by toggling the flag.
    static func leftNotificationFrame(
        frame: NSRect,
        visibleFrame: NSRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?,
        expanded: Bool = true
    ) -> NSRect {
        let compactFrame = islandFrame(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTopInset: safeAreaTopInset,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )
        guard expanded else {
            return compactFrame
        }
        let width = compactFrame.width + leftNotificationWidth
        let height = compactFrame.height
        let originX = compactFrame.minX - leftNotificationWidth
        let originY = compactFrame.maxY - height

        return NSRect(
            x: originX,
            y: originY,
            width: width,
            height: height
        )
    }

    static func leftNotificationFrame(
        on screen: IslandScreenDescriptor,
        expanded: Bool = true
    ) -> NSRect {
        leftNotificationFrame(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaTopInset,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            expanded: expanded
        )
    }
}
