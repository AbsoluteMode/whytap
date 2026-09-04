import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Borderless centered panel hosting `HistoryExpandedView`. Orders in
/// when `controller.expandedEntry` becomes non-nil, orders out when it
/// goes back to nil. Layered above the strip so the strip remains
/// visible behind the expanded card.
@MainActor
final class HistoryExpandedPanel: NSPanel {
    /// NSWindow level for the expanded card panel. Matches
    /// `HistoryStripPanel.windowLevel` — both must beat the Dock
    /// (`kCGDockWindowLevelKey` ≈ 20). Same value as the strip is fine:
    /// AppKit's later-orderFront wins ties, and the expanded panel is
    /// always ordered AFTER the strip (`controller.expandedEntry` change
    /// triggers `orderFrontRegardless` here).
    static let windowLevel: NSWindow.Level = .statusBar

    private let controller: HistoryStripController
    private let assetsDirectory: URL

    private var cancellables = Set<AnyCancellable>()
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var outsideClickMonitor: Any?

    init(controller: HistoryStripController, assetsDirectory: URL) {
        self.controller = controller
        self.assetsDirectory = assetsDirectory

        let initialFrame = Self.centeredFrame(
            on: IslandScreenResolver.currentVisibleFrame()
        )
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        // Match `HistoryStripPanel.windowLevel`. The expanded panel must
        // beat the Dock (it can drift into the dock zone too) and stay
        // above the strip. Ordering between the two is decided by AppKit
        // because both call `orderFrontRegardless` on lifecycle events —
        // the expanded panel orders front later so it wins the tie.
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
        // Same as `HistoryStripPanel`: become key only when something
        // inside needs to receive an event (scroll-wheel over the
        // ScrollView), so we don't drag focus away from the user's
        // underlying app at order-in time.
        self.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(
            rootView: HistoryExpandedView(
                controller: controller,
                assetsDirectory: assetsDirectory
            )
        )
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = host

        controller.$expandedEntry
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                self?.applyVisibility(entry: entry)
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

    // Same `becomesKeyOnlyIfNeeded`-based pattern as `HistoryStripPanel`
    // — eligible to become key (so the embedded ScrollView receives
    // scroll-wheel events for long agent responses), but the
    // `.nonactivatingPanel` style mask still prevents the app from
    // activating, so the user's underlying app keeps text-input focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshFrame()
        }
    }

    private func refreshFrame() {
        let visible = IslandScreenResolver.currentVisibleFrame()
        setFrame(Self.centeredFrame(on: visible), display: true, animate: false)
    }

    static func centeredFrame(on visible: NSRect) -> NSRect {
        let size = HistoryExpandedView.size
        let originX = visible.midX - size.width / 2
        let originY = visible.midY - size.height / 2
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    // MARK: - Visibility lifecycle

    private func applyVisibility(entry: HistoryStripExpandedEntry?) {
        if entry == nil {
            removeEventMonitors()
            orderOut(nil)
            return
        }
        refreshFrame()
        orderFrontRegardless()
        // Make the panel key so the embedded NSTextView (under SwiftUI
        // `Text.textSelection(.enabled)`) can become first responder and
        // receive selectAll:/copy: from the responder chain. The
        // `.nonactivatingPanel` style mask prevents app activation, so
        // the user's underlying app stays frontmost regardless — only
        // this panel enters the responder chain.
        makeKey()
        installEventMonitors()
    }

    private func installEventMonitors() {
        // Round 2 Bug 4: Esc must fire from outside our app too — the
        // panel is `.nonactivatingPanel` and Sidekey is `.accessory`,
        // so the user's underlying app stays key. Global monitor
        // catches Esc regardless of which app is foreground; local
        // monitor also fires when the expanded panel itself becomes
        // key (e.g. cursor over a scrollable region) and swallows the
        // event so AppKit doesn't beep.
        if globalKeyMonitor == nil {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return }
                guard event.keyCode == 53 else { return }
                DispatchQueue.main.async {
                    self.controller.handleEsc()
                }
            }
            globalKeyMonitor = monitor
        }
        if localKeyMonitor == nil {
            // Cmd+A / Cmd+C must work on non-Latin keyboard layouts
            // (Russian/Cyrillic, Greek, Arabic, etc.). `event.characters`
            // returns the LOCALIZED character ("ф" on Russian for the "A"
            // physical key), so matching `characters == "a"` fails on
            // those layouts. `keyCode` is the only layout-agnostic
            // identifier — it maps to the physical key position on the
            // ANSI keyboard regardless of which input source is active.
            //
            // We forward to the responder chain via `NSApp.sendAction`
            // so SwiftUI's underlying NSTextView (created by
            // `Text.textSelection(.enabled)`) picks up the action when
            // it's the first responder. The panel must already be key
            // (see `makeKey()` after `orderFrontRegardless()`) for
            // first-responder routing to work.
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.controller.handleEsc()
                    return nil
                }
                let cmdOnly = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask) == .command
                if cmdOnly {
                    switch Int(event.keyCode) {
                    case kVK_ANSI_A:
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                        return nil
                    case kVK_ANSI_C:
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                        return nil
                    default:
                        break
                    }
                }
                return event
            }
            localKeyMonitor = monitor
        }
        if outsideClickMonitor == nil {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return }
                let screenPoint = NSEvent.mouseLocation
                if !self.frame.contains(screenPoint) {
                    DispatchQueue.main.async {
                        // When the expanded panel is visible, outside
                        // click closes EVERYTHING (strip + expanded) per
                        // spec.
                        self.controller.handleOutsideClick()
                    }
                }
                _ = event
            }
            outsideClickMonitor = monitor
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
