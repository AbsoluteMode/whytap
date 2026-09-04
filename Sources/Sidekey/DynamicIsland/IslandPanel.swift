import AppKit
import Combine
import os.log
import SwiftUI

#if DEBUG
/// DEBUG-only hit-test tracing for the hover-gated music strip. File-level
/// (the hosting view is generic, which forbids static stored properties).
/// Compiled out of release. Andrey can correlate this with the
/// transport-button action log (same subsystem `com.sidekey.nowplaying`,
/// category `hittest`) to see exactly where the click chain breaks on-device.
private let islandMusicStripHitTestLog = OSLog(
    subsystem: "com.sidekey.nowplaying",
    category: "hittest"
)
#endif

/// Pure geometry for agent-surface hit zones inside the (already
/// enlarged) host window bounds. Top-right anchored like the rest of the
/// island stack.
struct IslandAgentHitZones {
    let boundsSize: CGSize
    let compactSize: CGSize
    let rightAgentZoneWidth: CGFloat
    let wingWidth: CGFloat
    let wingGap: CGFloat
    let answerSize: CGSize

    /// Wing zone: the part of the agent face that OVERFLOWS the right band
    /// (its extension). The content begins inside the capsule's right band
    /// and runs past the capsule's right edge; this rect covers only the
    /// overflow, whose left edge sits exactly at the capsule's right edge
    /// (`boundsSize.width - rightAgentZoneWidth`). `wingWidth` here is the
    /// face's EXTENSION (`IslandPanel.syncAgentSurfaces` passes
    /// `agentWingExtension`), not its full width — the in-band part is
    /// already hit-tested by the compact island's own rect.
    var wingRect: CGRect {
        CGRect(
            x: boundsSize.width - rightAgentZoneWidth,
            y: boundsSize.height - compactSize.height,
            width: wingWidth,
            height: compactSize.height
        )
    }

    /// Answer panel: below the capsule row, right edge aligned to the
    /// RECORDING form's right edge (matches `agentAnswerLayer`'s trailing
    /// pad in `IslandView` — the two must stay in lockstep or clicks miss).
    /// The form grows only by the recording face's EXTENSION, so the right
    /// edge is `wingRect.minX + agentWingRecordingExtension`.
    var answerRect: CGRect {
        // Centred under the pill (hover-panel geometry): the card's right edge
        // sits at the pill's right edge (`wingRect.minX` == window right minus
        // the wing zone), so a pill-width card is centred under the notch — the
        // same dorozhka the hover panel uses. Must stay in lockstep with
        // `IslandView.agentAnswerLayer`'s trailing pad (`rightAgentZoneWidth`).
        return CGRect(
            x: wingRect.minX - answerSize.width,
            y: boundsSize.height - compactSize.height - wingGap - answerSize.height,
            width: answerSize.width,
            height: answerSize.height
        )
    }

    /// Window-level hotspot for the answer panel's ✕ close control. The ✕
    /// is a SwiftUI Button, but in this non-activating, never-key panel the
    /// AppKit→SwiftUI bridge drops the first-mouse click before any SwiftUI
    /// gesture sees it (live trace: the window's sendEvent receives the
    /// click, hitTest resolves to the hosting view, and nothing fires —
    /// neither the Button action nor an `acceptsFirstMouse` NSView overlay).
    /// So the WINDOW intercepts clicks geometrically in `sendEvent` and
    /// dismisses directly. The rect mirrors the rendered cluster: a
    /// control-sized box at the answer panel's top-right (the [Esc ✕] row
    /// sits in the `agentWingGap` band right above the card), padded with a
    /// few points of slop on every side so near-misses still close.
    var answerCloseHotspot: CGRect {
        // The close controls ([Esc] [✕]) now live in the WING (the
        // `.answerControls` face), not over the card — so the whole cluster is
        // the dismiss target: a click anywhere on it cancels the flow. The
        // cluster sits in the compact-row band; its right edge is the controls
        // face's right edge (pill right `wingRect.minX` + the face's small
        // extension), and it is `agentWingAnswerControlsWidth` wide.
        let slop: CGFloat = 4
        let controlsWidth = IslandFrameLayout.agentWingAnswerControlsWidth
        let ext = IslandFrameLayout.agentWingExtension(faceWidth: controlsWidth)
        let right = wingRect.minX + ext
        return CGRect(
            x: right - controlsWidth - slop,
            y: boundsSize.height - compactSize.height - slop,
            width: controlsWidth + slop * 2,
            height: compactSize.height + slop * 2
        )
    }

    /// Window-level hotspot for the Retry pill in the total-offline
    /// `.deliveryFailed` Drop wing (Task 7). Same rationale as
    /// `answerCloseHotspot`: in this non-key, non-activating panel the
    /// AppKit→SwiftUI bridge drops the first-mouse click before any SwiftUI
    /// gesture fires, so `IslandPanel.sendEvent` intercepts the click
    /// geometrically and invokes `retryDelivery` directly. The pill hugs the
    /// face's trailing (right) edge; this covers the rightmost slice of the
    /// `.deliveryFailed` face (pill + its padding) plus slop so near-misses
    /// still retry. `wingRect` already covers the face's full extension, so the
    /// hotspot is clamped within it.
    var deliveryRetryHotspot: CGRect {
        let slop: CGFloat = 4
        // Width of the trailing Retry pill + its capsule padding, generous so
        // the whole control is clickable. Independent of the face width so the
        // message text to its left is NOT a retry target.
        let pillTargetWidth: CGFloat = 84
        let ext = IslandFrameLayout.agentWingExtension(
            faceWidth: IslandFrameLayout.agentWingDeliveryFailedWidth
        )
        let right = wingRect.minX + ext
        return CGRect(
            x: right - pillTargetWidth - slop,
            y: boundsSize.height - compactSize.height - slop,
            width: pillTargetWidth + slop * 2,
            height: compactSize.height + slop * 2
        )
    }
}

/// Pure geometry + gating for the hover-gated Now Playing player strip's
/// dedicated hit zone. The strip lives in the gap BETWEEN the compact pill
/// and the hover panel (top of the hover drawer), offset DOWN from the pill
/// by `musicStripTopGap`, at the full `compactWidth`, `musicStripHeight` tall.
///
/// **Why a dedicated zone.** The strip's transport buttons are SwiftUI
/// `Button`s in a non-key, non-activating `NSPanel`. Relying on the generic
/// expanded island rect to route their clicks failed on-device (the strip's
/// screen region did not deliver clicks even though, by the band-height
/// math, it sits inside that rect). The always-on `agentActive` /
/// `notificationActive` zones are explicit `union`ed rects that DO receive
/// events reliably; this mirrors them for the strip. When
/// `musicStripActive && acceptsExpandedHitTesting`, `stripRect` is unioned
/// into BOTH `ClickThroughHostingView.acceptsEvent` / `hitTest` and the
/// mouse-active frames (so the window stops ignoring mouse events over the
/// strip band).
struct IslandMusicStripHitZone {
    let boundsSize: CGSize
    let compactSize: CGSize
    let rightAgentZoneWidth: CGFloat
    let topGap: CGFloat
    let stripHeight: CGFloat

    /// Strip rect in host bounds-space (AppKit y-up, origin bottom-left,
    /// `boundsSize.height` = the permanently agent-sized window height).
    ///
    /// - Right edge pinned to the compact island's right edge
    ///   (`bounds.width - rightAgentZoneWidth`) — same anchor `acceptsEvent`
    ///   uses for the expanded island rect, so the strip stays trailing-aligned
    ///   under the pill.
    /// - Top edge is `compactHeight + topGap` below the window top; the rect is
    ///   `stripHeight` tall (lower the origin, grow up to that top edge).
    ///
    /// This computed band already covers the strip's transport buttons
    /// (on-device `acceptsEvent` reports `accepted=1` over them). The clicks
    /// still never reached the SwiftUI `Button`s in this non-key,
    /// non-activating panel — so `IslandPanel.sendEvent` intercepts transport
    /// clicks geometrically against `transportButtonRects(stripRect:)` and
    /// invokes the action directly, exactly as the answer panel's ✕ close
    /// hotspot does. The rect here keeps the band mouse-active so `sendEvent`
    /// actually receives the click.
    var stripRect: CGRect {
        let rightEdge = boundsSize.width - rightAgentZoneWidth
        let topFromWindowTop = compactSize.height + topGap
        return CGRect(
            x: rightEdge - compactSize.width,
            y: boundsSize.height - topFromWindowTop - stripHeight,
            width: compactSize.width,
            height: stripHeight
        )
    }

