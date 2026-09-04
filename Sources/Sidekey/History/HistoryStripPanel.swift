import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel hosting the bottom history strip.
/// Stays alive across mode switches; orders itself in/out based on
/// `HistoryStripController.openMode`.
///
/// Frame geometry: bottom of screen, left edge at `visible.minX +
/// sideMargin`, right edge at `visible.maxX - sideMargin`. The strip
/// now spans edge-to-edge so the 5-up rubbery cards row can fan out
/// across the full width. Height is constant.
@MainActor
final class HistoryStripPanel: NSPanel {
    /// Strip frame height. Maxim's 30% vertical-shrink directive
    /// («всю рамку правую + карточки уменьшить») dropped the pre-shrink
    /// 220pt to 154pt (220 × 0.7). Cards inside (`HistoryCardView.cardHeight`)
    /// shrink in lockstep so the strip's chrome above/below the cards
    /// stays roughly constant. Width is computed dynamically from the
    /// visible frame (full width minus side margins) — unchanged by
    /// the vertical-only shrink.
    static let height: CGFloat = 154
    /// Dock-safe lift applied to the strip's bottom anchor so a
    /// magnified or full-bar Dock can't paint over the cards. Same
    /// rationale and value as `FloatingDotPanel.dockSafeBottomMargin`
    /// — the strip + helper chip + orb all received the same +40 lift
    /// so the visual alignment between them is preserved.
    static let dockSafeBottomMargin: CGFloat = 40
    /// Strip's bottom edge sits 16pt ABOVE `visible.minY` after the
    /// dock-safe lift. Previously -24 (inside the dock zone) — Maxim's
    /// original "cards align with helper chip" spec is still satisfied
    /// because the helper chip also got the same +40 lift, so the two
    /// stay visually aligned. Click-outside still closes the strip.
    /// Was -24 → +16 with the dock-safe buffer.
    private static let baseBottomMargin: CGFloat = -24
    static let bottomMargin: CGFloat = baseBottomMargin + dockSafeBottomMargin
    static let sideMargin: CGFloat = 20
    /// NSWindow level. After the +40 dock-safe lift the strip sits
    /// ABOVE `visible.minY`, but a magnified Dock can still extend
    /// upward into the strip's area on small displays, and the strip
    /// must remain visible on fullscreen Spaces. `.statusBar` (25)
    /// beats both the Dock (`kCGDockWindowLevelKey` ≈ 20) and the
    /// default fullscreen chrome without escalating into modal-panel
    /// territory.
    static let windowLevel: NSWindow.Level = .statusBar
    /// Floor for the strip's width — clamp guard for degenerate /
    /// corrupt `visibleFrame` reports (e.g. screens reconfigured mid-
    /// session). Real screens are always wider than this.
    static let minimumWidth: CGFloat = 240

    private let controller: HistoryStripController
    private let feed: HistoryStripFeed
    private let assetsDirectory: URL
    private let toast: CopiedToastController?
    /// ROO-208 iter 15: paste engine the panel calls into when the
    /// user presses Enter on a hovered card. Nil in tests that don't
    /// drive the Enter-paste flow — the local key monitor degrades to
    /// "swallow Enter, do nothing" when both are absent.
    private let autoPasteEngine: AutoPasteEngine?

    private var cancellables = Set<AnyCancellable>()
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var outsideClickMonitor: Any?

    init(
        controller: HistoryStripController,
        feed: HistoryStripFeed,
        assetsDirectory: URL,
        toast: CopiedToastController? = nil,
        autoPasteEngine: AutoPasteEngine? = nil
    ) {
        self.controller = controller
        self.feed = feed
        self.assetsDirectory = assetsDirectory
        self.toast = toast
        self.autoPasteEngine = autoPasteEngine

        let initialFrame = Self.computeFrame(
            visibleFrame: IslandScreenResolver.currentVisibleFrame()
        )

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        // `.statusBar` (25) beats the Dock (`kCGDockWindowLevelKey` ≈
        // 20) so the cards stay visible even when a magnified Dock
        // intrudes upward, and so the strip stays visible while the
        // user is in another app's fullscreen Space.
        self.level = Self.windowLevel
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.isMovable = false
        self.hidesOnDeactivate = false
        // Round 2 Bug 2 fix: a `.nonactivatingPanel` that returns
        // `canBecomeKey: false` never enters AppKit's scroll-wheel
        // routing graph — the embedded `ScrollView(.horizontal)` was
        // visually present but inert. Letting the panel become key
        // (see overridden `canBecomeKey` below) + setting
        // `becomesKeyOnlyIfNeeded` keeps the underlying app
        // frontmost (the `.nonactivatingPanel` style mask suppresses
        // app activation) while still routing scroll events through
        // the panel's SwiftUI ScrollView.
        self.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(
            rootView: HistoryStripView(
                controller: controller,
                feed: feed,
                assetsDirectory: assetsDirectory,
                toast: toast
            )
        )
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        // ROO-208 iter 5: backing layer set up BEFORE the view enters
        // the panel's hierarchy. Setting `wantsLayer = true` post-
        // attachment can pick up the system default-tinted backing,
        // which surfaced as a faint light-grey ribbon wrapping the
        // sidebar+cards pair on Maxim's screenshot.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        // Inherit the panel's clear appearance rather than the system
        // default (vibrant light/dark), so SwiftUI material defaults
        // don't paint a window-background tint behind the cards.
        host.appearance = nil
        self.contentView = host
        clearFrameViewBackdrop()

        // Order in / out based on the controller's openMode. Combine
        // tracks both mode and expanded state so we can refresh the
        // hosted view's reload token if needed.
        controller.$openMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.applyVisibility(mode: mode)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: IslandScreenResolver.selectionDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
    }

