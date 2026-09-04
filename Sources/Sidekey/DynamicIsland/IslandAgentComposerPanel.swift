import AppKit

enum IslandAgentComposerOutsideClickPolicy {
    static func shouldCancel(composerVisible: Bool, clickInComposerPanel: Bool) -> Bool {
        composerVisible && !clickInComposerPanel
    }
}

@MainActor
final class IslandAgentComposerPanel: NSPanel {
    private static let textHorizontalInset: CGFloat = 12
    private static let textVerticalInset: CGFloat = 7
    private static let fontSize: CGFloat = 12
    fileprivate static let cursorWidth: CGFloat = 1.5

    private let rootView = NSView(frame: .zero)
    private let placeholderLabel = NSTextField(labelWithString: IslandAgentWingView.composerPlaceholder)
    private let scrollView = NSScrollView(frame: .zero)
    private let textView = IslandAgentComposerTextView(frame: .zero)

    private var submitHandler: (String) -> Void = { _ in }
    private var cancelHandler: () -> Void = {}
    private var textChangedHandler: (String) -> Void = { _ in }
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [
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
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false

        configureRootView()
        configureTextView()
        configureScrollView()
        configurePlaceholder()
        contentView = rootView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(
        frame targetFrame: NSRect,
        placeholder: String = IslandAgentWingView.composerPlaceholder,
        submit: @escaping (String) -> Void,
        cancel: @escaping () -> Void,
        textChanged: @escaping (String) -> Void = { _ in }
    ) {
        submitHandler = submit
        cancelHandler = cancel
        textChangedHandler = textChanged
        placeholderLabel.stringValue = placeholder
        textView.string = ""
        textChanged("")
        placeholderLabel.isHidden = false
        setFrame(targetFrame, display: false)
        layoutComposerSubviews()

        // Same overlay pattern as the old bottom-centre AgentPanel: stay
        // non-activating so the panel joins the current full-screen Space
        // instead of pulling Whytap into a different Space.
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        installOutsideClickMonitors()
        focusTextView()
    }

    func reposition(to targetFrame: NSRect) {
        guard isVisible else { return }
        setFrame(targetFrame, display: true)
        layoutComposerSubviews()
    }

    func hide() {
        removeOutsideClickMonitors()
        if isKeyWindow {
            resignKey()
        }
        orderOut(nil)
        textView.string = ""
        textChangedHandler("")
        placeholderLabel.isHidden = false
    }

    override func close() {
        hide()
    }

    deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func configureRootView() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.autoresizingMask = [.width, .height]
        rootView.addSubview(scrollView)
        rootView.addSubview(placeholderLabel)
    }

    private func configureTextView() {
        textView.onSubmit = { [weak self] text in
            guard let self else { return }
            let submit = submitHandler
            // M4: the user submitted the agent text composer (Return). Emit
            // the control click — never the typed `text` (no content/PII).
            hide()
            submit(text)
        }
        textView.onCancel = { [weak self] in
            self?.cancelAndHide()
        }
        textView.onTextChanged = { [weak self] in
            guard let self else { return }
            placeholderLabel.isHidden = !textView.string.isEmpty
            textChangedHandler(textView.string)
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = textView.composerCursorColor
        textView.font = NSFont.systemFont(ofSize: Self.fontSize, weight: .medium)
        textView.alignment = .left
        textView.textContainerInset = NSSize(width: 0, height: Self.textVerticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byClipping
        // Single-line field that scrolls horizontally to follow the caret.
        // The container must NOT track the view width: width-tracking clamps
        // the line to the visible width, so an overflowing query gets its tail
        // clipped (first chars pinned) instead of scrolling. Free width +
        // horizontal resize lets the line extend and the enclosing scroll view
        // reveal the caret end.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.height]
        textView.typingAttributes = [
            .font: textView.font as Any,
            .foregroundColor: textView.textColor as Any,
        ]
    }

    private func configureScrollView() {
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        // Clip the document view to the field: at the composing cap the line
        // scrolls, and the off-screen head/tail must not paint past the field
        // (onto the placeholder, the capsule edge, or the desktop).
        scrollView.contentView.clipsToBounds = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
    }

    private func configurePlaceholder() {
        placeholderLabel.font = NSFont.systemFont(ofSize: Self.fontSize, weight: .medium)
        placeholderLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        placeholderLabel.backgroundColor = .clear
        placeholderLabel.isBordered = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.autoresizingMask = [.width, .height]
    }

    private func focusTextView() {
        DispatchQueue.main.async { [weak self] in
            guard let self, isVisible else { return }
            makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
    }

    private func layoutComposerSubviews() {
        let bounds = NSRect(origin: .zero, size: frame.size)
        rootView.frame = bounds

        let textFrame = bounds.insetBy(dx: Self.textHorizontalInset, dy: 0)
        scrollView.frame = textFrame

        // The text view is the scroll view's document view: pin its height to
        // the visible (clip) height so it stays single-line, keep the container
        // width unbounded so the line can extend and scroll the caret into view.
        let contentHeight = scrollView.contentSize.height
        textView.minSize = NSSize(width: 0, height: contentHeight)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: contentHeight
        )
        var docFrame = textView.frame
        docFrame.origin = .zero
        docFrame.size.height = contentHeight
        docFrame.size.width = max(docFrame.size.width, scrollView.contentSize.width)
        textView.frame = docFrame

        placeholderLabel.frame = textFrame.insetBy(dx: 0, dy: Self.textVerticalInset)
    }

    private func installOutsideClickMonitors() {
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.cancelAndHide()
                }
            }
        }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self else { return event }
                let clickInComposer = event.window === self
                if IslandAgentComposerOutsideClickPolicy.shouldCancel(
                    composerVisible: isVisible,
                    clickInComposerPanel: clickInComposer
                ) {
                    cancelAndHide()
                }
                return event
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    private func cancelAndHide() {
        guard isVisible else { return }
        let cancel = cancelHandler
        hide()
        cancel()
    }

    #if DEBUG
    var composerTextViewForTesting: NSTextView { textView }

    func layoutForTesting(width: CGFloat, height: CGFloat) {
        setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
        layoutComposerSubviews()
    }
    #endif
}

@MainActor
private final class IslandAgentComposerTextView: NSTextView {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onTextChanged: (() -> Void)?

    var composerCursorColor: NSColor {
        NSColor(white: 1, alpha: 0.88)
    }

    override var acceptsFirstResponder: Bool { true }

    override func didChangeText() {
        super.didChangeText()
        onTextChanged?()
    }

    override func doCommand(by commandSelector: Selector) {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(string.replacingOccurrences(of: "\n", with: " "))
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            super.doCommand(by: commandSelector)
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard flag else { return }
        var cursorRect = rect
        cursorRect.size.width = IslandAgentComposerPanel.cursorWidth
        cursorRect.size.height = min(18, bounds.height)
        cursorRect.origin.y = bounds.midY - cursorRect.height / 2
        super.drawInsertionPoint(
            in: cursorRect,
            color: composerCursorColor,
            turnedOn: flag
        )
    }
}