    /// The three transport-button hotspot rects inside a strip rect, in the
    /// SAME coordinate space as `stripRect` (the caller decides whether that is
    /// host bounds-space for `hitTest` or window-space for `sendEvent` — both
    /// share origin and axes here because the host fills the window content).
    ///
    /// Layout mirror of `IslandMusicStripView`'s transport `HStack`: the three
    /// buttons sit at the strip's TRAILING end, inset by `horizontalPadding`
    /// from the strip's right edge, each `buttonSize` wide, `spacing` apart,
    /// vertically centered in the strip. Right-to-left the order rendered is
    /// `next` (rightmost), `playPause`, `previous` — so the returned tuple
    /// reflects that: `next.maxX` is the rightmost edge (minus the inset),
    /// `playPause` one button + spacing to its left, `previous` one more.
    ///
    /// Pure + testable: the click dispatch in `sendEvent` and the unit test
    /// both build the rects from here, so a layout-constant change can never
    /// silently desync the hit math from the render.
    ///
    /// `isLive` (radio / live stream): the strip renders ONLY play/pause and
    /// it occupies the rightmost slot `next` normally holds. `previous` and
    /// `next` are returned as `.null` — `CGRect.null.contains(_:)` is always
    /// false, so prev/next can never fire in live mode. This mirrors
    /// `IslandMusicStripView`, which hides prev/next and pins play/pause to the
    /// trailing edge while `snapshot.isLive`.
    static func transportButtonRects(
        stripRect: CGRect,
        isLive: Bool
    ) -> (previous: CGRect, playPause: CGRect, next: CGRect) {
        let buttonSize = IslandMusicStrip.transportButtonSize
        let spacing = IslandMusicStrip.transportSpacing
        let inset = IslandMusicStrip.horizontalPadding
        let y = stripRect.midY - buttonSize / 2

        // `next` is rightmost: its right edge sits one `horizontalPadding`
        // inside the strip's right edge.
        let nextMinX = stripRect.maxX - inset - buttonSize
        let playPauseMinX = nextMinX - spacing - buttonSize
        let previousMinX = playPauseMinX - spacing - buttonSize

        func rect(_ minX: CGFloat) -> CGRect {
            CGRect(x: minX, y: y, width: buttonSize, height: buttonSize)
        }

        if isLive {
            // Only play/pause, pinned to the rightmost slot.
            return (previous: .null, playPause: rect(nextMinX), next: .null)
        }
        return (
            previous: rect(previousMinX),
            playPause: rect(playPauseMinX),
            next: rect(nextMinX)
        )
    }

    /// Which transport button (if any) `point` falls over — the hover twin of
    /// the click dispatch in `sendEvent`. Built from the SAME
    /// `transportButtonRects`, so the hover highlight and click routing can
    /// never desync. `nil` when the point is over no button (gaps, artwork,
    /// title). In live mode only the rightmost play/pause can match.
    // WHY: docs/decisions/2026-06-16-island-music-progress-and-gap.md
    static func transportButton(
        at point: CGPoint,
        stripRect: CGRect,
        isLive: Bool
    ) -> MusicTransportButton? {
        let rects = transportButtonRects(stripRect: stripRect, isLive: isLive)
        // `.null.contains(_:)` is always false, so prev/next never match in live
        // mode (their rects are `.null`).
        if rects.next.contains(point) { return .next }
        if rects.playPause.contains(point) { return .playPause }
        if rects.previous.contains(point) { return .previous }
        return nil
    }

    /// The dedicated zone is hittable iff a track is active AND the island is
    /// hover-expanded — exactly the state in which the strip is rendered.
    static func isActive(
        musicStripActive: Bool,
        acceptsExpandedHitTesting: Bool
    ) -> Bool {
        musicStripActive && acceptsExpandedHitTesting
    }
}

/// `NSHostingView` subclass that forwards mouse events only inside the
/// rendered island bounds.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    /// Compact-pill rendered size. Set by `IslandPanel` when the frame
    /// is computed.
    var compactSize: CGSize = CGSize(
        width: IslandFrameLayout.leftSideWidth
            + IslandFrameLayout.syntheticNotchWidth
            + IslandFrameLayout.rightSideWidth,
        height: IslandFrameLayout.defaultCompactHeight
    )
    var expandedSize: CGSize = CGSize(
        width: IslandFrameLayout.leftSideWidth
            + IslandFrameLayout.syntheticNotchWidth
            + IslandFrameLayout.rightSideWidth,
        height: IslandFrameLayout.defaultCompactHeight + IslandDropModeControl.hoverPanelHeight
    )
    var acceptsExpandedHitTesting = false

    /// Width of the active left morph zone (the notification pill). `0` when
    /// no notification is on screen. When non-zero the window has grown
    /// leftward by this amount and the island content is trailing-aligned, so
    /// the hittable region spans the full bounds width (pill + island) instead
    /// of the usual centered compact/expanded rect.
    var leftZoneWidth: CGFloat = 0

    /// Agent surfaces: zero/nil when the agent flow is idle. The window is
    /// PERMANENTLY grown RIGHTWARD by `rightAgentZoneWidth` (and downward),
    /// so the compact/expanded right anchor below ALWAYS shifts left by that
    /// amount (see `acceptsEvent`). `agentActive` gates only whether these
    /// wing/answer rects are hittable — when idle the reserved zone is empty
    /// and transparent.
    var agentWingWidth: CGFloat = 0
    var agentAnswerSize: CGSize = .zero
    var agentActive: Bool = false

    /// `true` while the wing shows the persistent total-offline Drop-delivery
    /// failure (`IslandAgentFlowStore.Wing.deliveryFailed`, Task 7). Read by
    /// `IslandPanel.sendEvent` so a click on the wing's trailing Retry pill
    /// fires `retryDelivery` — same window-level dispatch the answer ✕ uses,
    /// because the AppKit→SwiftUI bridge drops first-mouse clicks in this
    /// non-key, non-activating panel.
    var agentRetryActive: Bool = false

    /// `true` while a Now Playing track is active (mirrors
    /// `AppState.nowPlaying != nil`). Gated with `acceptsExpandedHitTesting`
    /// (hover-expanded) so the dedicated strip hit zone is hittable ONLY when
    /// the strip is actually rendered. See `IslandMusicStripHitZone`.
    var musicStripActive: Bool = false

    /// `true` while the active Now Playing item is radio / a live stream
    /// (mirrors `AppState.nowPlaying?.isLive`). Read by `sendEvent`'s transport
    /// dispatch so the geometric hit rects collapse to a single rightmost
    /// play/pause button, matching the strip's live-mode render.
    var musicIsLive: Bool = false

    /// `true` while the compact pill is faded out to the bare notch after the
    /// idle timeout (`AppState.idleVisibility == .hiddenIdle`). Collapses the
    /// compact hit-rect to nothing so the invisible pill is click-through — the
    /// window keeps its geometry (never `orderOut`) but claims no compact clicks.
    /// The blocker set (spec §3) guarantees this is only ever `true` when no
    /// agent / notification / music / hover surface is present, so gating the
    /// compact rect alone is sufficient.
    var idleHidden: Bool = false

    /// The strip's dedicated hit zone for the current bounds — `nil` unless a
    /// track is active AND the island is hover-expanded (so the strip is on
    /// screen). Mirrors the always-on `agentActive` / `notificationActive`
    /// explicit zones, which reliably receive events where the generic
    /// expanded rect did not.
    ///
    /// The computed band (`IslandMusicStripHitZone.stripRect`) already covers
    /// the strip's transport buttons; keeping it mouse-active is what lets the
    /// window's `sendEvent` receive the transport clicks, which it then routes
    /// geometrically to the matching action (the strip's SwiftUI `Button`s
    /// never receive the click in this non-key panel — see
    /// `IslandPanel.sendEvent`).
    private var musicStripRect: CGRect? {
        guard IslandMusicStripHitZone.isActive(
            musicStripActive: musicStripActive,
            acceptsExpandedHitTesting: acceptsExpandedHitTesting
        ) else { return nil }
        return IslandMusicStripHitZone(
            boundsSize: bounds.size,
            compactSize: compactSize,
            rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
            topGap: IslandDropModeControl.musicStripTopGap,
            stripHeight: IslandDropModeControl.musicStripHeight
        ).stripRect
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsEvent(at: point) else { return nil }
        return super.hitTest(point)
    }

    private func acceptsEvent(at point: NSPoint) -> Bool {
        if agentActive {
            let zones = IslandAgentHitZones(
                boundsSize: bounds.size,
                compactSize: compactSize,
                rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
                wingWidth: agentWingWidth,
                wingGap: IslandFrameLayout.agentWingGap,
                answerSize: agentAnswerSize
            )
            if agentWingWidth > 0, zones.wingRect.contains(point) { return true }
            if agentAnswerSize != .zero, zones.answerRect.contains(point) { return true }
        }

        // The Now Playing player strip is hover-gated: it lives at the top of
        // the hover drawer (between the island and the hover panel). Its
        // transport buttons are SwiftUI `Button`s in this non-key,
        // non-activating panel; relying on the generic expanded island rect to
        // route their clicks failed on-device even though the strip band sits
        // inside that rect by the band-height math. So we UNION an explicit
        // dedicated strip zone — the same mechanism the always-on `agentActive`
        // / `notificationActive` zones use, which DO receive events reliably.
        if let stripRect = musicStripRect {
            let inStrip = stripRect.contains(point)
            #if DEBUG
            os_log(
                "strip hittest point=(%{public}.1f,%{public}.1f) rect=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f) expanded=%{public}d musicActive=%{public}d accepted=%{public}d",
                log: islandMusicStripHitTestLog,
                type: .debug,
                point.x, point.y,
                stripRect.origin.x, stripRect.origin.y, stripRect.width, stripRect.height,
                acceptsExpandedHitTesting ? 1 : 0,
                musicStripActive ? 1 : 0,
                inStrip ? 1 : 0
            )
            #endif
            if inStrip { return true }
        }

        // Idle-hidden: the compact pill is faded to the bare notch, so it must
        // not eat clicks — the window stays put but the compact content is
        // click-through. The agent / notification / music surfaces are checked
        // ABOVE and still claim their clicks if present (defense-in-depth; the
        // blocker set means they aren't while idle). Only the compact/expanded
        // island rect below is suppressed.
        if idleHidden {
            return false
        }

        let activeSize = IslandPanelFramePolicy.hitTestSize(
            compactSize: compactSize,
            expandedSize: expandedSize,
            acceptsExpandedHitTesting: acceptsExpandedHitTesting
        )
        // Island content is trailing-aligned, so its right edge is always the
        // bounds right edge — and the window is now permanently
        // `leftNotificationWidth` wider than the compact content (the left
        // morph zone is always reserved). So the active hit rect must be pinned
        // FLUSH-RIGHT in both cases, never centered: a centered rect would sit
        // ~leftNotificationWidth/2 too far left and drop clicks on the right of
        // the compact island (e.g. the meeting-recording Stop button).
        //   - no notification (`leftZoneWidth == 0`): the rect is exactly the
        //     trailing-aligned compact/expanded island content.
        //   - notification active: extend leftward across the left zone so the
        //     pill is clickable too.
        // The window is now PERMANENTLY agent-sized — it always reserves
        // `rightAgentZoneWidth` on the right, whether or not the agent flow is
        // on screen (the allocate-and-hit-test-gate pattern). So the
        // compact/expanded island content never sits at the bounds right edge:
        // its right edge is UNCONDITIONALLY inset by that amount. Shift the
        // right anchor left so the capsule (e.g. its trailing controls) stays
        // clickable regardless of agent state. When the agent flow is idle the
        // reserved zone is empty + transparent and the wing/answer rects above
        // are not hittable, so nothing in it claims clicks.
        let rightEdge = bounds.width - IslandFrameLayout.rightAgentZoneWidth
        let originX: CGFloat
        let width: CGFloat
        if leftZoneWidth > 0 {
            originX = rightEdge - activeSize.width - leftZoneWidth
            width = activeSize.width + leftZoneWidth
        } else {
            originX = rightEdge - activeSize.width
            width = activeSize.width
        }
        let activeRect = NSRect(
            x: originX,
            y: bounds.height - activeSize.height,
            width: width,
            height: activeSize.height
        )
        return activeRect.contains(point)
    }
}

