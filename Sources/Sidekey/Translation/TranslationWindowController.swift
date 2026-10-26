import AppKit
import SwiftUI
import Combine

enum TranslationOutsideClickPolicy {
    static func shouldDismiss(isText: Bool, isVisible: Bool, clickInside: Bool,
                              menuTracking: Bool, modalInteraction: Bool) -> Bool {
        isText && isVisible && !clickInside && !menuTracking && !modalInteraction
    }
}

@MainActor
final class TranslationWindowController: NSObject, NSWindowDelegate {
    enum Mode: String, CaseIterable { case text = "Text", subtitles = "Subtitles" }
    final class Presentation: ObservableObject { @Published var mode: Mode = .text }
    let text: TextTranslationModel
    let subtitles: LiveSubtitleModel
    private let presentation = Presentation()
    private var embeddingID: UUID?
    var isEmbedded: Bool { embeddingID != nil }
    private let panel: TranslationPanel
    private var modeObservation: AnyCancellable?
    private var preferences = Set<AnyCancellable>()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = 0

    var window: NSWindow { panel }

    init(textModel: TextTranslationModel? = nil, subtitleModel: LiveSubtitleModel? = nil,
         defaults: UserDefaults = .standard,
         openSettings: @escaping (AIFeature) -> Void,
         activityChanged: @escaping (Bool) -> Void) {
        text = textModel ?? TextTranslationModel()
        subtitles = subtitleModel ?? LiveSubtitleModel()
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
        panel.contentView = NSHostingView(rootView: TranslationView(
            text: text, subtitles: subtitles, presentation: presentation,
            openSettings: { [weak self] feature in
                self?.dismiss()
                openSettings(feature)
            }
        ))
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
        if !panel.isVisible {
            let frame = IslandScreenResolver.currentVisibleFrame()
            let width = min(panel.frame.width, frame.width - 32)
            let height = min(panel.frame.height, frame.height - 48)
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: mode == .subtitles ? frame.minY + 72 : frame.midY - height / 2,
                                  width: width, height: height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        updateOutsideClickMonitors(for: mode)
        text.onActivityChange?()
    }

    private func resize(for mode: Mode) {
        let isText = mode == .text
        configureChrome(for: mode)
        panel.minSize = NSSize(width: isText ? 360 : 480, height: isText ? 120 : 340)
        panel.titleVisibility = isText ? .hidden : .visible
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = isText
        }
        var frame = panel.frame
        let height: CGFloat = isText ? 140 : 400
        frame.origin.y += frame.height - height
        frame.size.width = max(frame.width, panel.minSize.width)
        frame.size.height = height
        panel.setFrame(frame, display: panel.isVisible)
        updateOutsideClickMonitors(for: mode)
    }

    private func configureChrome(for mode: Mode) {
        let isText = mode == .text
        panel.styleMask = isText ? [.borderless, .resizable, .nonactivatingPanel]
            : [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
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

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}