    // Round 2 Bug 2 fix: the strip MUST be eligible to become key so
    // AppKit forwards scroll-wheel events to the embedded SwiftUI
    // ScrollView. Combined with `becomesKeyOnlyIfNeeded = true` and
    // the `.nonactivatingPanel` style mask, becoming key here never
    // activates the app or steals text input focus from the user's
    // underlying app — the panel simply enters the responder chain
    // when the cursor is over it, which is exactly what scroll
    // routing requires.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit inserts an internal `NSNextStepFrame` above our hosting view
    /// after `contentView` assignment. Iter 5 cleared the host itself, but
    /// that parent frame still had AppKit's default draw path and can show
    /// up as the soft light-grey rounded ribbon around the whole strip.
    /// Make the wrapper layer-backed and transparent too; sidebar/card
    /// materials are deeper in the SwiftUI tree and remain unchanged.
    private func clearFrameViewBackdrop() {
        guard let frameView = contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.isOpaque = false
        frameView.layerContentsRedrawPolicy = .never
        frameView.appearance = nil
    }

    // MARK: - Geometry

    @objc private func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshFrame()
        }
    }

    private func refreshFrame() {
        let visible = IslandScreenResolver.currentVisibleFrame()
        let frame = Self.computeFrame(visibleFrame: visible)
        setFrame(frame, display: true, animate: false)
    }

    /// Pure-geometry helper exposed at static scope so tests can verify
    /// the strip's frame math without instantiating an NSPanel.
    ///
    /// ROO-208 iter 4: the strip spans the full screen width minus
    /// `2 × sideMargin`. The previous version subtracted the orb's
    /// hover area on the right, but the strip and the orb don't share
    /// a horizontal band anymore once the cards row needs the full
    /// width to fan out; the orb-avoidance dropped the strip to ~half
    /// the screen on default-positioned orbs. `minimumWidth` is a
    /// safety floor for degenerate visibleFrame reports only.
    static func computeFrame(visibleFrame visible: NSRect) -> NSRect {
        let leftX = visible.minX + sideMargin
        let rightX = visible.maxX - sideMargin
        let width = max(rightX - leftX, minimumWidth)
        let originY = visible.minY + bottomMargin
        return NSRect(x: leftX, y: originY, width: width, height: height)
    }

    // MARK: - Visibility lifecycle

    private func applyVisibility(mode: HistoryStripMode?) {
        if mode == nil {
            // Tear down event monitors when closing — they only need to
            // exist while the strip is on screen.
            removeEventMonitors()
            orderOut(nil)
            return
        }
        refreshFrame()
        orderFrontRegardless()
        // ROO-208 iter 15: become key so the local key monitor below
        // catches Enter even before the user has interacted with the
        // strip in any other way. Same `.nonactivatingPanel` +
        // `becomesKeyOnlyIfNeeded` combo as `HistoryExpandedPanel` —
        // becoming key does NOT activate Sidekey (the style mask
        // suppresses app activation), so the user's underlying app
        // keeps text-input focus, but the local NSEvent monitor's
        // closure DOES fire on Enter keystrokes.
        makeKey()
        installEventMonitors()
    }

    private func installEventMonitors() {
        // Round 2 Bug 4: Sidekey runs at `.accessory` activation policy
        // and the strip is `.nonactivatingPanel`, so the user's
        // underlying app (Slack, Notes, etc.) stays key. Esc has to fire
        // even when our window isn't key — that requires a GLOBAL
        // event monitor (`addGlobalMonitorForEvents`), since the local
        // monitor only fires when Sidekey itself is the active app.
        //
        // We still install a local monitor too: after Bug 2 the strip
        // becomes key on hover (so scroll-wheel works), and on hover
        // the local monitor fires + can swallow the Esc event by
        // returning `nil`. Without that, hover-pressing Esc would
        // beep before closing.
        if globalKeyMonitor == nil {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return }
                guard event.keyCode == 53 else { return }  // Esc
                DispatchQueue.main.async {
                    self.controller.handleEsc()
                }
            }
            globalKeyMonitor = monitor
        }
        if localKeyMonitor == nil {
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.controller.handleEsc()
                    return nil
                }
                // ROO-208 iter 15: Return (36) / Numpad Enter (76)
                // triggers paste-to-target IF the user is hovering a
                // card. Layout-agnostic — matches by keyCode, not
                // `event.characters` (mirrors iter-13's Cmd+A/C
                // pattern in `HistoryExpandedPanel`). Enter with no
                // hover is a silent no-op: returning `nil` swallows
                // the event so AppKit doesn't beep, but no paste
                // fires. We deliberately do NOT require the Enter to
                // be modifier-free — adding `event.modifierFlags`
                // checks would swallow Shift+Enter or Cmd+Enter
                // shortcuts the user may have bound elsewhere. With
                // no hover, the strip is the wrong surface for the
                // event regardless of modifier.
                if event.keyCode == 36 || event.keyCode == 76 {
                    if self.controller.hoveredCard != nil {
                        DispatchQueue.main.async {
                            self.handleEnterPaste()
                        }
                        return nil
                    }
                    return event  // no hover → let parent surfaces handle Enter
                }
                return event
            }
            localKeyMonitor = monitor
        }

        // Outside-click global monitor — when the user clicks anywhere
        // outside the strip's frame (and outside the expanded panel,
        // see HistoryExpandedPanel), close everything.
        if outsideClickMonitor == nil {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return }
                let screenPoint = NSEvent.mouseLocation
                if !self.frame.contains(screenPoint) {
                    DispatchQueue.main.async {
                        // The expanded panel is queried via the
                        // controller's `expandedEntry`; if it's nil, any
                        // outside-strip click closes. If it's non-nil,
                        // the expanded panel installs its own
                        // outside-click logic to avoid the strip click
                        // path closing both.
                        if self.controller.expandedEntry == nil {
                            self.controller.handleOutsideClick()
                        }
                    }
                }
                _ = event
            }
            outsideClickMonitor = monitor
        }
    }

    /// ROO-208 iter 15: write the hovered card to the pasteboard via
    /// the controller's shared helper, then trigger `AutoPasteEngine`'s
    /// already-on-pasteboard variant. Iter 16: close the strip BEFORE
    /// running the paste pipeline so Sidekey relinquishes key state and
    /// the target app reclaims focused-window status before Cmd+V posts.
    /// Iter 17: also guard on `controller.targetAppName != nil` — when
    /// the captured app had no editable focused element at strip-open,
    /// AX validation cleared the target and Enter must be a silent
    /// no-op (no pasteboard write, no strip close, no Cmd+V post).
    /// The card is still copy-able via mouse click; this guard only
    /// suppresses the auto-paste path.
    private func handleEnterPaste() {
        guard let card = controller.hoveredCard else { return }
        guard controller.targetAppName != nil else {
            // No validated text-input target — Enter is a no-op.
            // Falling through here (instead of writing the card to
            // the pasteboard anyway) matches the user's mental model:
            // if no hint shows, no action takes place. The user can
            // still click the card body to copy it and then Cmd+V
            // manually wherever they like.
            return
        }
        guard let engine = autoPasteEngine else {
            // No engine wired — preserve a sensible degradation: write
            // the card to the pasteboard anyway and close the strip,
            // so a Cmd+V follow-up still pastes. This branch only
            // fires in tests that construct the panel without the
            // engine; production wires the engine in `AppDelegate`.
            controller.writeCardToPasteboard(card, assetsDirectory: assetsDirectory)
            controller.close()
            return
        }

        // 1. Write the card's payload to the pasteboard (text/image/fileURLs).
        controller.writeCardToPasteboard(card, assetsDirectory: assetsDirectory)
        // 2. Close the strip BEFORE posting Cmd+V. Sidekey's `.accessory`
        //    policy plus the strip panel's `.nonactivatingPanel` style
        //    mask should already keep the target app frontmost while the
        //    strip is visible — but in practice `makeKey()` (added iter
        //    15 for local-monitor routing) keeps Sidekey in the key-
        //    window graph long enough that Cmd+V can race the 500 ms
        //    focusRestoreBudgetMs in `restoreTargetFocusIfNeeded` and
        //    land in nowhere. Closing first forces `orderOut` →
        //    `resignKey` → AppKit hands key status back to the target
        //    app's frontmost window. The remembered target stays
        //    captured on AutoPasteEngine across the close, so the
        //    subsequent activate() + Cmd+V still routes to the right pid.
        controller.close()
        // 3. Now run the paste pipeline. The pipeline's modifier-wait +
        //    restoreTargetFocus + settle + postCmdV all run after the
        //    strip is gone, so Cmd+V cleanly lands in the target app.
        Task { @MainActor in
            _ = await engine.pasteAlreadyOnPasteboard()
            // Return value ignored — strip is already closed; if the
            // modifier-wait timed out the user's pasteboard still has
            // the card, so a manual Cmd+V still works.
        }
    }

    private func removeEventMonitors() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
        if let m = globalKeyMonitor {
            NSEvent.removeMonitor(m)
            globalKeyMonitor = nil
        }
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }
}
