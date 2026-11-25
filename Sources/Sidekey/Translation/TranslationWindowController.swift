import AppKit
import SwiftUI
import Combine

enum TranslationOutsideClickPolicy {
    static func shouldDismiss(isText: Bool, isVisible: Bool, clickInside: Bool,
                              menuTracking: Bool, modalInteraction: Bool) -> Bool {
        isText && isVisible && !clickInside && !menuTracking && !modalInteraction
    }
}

// WHY: .project-docs/decisions/2026-10-20-translation-tools.md
enum TranslationHotkeyTogglePolicy {
    static func closes(isVisible: Bool, visibleMode: TranslationWindowController.Mode,
                       requested: TranslationWindowController.Mode) -> Bool {
        isVisible && visibleMode == requested
    }
}

@MainActor
final class TranslationWindowController: NSObject, NSWindowDelegate {
    enum Mode: String, CaseIterable { case text = "Text", subtitles = "Subtitles" }
    final class Presentation: ObservableObject {
        @Published var mode: Mode = .text
        @Published var isTextPresented = false
        @Published var inputFocusRequest: UInt64 = 0

        func requestInputFocus() { inputFocusRequest &+= 1 }
    }
    let text: TextTranslationModel
    let subtitles: LiveSubtitleModel
    let presentation = Presentation()
    /// × and the session button, clicked through the panel's `sendEvent`.
    let hitTargets = SubtitleOverlayHitTargets()
    /// Click-to-copy of a translation and its "Copied ✓", shared with the Toolbox pane.
    let copier: PromptCopier
    /// The overlay caption's scroll position, fed by the panel's scroll events.
    let scroll = SubtitleCaptionScroll()
    /// Moves and resizes the subtitle overlay from the panel's own events.
    let frameTracker = SubtitleOverlayFrameTracker()
    /// The displays' visible frames and the island's, for placing the overlay
    /// (tests substitute them).
    var screens: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
    var islandScreen: () -> NSRect = { IslandScreenResolver.currentVisibleFrame() }
    private var embeddingID: UUID?
    var isEmbedded: Bool { embeddingID != nil }
    private let panel: TranslationPanel
    private var modeObservation: AnyCancellable?
    private var preferences = Set<AnyCancellable>()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = 0
    /// The text palette keeps its own width, stored apart from the shared
    /// autosaved frame, so the wider subtitle overlay never changes it.
    // WHY: .project-docs/decisions/2026-11-21-compact-subtitle-overlay.md
    static let textWidthKey = "sidekey.translation.textPaletteWidth"
    static let defaultTextWidth: CGFloat = 560
    private let defaults: UserDefaults
    private var textWidth: CGFloat
    /// nil until the first layout: a restored frame says nothing about its mode.
    private var laidOutMode: Mode?
    private var applyingLayout = false

    var window: NSWindow { panel }

