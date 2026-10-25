import AppKit
import SwiftUI
import Combine

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

    var window: NSWindow { panel }

    init(textModel: TextTranslationModel? = nil, subtitleModel: LiveSubtitleModel? = nil,
         defaults: UserDefaults = .standard,
         openSettings: @escaping (AIFeature) -> Void,
         activityChanged: @escaping (Bool) -> Void) {
        text = textModel ?? TextTranslationModel()
        subtitles = subtitleModel ?? LiveSubtitleModel()
        panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 140),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        super.init()
        preferences = TranslationPreferences(defaults: defaults).bind(text: text, subtitles: subtitles)
        panel.title = "Whytap Translate"
        panel.titlebarAppearsTransparent = true
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
                self?.panel.orderOut(nil)
                self?.cancel()
                openSettings(feature)
            }
        ))
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
        text.onActivityChange?()
    }

    private func resize(for mode: Mode) {
        let isText = mode == .text
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
    func windowWillClose(_ notification: Notification) { panel.orderOut(nil); cancel() }
}

private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
