import AppKit
import SwiftUI

/// The try page's field: a native `NSTextView`, so Drop treats it like any
/// Whytap editor (`DropLocalEditor`) and inserts the take straight into it.
/// `onDictated` runs only when Drop reports an insertion into this very view,
/// never for typed or pasted text. Adapted from the former onboarding's
/// `TryPasteTextEditor`.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
struct OnboardingTryField: NSViewRepresentable {
    var placeholder: String
    /// A failed take's line is drawn in its tone; nil is the quiet grey.
    var placeholderColor: NSColor? = nil
    /// The standalone preview's pretend take: typed in as Drop would, then
    /// reported like Drop's own insertion.
    var take: String? = nil
    var onDictated: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let textView = OnboardingTryTextView(frame: .zero)
        textView.placeholder = placeholder
        textView.placeholderColor = placeholderColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Try Drop here")
        scrollView.documentView = textView
        context.coordinator.observe(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onDictated = onDictated
        guard let textView = scrollView.documentView as? OnboardingTryTextView else { return }
        textView.placeholder = placeholder
        textView.placeholderColor = placeholderColor
        if let take, take != context.coordinator.lastTake {
            context.coordinator.lastTake = take
            textView.string = take
            DispatchQueue.main.async { context.coordinator.onDictated() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDictated: onDictated) }

    @MainActor
    final class Coordinator {
        var onDictated: () -> Void
        var lastTake: String?
        private var observation: NSObjectProtocol?

        init(onDictated: @escaping () -> Void) { self.onDictated = onDictated }

        func observe(_ textView: NSTextView) {
            observation = NotificationCenter.default.addObserver(
                forName: .sidekeyDropInsertedIntoLocalEditor, object: textView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDictated() }
            }
        }

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }
    }
}

/// Takes the keyboard as soon as it is on screen, so holding the shortcut
/// right away already has a target, and draws a quiet placeholder.
@MainActor
final class OnboardingTryTextView: NSTextView {
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var placeholderColor: NSColor? { didSet { if placeholderColor != oldValue { needsDisplay = true } } }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 15),
            .foregroundColor: placeholderColor ?? NSColor.placeholderTextColor,
        ]
        // Wraps: a failed take's line can be longer than the field.
        let rect = NSRect(x: textContainerInset.width, y: textContainerInset.height,
                          width: max(0, bounds.width - textContainerInset.width * 2), height: bounds.height)
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}