enum IslandPanelFramePolicy {
    static func windowFrame(
        compactFrame: NSRect,
        expandedFrame: NSRect,
        acceptsExpandedHitTesting: Bool
    ) -> NSRect {
        // Keep the top-level window stable; mouse routing below decides
        // whether only the compact island or the full hover panel is active.
        expandedFrame
    }

    static func hitTestSize(
        compactSize: CGSize,
        expandedSize: CGSize,
        acceptsExpandedHitTesting: Bool
    ) -> CGSize {
        acceptsExpandedHitTesting ? expandedSize : compactSize
    }
}

enum IslandPanelMouseEventPolicy {
    /// The idle WAKE zone (founder feedback 2026-07-06): the compact pill's
    /// SCREEN rect (`IslandFrameLayout.islandFrame` — centered under the
    /// notch) inflated by `padding`. The window itself is permanently
    /// agent-wide, so gating the wake on `windowFrame.contains` made ANY
    /// mouse sweep across the top of the screen reveal the island; and the
    /// pill is NOT window-edge-aligned, so deriving its rect from the window
    /// frame put the zone off the pill entirely (second founder report:
    /// hover didn't wake at all). Take the authoritative screen-space rect.
    static func idleWakeZone(compactFrame: NSRect, padding: CGFloat) -> NSRect {
        compactFrame.insetBy(dx: -padding, dy: -padding)
    }

    /// `true` when the window should ignore the mouse at `cursor` — i.e. the
    /// cursor is over NONE of the rendered island surfaces. The window is a
    /// transparent, permanently agent-sized overlay; it must claim events over
    /// each rendered rect individually and pass everything else through.
    static func shouldIgnoreMouseEvents(cursor: NSPoint, activeFrames: [NSRect]) -> Bool {
        // Membership in ANY rendered rect — NOT their bounding union. A union
        // would re-open the dead-zone: the empty gap between the pill, wing and
        // answer card falls inside the bbox but over no content, so AppKit would
        // eat the event (ignoresMouseEvents == false + hitTest nil) instead of
        // passing it to the app below.
        !activeFrames.contains { $0.contains(cursor) }
    }

    /// The screen-space rects the window claims mouse events over — one per
    /// RENDERED island surface, never a bounding union (see
    /// `shouldIgnoreMouseEvents`). Pure so the per-surface gating stays
    /// unit-testable: every rect listed here MUST have visible content behind
    /// it, because a claimed rect over nothing eats the event (`hitTest` nil)
    /// instead of passing it to the app below.
    static func activeFrames(
        compactFrame: NSRect,
        expandedFrame: NSRect,
        leftNotificationFrame: NSRect,
        musicStripFrame: NSRect,
        agentSurfaceFrames: [NSRect],
        idleHidden: Bool,
        expanded: Bool,
        notificationActive: Bool,
        musicStripActive: Bool
    ) -> [NSRect] {
        var frames: [NSRect] = []
        // Idle-hidden: the compact pill is faded to the bare notch, so its rect
        // must NOT claim mouse events (the invisible pill would eat clicks). The
        // blocker set guarantees no agent / notification / music surface is up
        // while idle, so this simply drops the compact/expanded content frame.
        if !idleHidden {
            frames.append(expanded ? expandedFrame : compactFrame)
        }
        if notificationActive {
            frames.append(leftNotificationFrame)
        }
        // The player strip is a hover-gated band with its own transport hit zone
        // (`IslandMusicStripHitZone`); list its precise rect so the window claims
        // the strip without re-introducing a coarse expanded-frame union. Gated
        // by the SAME predicate as `hitTest` / the `sendEvent` transport
        // dispatch: the strip renders only while hover-expanded, so claiming
        // its band on `musicStripActive` alone left an invisible click-eating
        // strip under the compact pill whenever a track was playing (window
        // controls right under the island stopped responding).
        // WHY: docs/decisions/2026-07-16-music-strip-claim-hover-gate.md
        if IslandMusicStripHitZone.isActive(
            musicStripActive: musicStripActive,
            acceptsExpandedHitTesting: expanded
        ) {
            frames.append(musicStripFrame)
        }
        frames.append(contentsOf: agentSurfaceFrames)
        return frames
    }

    /// Hit-zone size for the agent answer card. Tracks the ACTUAL rendered card
    /// height so the claimed rect ends with the visible card — a fixed
    /// reservation left a tall empty band below short answers that ate clicks
    /// for windows underneath the screenSaver-level island. `.zero` until the
    /// card is measured (and when hidden) so no premature dead zone opens.
    static func agentAnswerHitSize(visible: Bool, contentHeight: CGFloat, width: CGFloat) -> CGSize {
        guard visible, contentHeight > 0 else { return .zero }
        return CGSize(width: width, height: contentHeight)
    }
}

/// Borderless panel hosting the Dynamic Island PoC view. The pill
/// wraps the macOS notch — compact pill straddles the cutout (orb on
/// the left of the notch, hover-only trigger orbs on the right).
///
/// **Lifecycle**: `IslandPanel.shared` lazily constructs a single
/// panel on first access. `show()` / `hide()` / `toggle()` are
/// idempotent.
///
/// The hosted `IslandView` derives its live visual state from
/// `AppState.phase` and `AppState.agentPhase`.
@MainActor
final class IslandPanel: NSPanel {

    static let shared = IslandPanel()

    /// Apply the Settings -> Other "Screenshot protection" toggle to the live
    /// island window. `.none` hides the panel from screenshots / screen
    /// shares; `.readOnly` is AppKit's default (visible, not remotely
    /// controllable).
    static func setScreenshotProtectionEnabled(_ enabled: Bool) {
        shared.sharingType = enabled ? .none : .readOnly
    }

    private var isShown: Bool = false

    /// Strong-typed reference to the hosting view so we can update its
    /// compact/expanded hit-test sizes on screen changes.
    private var host: ClickThroughHostingView<IslandView>!
    private var acceptsKeyboardFocus = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    /// Height of the hover band below the compact island. Defaults to the
    /// tile-grid band; `IslandView` reports a taller band while the History
    /// inline panel is on screen (`onHoverPanelBandHeightChange`) so the
    /// hit-test rect and mouse routing cover the full panel — without this
    /// the lower half of a tall panel ignores hover/clicks.
    private var hoverBandHeight: CGFloat = IslandDropModeControl.hoverPanelHeight

    /// Always `false` since the notification pill moved to
    /// the removed notification overlay; the left-zone geometry it used to drive is
    /// retired with it (Approach B).
    private var notificationActive = false

    /// `true` while a Now Playing track is active (mirrors
    /// `AppState.nowPlaying != nil`). Drives the dedicated hover-gated strip
    /// hit zone: combined with the hover state (`acceptsExpandedHitTesting`)
    /// it gates `IslandMusicStripHitZone` so the strip's transport buttons get
    /// an explicit, proven mouse-active region — the same union mechanism the
    /// agent / notification zones use. Mirrored from `AppState.nowPlaying`.
    private var musicStripActive = false
    private var musicStripCancellable: AnyCancellable?

    /// Live-stream flag mirrored from `AppState.nowPlaying?.isLive`, threaded
    /// onto the host so `sendEvent` collapses the transport hit rects to a
    /// single rightmost play/pause for radio. Parallel to `musicStripActive`.
    private var musicIsLive = false
    private var musicIsLiveCancellable: AnyCancellable?

    /// Local mirror of `AppState.idleVisibility == .hiddenIdle`. Threaded onto
    /// the host to gate the compact hit-rect (click-through while idle) and
    /// mirrored via `AppState` into `IslandView` for the fade-out.
    private var idleHidden = false
    private var idleVisibilityCancellable: AnyCancellable?