    init(textModel: TextTranslationModel? = nil, subtitleModel: LiveSubtitleModel? = nil,
         defaults: UserDefaults = .standard,
         pasteboard: NSPasteboard = .general,
         openSettings: @escaping (AIFeature) -> Void,
         activityChanged: @escaping (Bool) -> Void) {
        copier = TranslationView.makeCopier(pasteboard: pasteboard)
        text = textModel ?? TextTranslationModel()
        subtitles = subtitleModel ?? LiveSubtitleModel()
        self.defaults = defaults
        let storedWidth = defaults.double(forKey: Self.textWidthKey)
        textWidth = storedWidth >= 360 ? CGFloat(storedWidth) : Self.defaultTextWidth
        panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 140),
                                 styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        super.init()
        preferences = TranslationPreferences(defaults: defaults).bind(text: text, subtitles: subtitles)
        panel.title = "Whytap Translate"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 120)
        // A new frame key avoids restoring the former 610pt form as a quick palette.
        panel.setFrameAutosaveName("WhytapTranslationCompact")
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.contentView = FirstClickHostingView(rootView: TranslationView(
            text: text, subtitles: subtitles, presentation: presentation,
            openSettings: { [weak self] feature in
                self?.dismiss()
                openSettings(feature)
            },
            close: { [weak self] in self?.dismiss() },
            hitTargets: hitTargets,
            copier: copier,
            scroll: scroll
        ))
        panel.hitTargets = hitTargets
        panel.frameTracker = frameTracker
        panel.scroll = scroll
        frameTracker.hitTargets = hitTargets
        frameTracker.screens = { [weak self] in self?.screens() ?? [] }
        frameTracker.didFinish = { [weak self] frame in self?.rememberSubtitleFrame(frame) }
        if let content = panel.contentView { frameTracker.install(on: content) }
        adoptTextWidth(restoredFrame: panel.frame)
        configureChrome(for: .text)
        let publish = { [weak self] in
            guard let self else { return }
            activityChanged(self.isEmbedded || self.panel.isVisible || self.text.isTranslating || self.subtitles.phase.isActive)
        }
        text.onActivityChange = publish
        subtitles.onActivityChange = publish
        modeObservation = presentation.$mode.dropFirst().sink { [weak self] mode in
            self?.resize(for: mode)
        }
    }

    func show(_ mode: Mode) {
        if presentation.mode == mode { resize(for: mode) }
        else { presentation.mode = mode }
        if !panel.isVisible, mode == .subtitles {
            // Where the user left it, on the display it was left on.
            // WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
            applyingLayout = true
            panel.setFrame(subtitleFrame(), display: false)
            applyingLayout = false
        } else if !panel.isVisible {
            let frame = IslandScreenResolver.currentVisibleFrame()
            let width = min(panel.frame.width, frame.width - 32)
            let height = min(panel.frame.height, frame.height - 48)
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: mode == .subtitles ? frame.minY + 72 : frame.midY - height / 2,
                                  width: width, height: height), display: false)
        }
        if mode == .text {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Like the original overlay, subtitles never take keyboard focus
            // from the video or call; a click on a control still works.
            panel.orderFrontRegardless()
        }
        presentation.isTextPresented = mode == .text
        if mode == .text { presentation.requestInputFocus() }
        frameTracker.isEnabled = mode == .subtitles
        updateOutsideClickMonitors(for: mode)
        text.onActivityChange?()
    }

    /// The subtitle overlay's frame for this launch and these displays.
    func subtitleFrame() -> NSRect {
        SubtitleOverlayFrame.restored(saved: SubtitleOverlayFrame.load(from: defaults), screens: screens(),
                                      fallback: islandScreen())
    }

    /// A move or resize by the user is the overlay's place from now on.
    private func rememberSubtitleFrame(_ frame: NSRect) {
        guard laidOutMode == .subtitles else { return }
        SubtitleOverlayFrame.save(frame, to: defaults)
    }

    /// A tool hotkey's second press closes the same visible mode; the other
    /// mode switches the open window instead of closing it.
    func toggle(_ mode: Mode) { toggle(mode, windowVisible: panel.isVisible) }

    /// Visibility is a parameter so tests reach the close path without
    /// putting the panel on the user's screen.
    func toggle(_ mode: Mode, windowVisible: Bool) {
        if TranslationHotkeyTogglePolicy.closes(isVisible: windowVisible, visibleMode: presentation.mode,
                                                requested: mode) {
            dismiss()
        } else {
            show(mode)
        }
    }

    // WHY: .project-docs/decisions/2026-11-21-compact-subtitle-overlay.md
    static let subtitleSize = SubtitleOverlayFrame.defaultSize
    static let minimumWidth: CGFloat = 360

    /// Internal so tests can check the layout without putting the panel on screen.
    func resize(for mode: Mode) {
        hitTargets.cancelPress()
        frameTracker.cancel()
        let isText = mode == .text
        configureChrome(for: mode)
        // Subtitles: the smallest box that still holds the controls, a
        // problem with its fix and the caption.
        // WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
        panel.minSize = isText ? NSSize(width: Self.minimumWidth, height: 120) : SubtitleOverlayFrame.minimumSize
        let screen = IslandScreenResolver.currentVisibleFrame()
        var frame = panel.frame
        if laidOutMode == .text { rememberTextWidth(frame.width) }
        if isText {
            let top = frame.maxY
            frame.size = NSSize(width: max(textWidth, panel.minSize.width), height: 140)
            if laidOutMode == .text {
                frame.origin.y = top - frame.height
            } else {
                frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
            }
        } else if laidOutMode != .subtitles || !panel.isVisible {
            // Entering subtitles places the overlay where the user left it
            // (at first the bottom of the screen); a repeated show of the
            // visible overlay keeps where it is.
            frame = subtitleFrame()
        }
        frameTracker.isEnabled = !isText
        laidOutMode = mode
        applyingLayout = true
        panel.setFrame(frame, display: panel.isVisible)
        applyingLayout = false
        presentation.isTextPresented = isText && panel.isVisible
        if presentation.isTextPresented { presentation.requestInputFocus() }
        updateOutsideClickMonitors(for: mode)
    }

    private func configureChrome(for mode: Mode) {
        let isText = mode == .text
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        // The subtitle box draws its own soft shadow inside a transparent panel.
        panel.hasShadow = isText
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = isText ? 16 : 0
        panel.contentView?.layer?.masksToBounds = isText
    }

    private func updateOutsideClickMonitors(for mode: Mode) {
        guard mode == .text, panel.isVisible else { removeOutsideClickMonitors(); return }
        guard localMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseDown(at: event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation,
                                  in: event.window)
            return event // Let the clicked window receive its original click.
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseDown(at: NSEvent.mouseLocation, in: nil) }
        }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackingMenus += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus - 1)
                }
            }
        ]
    }

    private func handleMouseDown(at point: NSPoint, in eventWindow: NSWindow?) {
        guard TranslationOutsideClickPolicy.shouldDismiss(
            isText: presentation.mode == .text, isVisible: panel.isVisible,
            clickInside: eventWindow === panel || panel.frame.contains(point),
            menuTracking: trackingMenus > 0,
            modalInteraction: NSApp.modalWindow != nil || panel.attachedSheet != nil
        ) else { return }
        dismiss()
    }

    private func removeOutsideClickMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil; globalMouseMonitor = nil
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers = []; trackingMenus = 0
    }

    func dismiss() {
        hitTargets.cancelPress()
        frameTracker.cancel()
        presentation.isTextPresented = false
        removeOutsideClickMonitors()
        panel.orderOut(nil)
        cancel()
    }

    @discardableResult
    func beginEmbedding() -> UUID {
        let id = UUID()
        embeddingID = id
        text.onActivityChange?()
        return id
    }

    @discardableResult
    func endEmbedding(_ id: UUID? = nil) -> Task<Void, Never>? {
        guard isEmbedded, id == nil || id == embeddingID else { return nil }
        embeddingID = nil
        // Keep the activity guard until asynchronous capture cleanup finishes.
        // A separately visible translator still owns the shared session.
        let cleanup = panel.isVisible ? nil : cancel()
        text.onActivityChange?()
        return cleanup
    }

    @discardableResult
    func cancel() -> Task<Void, Never> { text.cancel(); return subtitles.cancel() }
    func windowWillClose(_ notification: Notification) { dismiss() }

    /// A user's resize of the text palette is its new width.
    func windowDidResize(_ notification: Notification) {
        guard !applyingLayout, laidOutMode == .text else { return }
        rememberTextWidth(panel.frame.width)
    }

    /// AppKit's own resize of the overlay (outside the tracker) is kept too.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard !applyingLayout, laidOutMode == .subtitles, !frameTracker.isTracking else { return }
        rememberSubtitleFrame(panel.frame)
    }

    /// Once per Mac: until this version stores the palette width, the shared
    /// autosaved frame belonged to the previous version, whose text palette
    /// used it too. Keep that width unless the frame is a subtitles window
    /// (the old window is at least 340 pt tall, this version's overlay 190 pt),
    /// then store the width so later launches never read the shared frame.
    private func adoptTextWidth(restoredFrame frame: NSRect) {
        guard defaults.object(forKey: Self.textWidthKey) == nil else { return }
        let isSubtitlesFrame = frame.height >= 340 || abs(frame.height - Self.subtitleSize.height) < 0.5
        if !isSubtitlesFrame, frame.width >= 360 { textWidth = frame.width }
        defaults.set(Double(textWidth), forKey: Self.textWidthKey)
    }

    private func rememberTextWidth(_ width: CGFloat) {
        guard width >= 360, abs(width - textWidth) >= 0.5 else { return }
        textWidth = width
        defaults.set(Double(width), forKey: Self.textWidthKey)
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// The subtitle overlay never takes keyboard focus, so it is not the key
/// window when the user reaches for Stop or ×. Without this, AppKit spends
/// that first click making the panel key and the button never sees it.
// WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TranslationPanel: NSPanel {
    var hitTargets: SubtitleOverlayHitTargets?
    var frameTracker: SubtitleOverlayFrameTracker?
    var scroll: SubtitleCaptionScroll?
    override var canBecomeKey: Bool { true }

    // The overlay's buttons take their click here, where it always arrives,
    // not through the first-mouse bridge that can drop it. The rest of the
    // subtitle box moves the overlay, its edges resize it, and a scroll
    // scrolls its caption.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    // WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
    override func sendEvent(_ event: NSEvent) {
        if frameTracker?.isTracking == true, frameTracker?.handle(event, in: self) == true { return }
        if let hitTargets, hitTargets.handle(event, in: self) { return }
        if let frameTracker, frameTracker.handle(event, in: self) { return }
        if event.type == .scrollWheel, frameTracker?.isEnabled == true, let scroll {
            scroll.scroll(with: event)
            return
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { close() }
}