    /// Fired when a mouse event lands inside the island's window frame — the
    /// broad wake-zone (spec §4.1). Wired by `AppDelegate` to the idle
    /// controller's `registerActivity()`, which wakes `.hiddenIdle → .active`
    /// instantly and resets the idle timer. Carries NO event payload
    /// (invariant #3). Default no-op so the panel works before wiring.
    var onIslandMouseActivity: () -> Void = {}

    /// Fired when the cursor enters/leaves the island's rendered content
    /// (blocker B10, spec §3). Wired by `AppDelegate` to the controller's
    /// `setHovered(_:)` so a stationary hover holds `.active`. Default no-op.
    var onIslandHoverChange: (Bool) -> Void = { _ in }

    /// Whether the cursor was over island content on the last routing pass —
    /// so `onIslandHoverChange` fires only on the edge, not every mouse move.
    private var islandHovered = false

    /// Presentation state for the island agent surfaces. Created with a
    /// standalone `AskResponseStore` so the view mounts before the routing
    /// task connects the real one; `installAgentFlow(store:)` swaps in the
    /// store backed by `AgentController.responseStore` (same instance the
    /// agent streams into) once the controller exists.
    private(set) var agentFlow = IslandAgentFlowStore(responseStore: AskResponseStore())
    private let agentComposerPanel = IslandAgentComposerPanel()

    /// Selection chip state for the answer panel's useful-links block.
    let agentLinksSelection = UsefulLinksSelectionState()

    /// Agent-flow action closures wired by the routing task (Task 10) from
    /// where `AgentController` is created. The composing wing's submit /
    /// cancel and the answer panel's dismiss funnel through these. Default
    /// to no-op so the panel renders before the controller exists; setting
    /// them rebuilds the rootView so the captured closures are live.
    private var agentSubmitText: (String) -> Void = { _ in }
    private var agentCancelFlow: () -> Void = {}

    private var agentFlowCancellable: AnyCancellable?

    /// Local Cmd+C / Cmd+A monitor active while the island answer panel is
    /// visible. Replaces the legacy `AgentResponsePanel.performKeyEquivalent`
    /// override — the island panel hosts the answer body now, so copy /
    /// select-all on streamed text dispatch through the responder chain here.
    private var agentAnswerEditingMonitor: Any?
    private var agentAnswerVisibleCancellable: AnyCancellable?

    /// Measured height of the rendered answer card, reported by `IslandView`.
    /// Drives the answer hit-zone so it ends with the visible card instead of a
    /// fixed reservation (see `agentAnswerHitSize`). `0` until first measured.
    private var agentAnswerContentHeight: CGFloat = 0

    /// `true` while the agent surfaces (wing capsule + answer panel) are
    /// presented. Drives the rightward + downward window-frame growth via
    /// `IslandFrameLayout.hostPanelFrame(agentActive:)` and the agent
    /// hit-zone routing. Mirrors `host?.agentActive`; defaults off so the
    /// no-agent layout is bit-for-bit the previous behavior.
    private var agentActive: Bool { host?.agentActive ?? false }

    /// Production-wired action closures fired by the trigger orbs.
    /// Setting this rebuilds the rootView with the new closures captured.
    /// Defaults to `.noOp` so the panel
    /// renders before `AppDelegate` wires real handlers; the production
    /// call site overwrites this before `show()`.
    var actions: IslandActions = .noOp {
        didSet {
            // Rebuild rootView so the new closures are captured by the
            // SwiftUI view's `actions` constant. The layout-only fields
            // (compactHeight / compactWidth / notchWidth) come from the
            // last computed layout — re-read via `applyCurrentLayout`
            // so this setter works even if the screen changed between
            // `show()` and `actions = ...`.
            applyCurrentLayout(display: false)
        }
    }

    private init() {
        let layout = Self.computeLayout()
        let initialFrame = layout.windowFrame(
            expandedHitTesting: false,
            notificationActive: false
        )
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Unlike `FloatingDotPanel` / status-bar overlays, this panel
        // wraps the notch and renders ON TOP of the macOS menu-bar
        // y-band — the compact pill is entirely inside the menu-bar
        // height. `.statusBar` (25) is not enough on macOS 14+: the
        // system menu bar empirically renders above it, hiding the pill.
        self.collectionBehavior = [
            // macOS 13+: lets a high-level (`.screenSaver`) overlay appear
            // inside ANOTHER app's full-screen Space. Without it the notch
            // surfaces vanish over a foreign fullscreen window (e.g. Dia /
            // Chromium); the history strip avoids this only by sitting at the
            // lower `.statusBar` level, where `.canJoinAllSpaces` alone suffices.
            // WHY: docs/decisions/2026-06-24-overlay-foreign-fullscreen.md
            .canJoinAllApplications,
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.isFloatingPanel = true
        // Screenshot protection (Settings -> Other): when the user opts in,
        // the island (transcripts, agent answers, history cards) is excluded
        // from screenshots and screen shares. Applied live by
        // `setScreenshotProtectionEnabled`.
        self.sharingType = PrivacyPreferences.shared.screenshotProtectionEnabled ? .none : .readOnly
        self.ignoresMouseEvents = true // Global mouse monitor enables only the active island rect.
        // SwiftUI `.onHover` inside the panel (the music strip's transport
        // buttons) relies on tracking-area mouseEntered/Exited delivery. In a
        // non-activating panel those arrive unreliably unless the window opts
        // into moved-mouse events — without this the buttons' hover highlight
        // flickered on/off as the cursor moved across them.
        self.acceptsMouseMovedEvents = true
        // The product is dark-only; pin the whole island window so every
        // material in it (hover glass, notification pill, SwiftUI
        // `.glassEffect`) renders dark regardless of the user's system
        // theme. In light mode the unpinned materials rendered near-white —
        // the "looks completely different on my Mac" bug. Window-level pin
        // covers layers that ignore per-view appearance or SwiftUI
        // `colorScheme` pins.
        self.appearance = NSAppearance(named: .darkAqua)

        // `isFloatingPanel = true` silently resets `level` to `.floating`
        // (rawValue 3). Setting our intended level AFTER `isFloatingPanel`
        // is the only way to keep the panel above the macOS menu bar
        // (which sits at `.mainMenu` = 24). Verified empirically via
        // CGWindowListCopyWindowInfo — before this reorder our level
        // was reported as 3 regardless of what we assigned earlier.
        self.level = .screenSaver

        let rootView = self.makeRootView(layout: layout)
        let host = ClickThroughHostingView(rootView: rootView)
        // CRITICAL: without this, `NSHostingView`'s default `.standardBounds`
        // sizing options install auto-layout constraints from the SwiftUI
        // content's intrinsic size, and a hosting view that is the window's
        // `contentView` then DRIVES THE WINDOW FRAME — silently overriding
        // `apply()`'s `setFrame` and shrink-wrapping the window back to the
        // idle content size. That is exactly the agent-invocation jolt: the
        // window snapped (content-sized resize) while SwiftUI animated, so
        // the island visually jumped and slid back. Empty options keep the
        // window the sole owner of its frame (the permanently agent-sized
        // allocate-and-hit-test-gate pattern); the SwiftUI content is then
        // top-leading-pinned inside it by `IslandView`'s outer flexible frame.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        // wantsLayer intentionally NOT set: an explicit backing CALayer created
        // an intermediate compositing buffer that blocked NSVisualEffectView
        // (behindWindow blending) from sampling outside the window.
        host.compactSize = layout.compactSize
        // `expandedSize` is the compact/expanded island hit-test region only;
        // the agent surfaces are hit-tested via separate zones, and the agent
        // grow-out is folded into `acceptsEvent`'s `rightInset` shift, so this
        // stays the (notification-only) island size. The window itself is
        // permanently agent-sized; only the hit-test rect is inset.
        host.expandedSize = expandedHitTestSize(layout: layout)
        self.host = host
        self.contentView = host

        // `notificationActive` stays false: the left morph zone is never made
        // hittable. The left-morph machinery is left dormant; a later
        // follow-up may remove it entirely.

        // Mirror `AppState.nowPlaying` so the dedicated strip hit zone becomes
        // hittable while a track is active (combined with the hover state).
        // `dropFirst()` skips the initial value — the initial host state below
        // already assumes no track.
        musicStripCancellable = AppState.shared.$nowPlaying
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                self?.setMusicStripActive(active)
            }

        // Mirror the active item's live-stream flag so `sendEvent`'s transport
        // dispatch collapses to a single rightmost play/pause for radio.
        // `dropFirst()` skips the initial value — the host defaults to `false`.
        musicIsLiveCancellable = AppState.shared.$nowPlaying
            .map { $0?.isLive ?? false }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isLive in
                self?.setMusicIsLive(isLive)
            }

        // Mirror the agent flow store so the window grows for the wing /
        // answer panel and the hit zones become active as the agent
        // surfaces appear and change size.
        subscribeToAgentFlow()

        // Mirror the idle-hide visibility so the compact hit-rect collapses to
        // click-through while the pill is faded to the bare notch. `dropFirst()`
        // skips the initial `.active` (the host defaults to visible).
        // SYNCHRONOUS on purpose (no RunLoop.main hop): AppState publishes on
        // the main actor already, and each deferred hop added a runloop turn
        // to the hover-wake — see the AppDelegate visibility sink note.
        idleVisibilityCancellable = AppState.shared.$idleVisibility
            .map { $0 == .hiddenIdle }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] hidden in
                self?.applyIdleHidden(hidden)
            }

        // Re-anchor on display configuration change (resolution / monitor
        // arrangement / external-display swap). Without this the panel
        // would stay at its original screen-space frame after the user
        // unplugs a notched display and the system fallback main becomes
        // a non-notched screen.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // The user picked a different display in Settings — same re-anchor
        // path as a hardware configuration change (the cache rebuild inside
        // is redundant but harmless: the screen set didn't change).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: IslandScreenResolver.selectionDidChangeNotification,
            object: nil
        )
    }

    /// Connect the island agent surfaces to the store backed by the live
    /// `AgentController.responseStore`. Replaces the standalone bootstrap
    /// store created at init so the answer panel renders the same content
    /// the agent streams into. Rebuilds the rootView (the new store is an
    /// `@ObservedObject` constant captured at view-construction time) and
    /// re-subscribes the surface-sizing pipeline.
    ///
    /// Temporary connection point: the routing task (Task 10) calls this
    /// from where `AgentController` is created. Once a richer wiring exists
    /// it can be folded in.
    func installAgentFlow(_ store: IslandAgentFlowStore) {
        agentFlow = store
        subscribeToAgentFlow()
        subscribeToAgentAnswerEditingMonitor()
        applyCurrentLayout(display: isShown)
    }

    /// Wire the composing wing's submit / cancel and the answer panel's
    /// dismiss to `AgentController`. Called by the routing task (Task 10)
    /// from where the controller is created. Rebuilds the rootView so the
    /// `IslandView` closures capture the new handlers.
    func installAgentActions(
        submitText: @escaping (String) -> Void,
        cancelFlow: @escaping () -> Void
    ) {
        agentSubmitText = submitText
        agentCancelFlow = cancelFlow
        applyCurrentLayout(display: isShown)
    }

    /// (Re)wire the Combine subscription that mirrors the agent flow store's
    /// `wing` / `answerPanelVisible` into the window-frame growth + hit
    /// zones via `setAgentSurfaces`. Pushes the current value immediately so
    /// the surfaces reflect any state already present on the store.
    private func subscribeToAgentFlow() {
        agentFlowCancellable = agentFlow.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // `objectWillChange` fires BEFORE the published value
                // mutates; hop to the next runloop tick so we read the new
                // `wing` / `answerPanelVisible`.
                DispatchQueue.main.async { self?.syncAgentSurfaces() }
            }
        syncAgentSurfaces()
    }

    /// Install / remove the local Cmd+C / Cmd+A monitor in lockstep with the
    /// flow store's `answerPanelVisible`. The island panel hosts the answer
    /// body now (the legacy `AgentResponsePanel.performKeyEquivalent`
    /// override is gone from the live path), so copy / select-all on the
    /// streamed answer text dispatch through the responder chain here while
    /// the panel is on screen.
    private func subscribeToAgentAnswerEditingMonitor() {
        agentAnswerVisibleCancellable = agentFlow.$answerPanelVisible
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible {
                    self?.installAgentAnswerEditingMonitor()
                } else {
                    self?.removeAgentAnswerEditingMonitor()
                }
            }
    }

    private func installAgentAnswerEditingMonitor() {
        guard agentAnswerEditingMonitor == nil else { return }
        agentAnswerEditingMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { event in
            // Pure classifier (Cmd+C → copy, Cmd+A → selectAll;
            // layout-independent on keyCode). Forward the matched action
            // down the responder chain — `nil` target walks it from the
            // first responder, exactly what the missing Edit menu would
            // have done.
            guard let action = AgentEditingAction.action(for: event) else {
                return event
            }
            if NSApp.sendAction(action, to: nil, from: nil) {
                return nil
            }
            return event
        }
    }

    private func removeAgentAnswerEditingMonitor() {
        if let monitor = agentAnswerEditingMonitor {
            NSEvent.removeMonitor(monitor)
            agentAnswerEditingMonitor = nil
        }
    }

    /// Push the current agent flow state into the host window: the wing
    /// hit-zone width is the active face's EXTENSION — the part that
    /// overflows the right band, i.e. the zone BEHIND the capsule
    /// (`IslandAgentHitZones.wingRect` covers only this overflow; the in-band
    /// part of the face is already hit-tested by the compact island's rect).
    /// Answer-panel zone size when the panel is visible. No-op-equivalent
    /// (`active: false`, zero sizes) when the flow is idle, so the no-agent
    /// layout stays untouched.
    private func syncAgentSurfaces() {
        let faceWidth: CGFloat = {
            switch agentFlow.wing {
            case .recording:
                return IslandAgentWingView.recordingFaceWidth(
                    text: agentFlow.recordingFaceWidthHint,
                    providerMarkVisible: agentFlow.recordingProviderBrand != nil
                )
            case .composing:
                return IslandAgentWingView.composingFaceWidth(text: agentFlow.composingText)
            case .acting:
                return IslandAgentWingView.actingFaceWidth(
                    label: agentFlow.activityLabel,
                    providerMarkVisible: agentFlow.recordingProviderBrand != nil
                )
            case .answerControls: return IslandFrameLayout.agentWingAnswerControlsWidth
            case .failed: return IslandFrameLayout.agentWingFailedWidth
            case .deliveryFailed: return IslandFrameLayout.agentWingDeliveryFailedWidth
            case .hidden: return 0
            }
        }()
        let wingWidth = IslandFrameLayout.agentWingExtension(faceWidth: faceWidth)
        setAgentSurfaces(
            active: agentFlow.isActive,
            wingWidth: wingWidth,
            // Hit-zone tracks the MEASURED card height, not the fixed
            // `agentAnswerZoneHeight` reservation — an over-tall zone below a
            // short answer ate clicks for windows under the island (e.g. a
            // system "OK"/permission dialog the agent triggered).
            answerSize: IslandPanelMouseEventPolicy.agentAnswerHitSize(
                visible: agentFlow.answerPanelVisible,
                contentHeight: agentAnswerContentHeight,
                width: IslandFrameLayout.agentAnswerPanelWidth
            ),
            retryActive: {
                if case .deliveryFailed = agentFlow.wing { return true }
                return false
            }()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = agentAnswerEditingMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        // The answer panel's ✕ is dismissed HERE, at the window level. The
        // island is a non-activating panel that is never key while an answer
        // is on screen, and Whytap is an inactive app (the user is in another
        // app), so the AppKit→SwiftUI event bridge drops the first-mouse
        // click before any SwiftUI gesture — or even an `acceptsFirstMouse`
        // NSView overlay — sees it. `sendEvent` is the one layer that always
        // runs (live-traced), so the window intercepts the click
        // geometrically against the ✕ hotspot and dismisses directly.
        // See docs/troubleshooting.md ("Island answer ✕ does nothing").
        if event.type == .leftMouseDown,
           let host, host.agentActive, host.agentAnswerSize != .zero {
            let zones = IslandAgentHitZones(
                boundsSize: frame.size,
                compactSize: host.compactSize,
                rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
                wingWidth: host.agentWingWidth,
                wingGap: IslandFrameLayout.agentWingGap,
                answerSize: host.agentAnswerSize
            )
            if zones.answerCloseHotspot.contains(event.locationInWindow) {
                agentCancelFlow()
                return
            }
        }

        // The total-offline Drop `.deliveryFailed` wing's Retry pill is
        // dismissed HERE too, for the same first-mouse reason as the ✕ above.
        // Gated on `agentRetryActive` so the hotspot only arms while the
        // failure wing is on screen.
        if event.type == .leftMouseDown,
           let host, host.agentRetryActive, host.agentWingWidth > 0 {
            let zones = IslandAgentHitZones(
                boundsSize: frame.size,
                compactSize: host.compactSize,
                rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
                wingWidth: host.agentWingWidth,
                wingGap: IslandFrameLayout.agentWingGap,
                answerSize: host.agentAnswerSize
            )
            if zones.deliveryRetryHotspot.contains(event.locationInWindow) {
                actions.retryDelivery()
                return
            }
        }

        // The hover-gated player strip's transport buttons (⏮ ▶ ⏭) are
        // dismissed HERE too, for the same reason the ✕ is: they are SwiftUI
        // `Button`s in this non-key, non-activating panel, and on-device the
        // AppKit→SwiftUI bridge drops the click before the `Button` action ever
        // fires (the dedicated hit zone reports `accepted=1` over them, yet the
        // `Button` never receives the click). `sendEvent` always runs, so the
        // window intercepts the click geometrically against each button's
        // hotspot — derived from the SAME computed strip rect the hit zone uses
        // + the `IslandMusicStrip` layout constants — and invokes the matching
        // action directly. Mirror of the ✕ close hotspot above.
        if event.type == .leftMouseDown, let strip = transportStripRect() {
            let isLive = host?.musicIsLive ?? false
            let rects = IslandMusicStripHitZone.transportButtonRects(
                stripRect: strip,
                isLive: isLive
            )
            let location = event.locationInWindow
            #if DEBUG
            os_log(
                "transport mouseDown loc=(%{public}.1f,%{public}.1f) strip=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f) prev=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f) play=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f) next=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f)",
                log: islandMusicStripHitTestLog,
                type: .debug,
                location.x, location.y,
                strip.origin.x, strip.origin.y, strip.width, strip.height,
                rects.previous.origin.x, rects.previous.origin.y, rects.previous.width, rects.previous.height,
                rects.playPause.origin.x, rects.playPause.origin.y, rects.playPause.width, rects.playPause.height,
                rects.next.origin.x, rects.next.origin.y, rects.next.width, rects.next.height
            )
            #endif
            if rects.previous.contains(location) {
                #if DEBUG
                os_log("transport matched: previous → invoked musicPrevious",
                       log: islandMusicStripHitTestLog, type: .debug)
                #endif
                actions.musicPrevious()
                return
            }
            if rects.playPause.contains(location) {
                #if DEBUG
                os_log("transport matched: playPause → invoked musicPlayPause",
                       log: islandMusicStripHitTestLog, type: .debug)
                #endif
                actions.musicPlayPause()
                return
            }
            if rects.next.contains(location) {
                #if DEBUG
                os_log("transport matched: next → invoked musicNext",
                       log: islandMusicStripHitTestLog, type: .debug)
                #endif
                actions.musicNext()
                return
            }
        }

        super.sendEvent(event)
    }

    /// The strip's computed hit rect in window/bounds-space (AppKit y-up,
    /// origin bottom-left — the same space `event.locationInWindow` arrives in,
    /// because the host fills the window content and shares its origin) when a
    /// track is active AND the island is hover-expanded; `nil` otherwise. The
    /// `sendEvent` transport dispatch builds the three button hotspots from
    /// this, exactly as the dedicated hit zone (`ClickThroughHostingView`) does
    /// in host bounds-space.
    private func transportStripRect() -> CGRect? {
        guard let host,
              IslandMusicStripHitZone.isActive(
                  musicStripActive: host.musicStripActive,
                  acceptsExpandedHitTesting: host.acceptsExpandedHitTesting
              )
        else { return nil }
        return IslandMusicStripHitZone(
            boundsSize: frame.size,
            compactSize: host.compactSize,
            rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
            topGap: IslandDropModeControl.musicStripTopGap,
            stripHeight: IslandDropModeControl.musicStripHeight
        ).stripRect
    }

    // Borderless / nonactivating panels must opt out of becoming key / main
    // for normal island interactions; otherwise clicking SwiftUI buttons steals
    // focus from the app the user was typing in. Agent text entry is the lone
    // exception, and it lives in `IslandAgentComposerPanel` instead of mutating
    // this overlay panel at runtime.
    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    /// Toggled by the composing wing. The island panel stays a non-activating
    /// overlay; a separate key-capable composer panel owns the NSTextView and
    /// keyboard focus for text entry.
    var agentKeyboardEnabled = false {
        didSet {
            guard agentKeyboardEnabled != oldValue else { return }
            syncAgentComposerPanel()
        }
    }

    private func syncAgentComposerPanel() {
        guard agentKeyboardEnabled,
              case .composing = agentFlow.wing,
              let frame = composingFieldScreenFrame()
        else {
            agentComposerPanel.hide()
            return
        }

        if agentComposerPanel.isVisible {
            agentComposerPanel.reposition(to: frame)
        } else {
            let placeholder = agentFlow.activeSourceIsGoogle
                ? IslandAgentWingView.googleComposerPlaceholder
                : IslandAgentWingView.composerPlaceholder
            agentComposerPanel.show(
                frame: frame,
                placeholder: placeholder,
                submit: { [weak self] text in
                    self?.agentSubmitText(text)
                },
                cancel: { [weak self] in
                    self?.agentCancelFlow()
                },
                textChanged: { [weak self] text in
                    self?.agentFlow.composingTextChanged(text)
                }
            )
        }
    }

    /// The composing field's rect in island-window coordinates. `wingRect`
    /// covers only the overflow past the island's right band, but the visible
    /// composer also occupies the in-band part to its left. The companion
    /// `IslandAgentComposerPanel` is positioned over this full rect.
    private func composingFieldWindowRect() -> CGRect {
        guard let host else { return .zero }
        let zones = IslandAgentHitZones(
            boundsSize: frame.size,
            compactSize: host.compactSize,
            rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
            wingWidth: host.agentWingWidth,
            wingGap: IslandFrameLayout.agentWingGap,
            answerSize: host.agentAnswerSize
        )
        let wing = zones.wingRect
        // Match the field rect to the (text-adaptive) composing face: the panel
        // is leading-anchored (its left edge is fixed at `wing.minX - inBand`,
        // independent of the width) and grows rightward with the capsule, so the
        // typed text always sits on black instead of leaking onto the desktop.
        let fullWidth = IslandAgentWingView.composingFaceWidth(text: agentFlow.composingText)
        let inBand = max(0, fullWidth - host.agentWingWidth)
        return CGRect(
            x: wing.minX - inBand,
            y: wing.minY,
            width: fullWidth,
            height: wing.height
        )
    }

    private func composingFieldScreenFrame() -> NSRect? {
        guard host != nil else { return nil }
        let rect = composingFieldWindowRect()
        guard rect != .zero else { return nil }
        return NSRect(
            x: frame.minX + rect.minX,
            y: frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    // AppKit's default `constrainFrameRect(_:to:)` clamps window frames
    // so they don't overlap the menu bar — `top edge > visibleFrame.maxY`
    // gets pulled down to `visibleFrame.maxY`. We deliberately place the
    // island at `top edge = screen.frame.maxY` (flush with the physical
    // top of the screen, INSIDE the menu-bar / notch band). Returning
    // the requested frame unchanged opts out of that clamping. Standard
    // pattern for notch / status-bar overlays.
    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        return frameRect
    }

    // MARK: - Public API

    /// Make the panel visible. Idempotent — repeated calls keep it on
    /// screen at the current frame, re-anchored to the selected display
    /// snapshot resolved by `IslandScreenResolver`.
    func show() {
        startMouseEventRouting()
        applyCurrentLayout(display: false)
        refreshMouseEventRouting()
        orderFrontRegardless()
        isShown = true
    }

    func hide() {
        stopMouseEventRouting()
        agentComposerPanel.hide()
        ignoresMouseEvents = true
        orderOut(nil)
        isShown = false
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    /// `true` between `show()` and `hide()`. Used by `AppDelegate` to
    /// label the menu item (Show vs Hide). Distinct from
    /// `NSWindow.isVisible` (which would return `true` only while the
    /// window is actually on screen — we want the intended state).
    var isShownOnScreen: Bool { isShown }

    // MARK: - Layout

    /// Bundle of values that vary together when re-laying out the
    /// compact panel.
    private struct Layout {
        let compactFrame: NSRect
        let expandedHostFrame: NSRect
        /// Expanded host frame grown for the agent surfaces (rightward by
        /// `rightAgentZoneWidth`, downward by `agentWingGap +
        /// agentAnswerZoneHeight`, top pinned, `minX` fixed). Used as the
        /// window frame while `agentActive`.
        let agentExpandedHostFrame: NSRect
        /// Frame the island occupies when morphed leftward for a notification
        /// (`expanded: true`). Unioned into the window frame so the pill,
        /// which renders OUTSIDE the compact/expanded frame, is not clipped.
        let leftNotificationFrame: NSRect
        let compactHeight: CGFloat
        let compactSize: CGSize
        let notchWidth: CGFloat

        /// Window frame for the current hover state. The base is the
        /// (stable) expanded host frame; the leftward notification morph
        /// frame is ALWAYS unioned in so the window's left edge is
        /// permanently reserved for the pill zone. This is deliberate:
        /// keeping the window a fixed width means it never resizes when a
        /// notification shows/hides, so the AppKit frame and the SwiftUI
        /// content width can no longer animate on mismatched curves and
        /// jitter. The pill's appearance is carried entirely by its own
        /// SwiftUI `.transition`; the empty reserved area is transparent
        /// and gated click-through via `host.leftZoneWidth`.
        ///
        /// `notificationActive` is retained in the signature for call-site
        /// clarity but no longer changes the WIDTH — the union is
        /// unconditional. (It still has no effect on height; height is
        /// driven by `expandedHitTesting`.)
        ///
        /// The window ALWAYS lives on the agent-grown host frame (wider +
        /// taller), whether or not the agent flow is active — the island's
        /// native allocate-and-hit-test-gate pattern. Keeping the AppKit
        /// frame static across the agent toggle is what kills the
        /// invocation jolt: the SwiftUI content expands inside an already
        /// large window (SwiftUI animates it), instead of the window
        /// resizing one async hop after the store flips. The
        /// left-notification union is still applied so the pill zone stays
        /// reserved.
        func windowFrame(
            expandedHitTesting: Bool,
            notificationActive: Bool
        ) -> NSRect {
            let base = IslandPanelFramePolicy.windowFrame(
                compactFrame: compactFrame,
                expandedFrame: agentExpandedHostFrame,
                acceptsExpandedHitTesting: expandedHitTesting
            )
            return base.union(leftNotificationFrame)
        }

        /// Island hit-test region size (the compact/expanded island content +
        /// the left-notification reservation), independent of the agent
        /// grow-out. The window is permanently agent-sized, but the
        /// compact/expanded island content stays the NON-agent width; the
        /// agent grow-out is folded into `acceptsEvent`'s `rightInset` shift,
        /// not into this size. Height follows the hover state.
        func islandHitTestSize(expandedHitTesting: Bool) -> CGSize {
            let base = IslandPanelFramePolicy.windowFrame(
                compactFrame: compactFrame,
                expandedFrame: expandedHostFrame,
                acceptsExpandedHitTesting: expandedHitTesting
            )
            return base.union(leftNotificationFrame).size
        }
    }

    /// Reads a stable screen descriptor once and forwards its frame,
    /// visibleFrame, safe area, and aux areas to `IslandFrameLayout`.
    private static func computeLayout() -> Layout {
        let screen = IslandScreenResolver.currentDescriptor()
        let compactFrame = IslandFrameLayout.islandFrame(on: screen)
        let expandedHostFrame = IslandFrameLayout.hostPanelFrame(on: screen, expanded: true)
        let agentExpandedHostFrame = IslandFrameLayout.hostPanelFrame(
            on: screen,
            expanded: true,
            agentActive: true
        )
        let leftNotificationFrame = IslandFrameLayout.leftNotificationFrame(on: screen, expanded: true)
        let metrics = IslandFrameLayout.notchMetrics(on: screen)
        return Layout(
            compactFrame: compactFrame,
            expandedHostFrame: expandedHostFrame,
            agentExpandedHostFrame: agentExpandedHostFrame,
            leftNotificationFrame: leftNotificationFrame,
            compactHeight: compactFrame.height,
            compactSize: compactFrame.size,
            notchWidth: metrics.width
        )
    }

    /// Re-applies the current screen's layout to the panel and host.
    /// Rebuilds the SwiftUI rootView with the new dimensions so the
    /// pill renders with the correct geometry after a display change.
    private func applyCurrentLayout(display: Bool) {
        let layout = Self.computeLayout()
        let expanded = host?.acceptsExpandedHitTesting ?? false
        apply(layout: layout, display: display, expanded: expanded)
        host?.compactSize = layout.compactSize
        host?.expandedSize = expandedHitTestSize(layout: layout)
        host?.leftZoneWidth = notificationActive ? IslandFrameLayout.leftNotificationWidth : 0
        host?.musicStripActive = musicStripActive
        host?.musicIsLive = musicIsLive
        // The SwiftUI view captures its sizing constants once via init,
        // so we rebuild its rootView with the new values on display
        // change. Existing animations are not preserved across this
        // swap — acceptable for a PoC since display changes are rare.
        host?.rootView = makeRootView(layout: layout)
        syncAgentComposerPanel()
    }

    /// Builds the hosted `IslandView` with the current sizing + the panel's
    /// agent surfaces wired in. Both the initial mount and the rebuild on
    /// display change / actions swap go through here so the wiring stays in
    /// one place. The closures capture `[weak self]` and read the LIVE
    /// `actions` (not the `.noOp` present at init time) so `AppDelegate`'s
    /// later install is honored without re-creating the view.
    @MainActor
    private func makeRootView(layout: Layout) -> IslandView {
        IslandView(
            compactHeight: layout.compactHeight,
            compactWidth: layout.compactSize.width,
            notchWidth: layout.notchWidth,
            onHoverChange: { [weak self] isHovering in
                self?.setHoverExpanded(isHovering)
            },
            onKeyboardFocusRequest: { [weak self] wantsFocus in
                self?.setKeyboardFocusRequested(wantsFocus)
            },
            onHoverPanelBandHeightChange: { [weak self] height in
                self?.setHoverBandHeight(height)
            },
            onAgentAnswerHeightChange: { [weak self] height in
                self?.setAgentAnswerContentHeight(height)
            },
            actions: self.actions,
            agentFlow: agentFlow,
            agentLinksSelection: agentLinksSelection,
            cancelAgentFlow: { [weak self] in
                self?.agentCancelFlow()
            },
            onAgentKeyboardFocusChange: { [weak self] wantsFocus in
                self?.agentKeyboardEnabled = wantsFocus
            },
            vocabulary: { [weak self] in
                (self?.actions ?? .noOp).vocabulary()
            }
        )
    }

    private func setHoverExpanded(_ expanded: Bool) {
        guard host?.acceptsExpandedHitTesting != expanded else { return }
        host?.acceptsExpandedHitTesting = expanded

        let layout = Self.computeLayout()
        apply(layout: layout, display: true, expanded: expanded)
        host?.compactSize = layout.compactSize
        host?.expandedSize = expandedHitTestSize(layout: layout)
        refreshMouseEventRouting(layout: layout)
    }

    /// React to a track starting / stopping. Mirrors the flag onto the host
    /// (so `acceptsEvent` / `hitTest` can union the strip rect) and refreshes
    /// mouse routing so the window stops ignoring events over the strip band
    /// while a track is active. No window resize — the strip lives inside the
    /// already-reserved expanded band. Idempotent.
    private func setMusicStripActive(_ active: Bool) {
        guard musicStripActive != active else { return }
        musicStripActive = active
        host?.musicStripActive = active
        refreshMouseEventRouting()
    }

    /// Mirror the active item's live-stream flag onto the host. No window
    /// resize or mouse-routing change — only the transport hit dispatch reads
    /// it. Idempotent.
    private func setMusicIsLive(_ isLive: Bool) {
        guard musicIsLive != isLive else { return }
        musicIsLive = isLive
        host?.musicIsLive = isLive
    }

    /// React to the idle-hide visibility flipping. Mirrors the flag onto the
    /// host (so `acceptsEvent` makes the faded compact pill click-through) and
    /// refreshes mouse routing so the window stops claiming compact clicks.
    /// No window resize — the window never moves in idle (spec §1.2). The
    /// SwiftUI fade itself is driven separately via `AppState.idleVisibility`
    /// (Stage 5). Idempotent.
    private func applyIdleHidden(_ hidden: Bool) {
        guard idleHidden != hidden else { return }
        idleHidden = hidden
        host?.idleHidden = hidden
        refreshMouseEventRouting()
    }

    /// Track whether the cursor is over rendered island content and fire the
    /// hover blocker (B10) on the edge only. Called from every routing pass —
    /// including state-change refreshes — which is safe because it only reflects
    /// the current cursor-over-content fact. Carries only a bool (invariant #3).
    private func updateIslandHover(cursorOverContent: Bool) {
        guard islandHovered != cursorOverContent else { return }
        islandHovered = cursorOverContent
        onIslandHoverChange(cursorOverContent)
    }

    /// Fire the idle wake from a REAL mouse event (not a state-change refresh).
    /// The wake zone is the compact pill's own rect (+ small padding), NOT the
    /// whole window frame — the window is permanently agent-wide, so the broad
    /// gate woke the island on any mouse sweep across the top of the screen
    /// (founder feedback 2026-07-06; spec §4.1 updated). The same narrow zone
    /// gates plain activity ticks, so mousing far from the pill doesn't keep
    /// resetting the idle timer either. Wired only into the mouse monitors so
    /// a collapse-triggered `refreshMouseEventRouting` can never self-wake.
    /// No payload (invariant #3).
    private func handleIslandMouseActivity() {
        let zone = IslandPanelMouseEventPolicy.idleWakeZone(
            compactFrame: Self.computeLayout().compactFrame,
            padding: IslandIdleConfig.wakeZonePadding
        )
        guard zone.contains(NSEvent.mouseLocation) else { return }
        onIslandMouseActivity()
    }

    /// Toggle the agent surfaces (wing capsule + answer panel). Updates only
    /// the host's agent hit-test fields and refreshes mouse routing so the
    /// cursor over the wing/answer keeps events enabled. All flags are off by
    /// default, so callers that never invoke this keep the prior no-agent
    /// behavior.
    ///
    /// Critically, this NEVER resizes the window: the island window is
    /// permanently sized for the widest wing + the full answer zone
    /// (`agentExpandedHostFrame`, see `Layout.windowFrame`). Toggling the
    /// agent only flips hit-test gating — `agentActive` shifts the
    /// island's compact/expanded hit rect left by `rightAgentZoneWidth`
    /// (`acceptsEvent`) and the wing/answer rects become hittable. Keeping
    /// the AppKit frame static across the toggle is what removes the
    /// invocation jolt: the SwiftUI content expands inside the already-large
    /// window (SwiftUI animates it) rather than the window resizing one async
    /// hop after the store flips. Idempotent: a call that changes nothing
    /// returns early.
    func setAgentSurfaces(
        active: Bool,
        wingWidth: CGFloat,
        answerSize: CGSize,
        retryActive: Bool = false
    ) {
        let activeChanged = host?.agentActive != active
        let hitZonesChanged = host?.agentWingWidth != wingWidth
            || host?.agentAnswerSize != answerSize
        let retryChanged = host?.agentRetryActive != retryActive
        guard activeChanged || hitZonesChanged || retryChanged else { return }

        host?.agentActive = active
        host?.agentWingWidth = wingWidth
        host?.agentAnswerSize = answerSize
        host?.agentRetryActive = retryActive

        refreshMouseEventRouting()
        syncAgentComposerPanel()
    }

    private func setKeyboardFocusRequested(_ wantsFocus: Bool) {
        acceptsKeyboardFocus = wantsFocus
        if wantsFocus {
            makeKey()
        } else if isKeyWindow {
            resignKey()
        }
    }

    /// `IslandView` reports the hover band height for the current panel mode
    /// (tall for History, default for everything else). Re-derives the
    /// hit-test size and mouse routing so the grown band actually receives
    /// hover/click events.
    private func setHoverBandHeight(_ height: CGFloat) {
        guard hoverBandHeight != height else { return }
        hoverBandHeight = height
        let layout = Self.computeLayout()
        host?.expandedSize = expandedHitTestSize(layout: layout)
        refreshMouseEventRouting(layout: layout)
    }

    /// `IslandView` reports the rendered answer card height so the answer
    /// hit-zone matches the visible card (not the fixed `agentAnswerZoneHeight`
    /// reservation, which left a tall click-eating band below short answers).
    /// Re-syncs the agent surfaces so the new height reaches the hit-zone.
    private func setAgentAnswerContentHeight(_ height: CGFloat) {
        let rounded = height.rounded()
        guard agentAnswerContentHeight != rounded else { return }
        agentAnswerContentHeight = rounded
        syncAgentSurfaces()
    }

    /// `Layout`'s expanded sizes are built from the static default band
    /// (`IslandDropModeControl.hoverPanelHeight`); these two helpers stretch
    /// them downward by the current band delta. AppKit y grows up, so growing
    /// downward means lowering `origin.y` while growing `height`.
    private var hoverBandHeightDelta: CGFloat {
        hoverBandHeight - IslandDropModeControl.hoverPanelHeight
    }

    private func expandedHitTestSize(layout: Layout) -> CGSize {
        var size = layout.islandHitTestSize(expandedHitTesting: true)
        size.height += hoverBandHeightDelta
        return size
    }

    private func expandedMouseFrame(layout: Layout) -> NSRect {
        var frame = layout.expandedHostFrame
        frame.origin.y -= hoverBandHeightDelta
        frame.size.height += hoverBandHeightDelta
        return frame
    }

    /// Screen-space frame of the hover-gated music strip — directly below the
    /// compact island, offset down by `musicStripTopGap`, full compact width,
    /// `musicStripHeight` tall (AppKit y-up: its top edge is the compact
    /// frame's bottom edge minus the gap, so lower the origin by the gap +
    /// strip height). Unioned into the expanded mouse-active frame while a
    /// track is active so the window keeps mouse events live over the strip
    /// band, mirroring the bounds-space `IslandMusicStripHitZone` used by
    /// `acceptsEvent` / `hitTest`.
    private func musicStripScreenFrame(layout: Layout) -> NSRect {
        // The computed band just below the compact pill. Matches the
        // bounds-space `IslandMusicStripHitZone.stripRect` used by
        // `acceptsEvent` / `hitTest`, so the mouse-active band and the hit rect
        // stay in lockstep.
        let compact = layout.compactFrame
        let height = IslandDropModeControl.musicStripHeight
        return NSRect(
            x: compact.minX,
            y: compact.minY - IslandDropModeControl.musicStripTopGap - height,
            width: compact.width,
            height: height
        )
    }

    private func apply(layout: Layout, display: Bool, expanded: Bool) {
        // The window is PERMANENTLY sized for the agent surfaces (the
        // allocate-and-hit-test-gate pattern), so the frame is identical
        // whether or not the agent flow is active — toggling the agent never
        // resizes the window. Only the hover state (expanded height) and the
        // notification reservation move the frame.
        let targetFrame = layout.windowFrame(
            expandedHitTesting: expanded,
            notificationActive: notificationActive
        )
        setFrame(targetFrame, display: display)
        host?.frame = NSRect(origin: .zero, size: targetFrame.size)
        syncAgentComposerPanel()
    }

    /// Events that re-evaluate `ignoresMouseEvents`. `.mouseMoved` is the main
    /// driver, but clicks / scrolls / drags must refresh too: the island sits at
    /// `.screenSaver` level ABOVE everything, so a popup or system dialog (e.g.
    /// a TCC "Allow" prompt the local agent triggers, or a selection that lands
    /// the cursor over another window) can appear under it — and a stale flag
    /// would let the island eat the click. `.leftMouseDragged` keeps the flag
    /// fresh through a text-selection drag, which emits drags, not moves.
    private static let mouseRoutingEvents: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .scrollWheel,
        .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    private func startMouseEventRouting() {
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: Self.mouseRoutingEvents
            ) { [weak self] _ in
                // Synchronous: global-monitor callbacks already arrive on the
                // main thread, and the old `DispatchQueue.main.async` hop left
                // the flag one frame stale — a click in that frame hit the
                // still-opaque window and was eaten. `assumeIsolated` calls the
                // @MainActor method inline without re-introducing that lag.
                MainActor.assumeIsolated {
                    self?.refreshMouseEventRouting()
                    // Real mouse event → feed the idle wake (see
                    // `handleIslandMouseActivity`). Kept out of
                    // `refreshMouseEventRouting` so a collapse-driven refresh
                    // never self-wakes the island.
                    self?.handleIslandMouseActivity()
                }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: Self.mouseRoutingEvents
            ) { [weak self] event in
                self?.refreshMouseEventRouting()
                self?.handleIslandMouseActivity()
                return event
            }
        }
    }

    private func stopMouseEventRouting() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    // WHY: docs/decisions/2026-06-16-island-mouse-dead-zone.md
    private func refreshMouseEventRouting(layout: Layout? = nil) {
        let layout = layout ?? Self.computeLayout()
        // The window is permanently agent-sized. It must claim mouse events over
        // EACH rendered surface individually — never a bounding union of them.
        // The empty gap between the pill, wing and answer card must stay
        // click-through: with `ignoresMouseEvents == false` over a gap, `hitTest`
        // returns nil and AppKit EATS the event instead of passing it to the app
        // below — that was the system-wide "parts of the screen don't click /
        // scroll" bug that lasted the whole drop/agent cycle. The precise per-rect
        // gating mirrors `acceptsEvent` / `hitTest`, so routing claims exactly
        // what hit-testing accepts.
        let expanded = host?.acceptsExpandedHitTesting ?? false
        let activeFrames = IslandPanelMouseEventPolicy.activeFrames(
            compactFrame: layout.compactFrame,
            expandedFrame: expandedMouseFrame(layout: layout),
            leftNotificationFrame: layout.leftNotificationFrame,
            musicStripFrame: musicStripScreenFrame(layout: layout),
            agentSurfaceFrames: agentSurfaceScreenFrames(),
            idleHidden: idleHidden,
            expanded: expanded,
            notificationActive: notificationActive,
            musicStripActive: musicStripActive
        )

        let shouldIgnore = IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
            cursor: NSEvent.mouseLocation,
            activeFrames: activeFrames
        )

        // Hover blocker (spec §3 B10): cursor over actually-rendered island
        // content holds `.active` even when stationary. Fired only on the edge
        // so a hover doesn't spam the callback. Safe to compute on every routing
        // pass (including state-change refreshes) — it just tracks whether the
        // cursor is currently over content. The mouse-MOVE wake is fed
        // separately, from the real mouse monitors only (see
        // `startMouseEventRouting`), so a collapse-triggered refresh can never
        // self-wake the island.
        updateIslandHover(cursorOverContent: !shouldIgnore)
        #if DEBUG
        // While a track is active, trace whether the window is ignoring mouse
        // events over the strip band AT THE TIME the cursor moves — so a click
        // that never reaches `sendEvent` can be distinguished from one that
        // reaches it but misses a hotspot. Gated on `musicStripActive` to avoid
        // logging on every mouse-move when there is no music. Coordinates are
        // SCREEN-space (y-up) to match the cursor + mouse-active frames.
        if musicStripActive {
            let cursor = NSEvent.mouseLocation
            let stripFrame = musicStripScreenFrame(layout: layout)
            let expandedFrame = expandedMouseFrame(layout: layout)
            os_log(
                "routing cursor=(%{public}.1f,%{public}.1f) expandedFrame=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f) stripFrame=(%{public}.1f,%{public}.1f,%{public}.1f,%{public}.1f) expandedHit=%{public}d ignoresMouseEvents=%{public}d",
                log: islandMusicStripHitTestLog,
                type: .debug,
                cursor.x, cursor.y,
                expandedFrame.origin.x, expandedFrame.origin.y, expandedFrame.width, expandedFrame.height,
                stripFrame.origin.x, stripFrame.origin.y, stripFrame.width, stripFrame.height,
                (host?.acceptsExpandedHitTesting ?? false) ? 1 : 0,
                shouldIgnore ? 1 : 0
            )
        }
        #endif
        if ignoresMouseEvents != shouldIgnore {
            ignoresMouseEvents = shouldIgnore
        }
        refreshMusicTransportHover()
    }

    /// Resolve which transport button the cursor is over and publish it for the
    /// strip's hover highlight. Geometric, because SwiftUI `.onHover` flickers in
    /// this non-activating panel — the same reason transport CLICKS are
    /// dispatched geometrically in `sendEvent`. The cursor is converted
    /// screen → window space (the host fills the window, so window space matches
    /// the strip-rect space the hotspots are built in).
    private func refreshMusicTransportHover() {
        let hovered: MusicTransportButton?
        if let strip = transportStripRect() {
            let cursorInWindow = CGPoint(
                x: NSEvent.mouseLocation.x - frame.origin.x,
                y: NSEvent.mouseLocation.y - frame.origin.y
            )
            hovered = IslandMusicStripHitZone.transportButton(
                at: cursorInWindow,
                stripRect: strip,
                isLive: host?.musicIsLive ?? false
            )
        } else {
            hovered = nil
        }
        if AppState.shared.hoveredMusicTransport != hovered {
            AppState.shared.hoveredMusicTransport = hovered
        }
    }

    /// The agent wing + answer rects in SCREEN space (empty while the agent flow
    /// is idle). Built from the SAME `IslandAgentHitZones` that `hitTest`'s
    /// `acceptsEvent` and `sendEvent`'s ✕ hotspot use, so mouse-routing claims
    /// exactly what hit-testing accepts — neither can drift into a dead zone.
    /// `wingRect`/`answerRect` are in the window's bottom-left bounds space, so a
    /// translate by the window origin lifts them to screen space.
    private func agentSurfaceScreenFrames() -> [NSRect] {
        guard let host, host.agentActive else { return [] }
        let zones = IslandAgentHitZones(
            boundsSize: frame.size,
            compactSize: host.compactSize,
            rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
            wingWidth: host.agentWingWidth,
            wingGap: IslandFrameLayout.agentWingGap,
            answerSize: host.agentAnswerSize
        )
        let origin = frame.origin
        var rects: [NSRect] = []
        if host.agentWingWidth > 0 {
            rects.append(zones.wingRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        if host.agentAnswerSize != .zero {
            rects.append(zones.answerRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    @objc private func handleScreenChange() {
        guard isShown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            IslandScreenCache.shared.rebuild()
            self.applyCurrentLayout(display: true)
        }
    }
}
