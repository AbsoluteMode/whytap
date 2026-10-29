import AppKit
import ScreenCaptureKit
import os.log

enum ScreenshotCaptureConfiguration {
    /// ScreenCaptureKit's filter describes points; its scale supplies the source pixels.
    // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    static func make(contentRect: CGRect, pointPixelScale: Float) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((contentRect.width * CGFloat(pointPixelScale)).rounded())
        configuration.height = Int((contentRect.height * CGFloat(pointPixelScale)).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.scalesToFit = false
        return configuration
    }
}

@MainActor
final class ScreenshotCapturePanel: NSPanel {
    weak var keyboardCanvas: ScreenshotCanvas?
    var onAdvanceFocus: ((Bool) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleEditorKey(with: event) { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleEditorKey(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    private func handleEditorKey(with event: NSEvent) -> Bool {
        if firstResponder is ScreenshotInlineTextView { return false }
        if firstResponder is ScreenshotTextMoveHandle {
            return keyboardCanvas?.performKeyEquivalent(with: event) ?? false
        }
        if event.keyCode == 48 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onAdvanceFocus?(event.modifierFlags.contains(.shift)); return true
        }
        guard !(firstResponder is NSTextView), let keyboardCanvas else { return false }
        if keyboardCanvas.performKeyEquivalent(with: event) { return true }
        if ScreenshotArrow(keyCode: event.keyCode) != nil, event.modifierFlags.intersection([.command, .control]).isEmpty {
            keyboardCanvas.keyDown(with: event); return true
        }
        return false
    }
    override func keyDown(with event: NSEvent) { keyboardCanvas?.keyDown(with: event) }
    override func cancelOperation(_ sender: Any?) { keyboardCanvas?.cancelOperation(sender) }
}

/// System observation and focus are injectable so generated-fixture tests stay
/// independent of the user's actual Space/display changes and foreground app.
@MainActor
struct ScreenshotCaptureEnvironment {
    let applicationNotifications: NotificationCenter
    let workspaceNotifications: NotificationCenter
    let frontmostApplication: () -> NSRunningApplication?

    static var system: Self {
        Self(applicationNotifications: .default, workspaceNotifications: NSWorkspace.shared.notificationCenter,
             frontmostApplication: { NSWorkspace.shared.frontmostApplication })
    }
}

/// One in-memory capture session. Files are written only on explicit Download.
@MainActor
final class ScreenshotCoordinator: NSObject, NSSharingServicePickerDelegate {
    private var windows: [ScreenshotCapturePanel] = []
    private var toolbarPanel: ScreenshotCapturePanel?
    private var settingsPanel: ScreenshotCapturePanel?
    private var toolbar: ScreenshotToolbar?
    private weak var selectedCanvas: ScreenshotCanvas?
    private var task: Task<Void, Never>?
    private var captureDeadlineTask: Task<Void, Never>?
    private var generation: UUID?
    private var previousApp: NSRunningApplication?
    private var sharePicker: NSSharingServicePicker?
    private var observers: [NSObjectProtocol] = []
    private let environment: ScreenshotCaptureEnvironment
    private var copyWaitReason: String?
    private var copyAfterProcessing = false
    private let activityChanged: (Bool) -> Void
    private let preparationChanged: (Bool) -> Void
    private var preparing = false
    private let captureOverride: (() async throws -> [(NSScreen, CGImage)])?
    private let captureTimeout: Duration
    private let captureFailure: (String) -> Void
    private var displayLayout: [ScreenshotDisplayLayout] = []
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "Screenshot")
    var isActive: Bool { generation != nil }

    init(activityChanged: @escaping (Bool) -> Void, preparationChanged: @escaping (Bool) -> Void = { _ in },
         captureOverride: (() async throws -> [(NSScreen, CGImage)])? = nil,
         captureTimeout: Duration = .seconds(10), captureFailure: ((String) -> Void)? = nil,
         environment: ScreenshotCaptureEnvironment? = nil) {
        self.activityChanged = activityChanged; self.preparationChanged = preparationChanged; self.captureOverride = captureOverride
        self.captureTimeout = captureTimeout
        self.environment = environment ?? .system
        self.captureFailure = captureFailure ?? { message in
            let alert = NSAlert(); alert.messageText = "Screenshot unavailable"
            alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.runModal()
        }
        super.init()
        observers.append(self.environment.applicationNotifications.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.displayLayout != Self.currentDisplayLayout() else { return }
                self.cancel(restoreFocus: false, reason: "display_changed")
            }
        })
        observers.append(self.environment.workspaceNotifications.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(restoreFocus: false, reason: "space_changed") }
        })
    }
    deinit {
        for observer in observers {
            environment.applicationNotifications.removeObserver(observer)
            environment.workspaceNotifications.removeObserver(observer)
        }
    }

    func start() {
        guard !isActive else {
            os_log("screenshot_start ignored_already_active", log: Self.log, type: .info)
            return
        }
        previousApp = environment.frontmostApplication()
        let token = UUID(); generation = token; activityChanged(true)
        setPreparing(true)
        displayLayout = Self.currentDisplayLayout()
        os_log("screenshot_capture begin", log: Self.log, type: .info)
        task = Task { [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            do {
                var snapshots: [(NSScreen, CGImage)] = []
                if let captureOverride = self.captureOverride {
                    self.startCaptureDeadline(token: token)
                    snapshots = try await captureOverride()
                } else {
                    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                        self.cancel(); self.showPermissionHelp(); return
                    }
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.startCaptureDeadline(token: token)
                    // Freeze the visible screen before ordering editor windows or releasing
                    // Hover. Include Whytap's own visible surfaces, like Apple's area capture.
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    for screen in NSScreen.screens {
                        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                              let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = ScreenshotCaptureConfiguration.make(contentRect: filter.contentRect, pointPixelScale: filter.pointPixelScale)
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        snapshots.append((screen, image))
                    }
                }
                guard !snapshots.isEmpty else { throw ScreenshotImageError.rendering }
                guard self.generation == token else { return }
                self.captureDeadlineTask?.cancel(); self.captureDeadlineTask = nil
                self.present(snapshots)
                self.setPreparing(false)
                os_log("screenshot_capture presented", log: Self.log, type: .info)
            } catch {
                guard self.generation == token else { return }
                self.cancel(reason: "capture_failed")
                self.captureFailure("Check Screen Recording access for Whytap in System Settings, then try again.")
            }
        }
    }

    private func startCaptureDeadline(token: UUID) {
        let timeout = captureTimeout
        captureDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == token, self.windows.isEmpty else { return }
            self.cancel(reason: "capture_timeout")
            self.captureFailure("The screen capture took too long. Press your Screenshot shortcut again to retry.")
        }
    }

    private func setPreparing(_ value: Bool) {
        guard preparing != value else { return }
        preparing = value; preparationChanged(value)
    }

    private static func currentDisplayLayout() -> [ScreenshotDisplayLayout] {
        NSScreen.screens.map { ScreenshotDisplayLayout(screen: $0) }
    }

    private func showPermissionHelp() {
        let alert = NSAlert(); alert.messageText = "Allow screenshots"
        alert.informativeText = "Enable Whytap in System Settings → Privacy & Security → Screen & System Audio Recording. If macOS asks you to reopen Whytap, finish your current work first."
        alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    private func present(_ snapshots: [(NSScreen, CGImage)]) {
        for (screen, image) in snapshots {
            let window = ScreenshotCapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .screenSaver; window.backgroundColor = .black
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let canvas = ScreenshotCanvas(image: image, size: screen.frame.size)
            window.keyboardCanvas = canvas
            window.onAdvanceFocus = { [weak self] backwards in self?.advanceFocus(backwards: backwards) }
            window.contentView = canvas
            canvas.onSelection = { [weak self, weak canvas] in
                guard let self, let canvas, !canvas.selection.isEmpty else {
                    self?.settingsPanel?.orderOut(nil); self?.toolbarPanel?.orderOut(nil); return
                }
                if self.selectedCanvas == nil {
                    self.selectedCanvas = canvas
                    for other in self.windows where other !== canvas.window { other.orderOut(nil) }
                    self.createToolbar(for: canvas)
                }
                self.positionToolbar()
            }
            canvas.onChange = { [weak self] in self?.toolbar?.refresh() }
            canvas.onCommand = { [weak self] command in self?.perform(command) }
            canvas.onBlur = { [weak self, weak canvas] rect, mode in
                guard let canvas else { return }; self?.blur(rect, mode: mode, canvas: canvas)
            }
            windows.append(window); window.orderFrontRegardless()
        }
        let underPointer = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first
        underPointer?.makeKey(); underPointer?.makeFirstResponder(underPointer?.contentView)
    }

    private func createToolbar(for canvas: ScreenshotCanvas) {
        guard toolbarPanel == nil, let parent = canvas.window else { return }
        let toolbar = ScreenshotToolbar(canvas: canvas)
        let panel = ScreenshotCapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .screenSaver; panel.contentView = toolbar
        panel.keyboardCanvas = canvas; panel.hidesOnDeactivate = false
        panel.onAdvanceFocus = { [weak self] backwards in self?.advanceFocus(backwards: backwards) }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.onCommand = { [weak self] command in self?.perform(command) }
        toolbar.onLayout = { [weak self] in self?.positionToolbar() }
        self.toolbar = toolbar; toolbarPanel = panel
        parent.addChildWindow(panel, ordered: .above)
        let settings = ScreenshotCapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false; settings.isOpaque = false; settings.backgroundColor = .clear; settings.hasShadow = true
        settings.level = .screenSaver; settings.contentView = toolbar.toolSettings
        settings.keyboardCanvas = canvas; settings.hidesOnDeactivate = false
        settings.onAdvanceFocus = { [weak self] backwards in self?.advanceFocus(backwards: backwards) }
        settings.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.addChildWindow(settings, ordered: .above); settingsPanel = settings
        positionToolbar()
    }

    private func positionToolbar() {
        guard let canvas = selectedCanvas, let parent = canvas.window, let panel = toolbarPanel, let toolbar else { return }
        guard !canvas.selection.isEmpty else { settingsPanel?.orderOut(nil); panel.orderOut(nil); return }
        toolbar.configure(availableWidth: parent.frame.width)
        let size = toolbar.fittingSize, safeTop = parent.screen?.safeAreaInsets.top ?? 0
        let frame = ScreenshotGeometry.toolbarFrame(selection: parent.convertToScreen(canvas.selection), screen: parent.frame,
                                                     size: CGSize(width: max(240, size.width), height: max(43, size.height)), safeAreaTop: safeTop)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if let settingsPanel {
            if toolbar.toolSettings.isHidden { settingsPanel.orderOut(nil) }
            else {
                let frame = ScreenshotGeometry.toolSettingsFrame(toolbar: frame, selection: parent.convertToScreen(canvas.selection), screen: parent.frame,
                                                                   size: toolbar.toolSettings.fittingSize, safeAreaTop: safeTop)
                if settingsPanel.frame != frame { settingsPanel.setFrame(frame, display: true) }
                if !settingsPanel.isVisible { settingsPanel.orderFrontRegardless() }
            }
        }
    }

    private func advanceFocus(backwards: Bool) {
        guard let toolbar else { return }
        var controls = toolbar.focusableControls + toolbar.toolSettings.focusableControls
        if let handle = selectedCanvas?.textHandle, !handle.isHidden, handle.isEnabled { controls.append(handle) }
        guard !controls.isEmpty else { return }
        let current = controls.firstIndex { control in
            guard control.window?.isKeyWindow == true else { return false }
            let responder = control.window?.firstResponder
            if responder === control { return true }
            if let editor = (control as? NSTextField)?.currentEditor() { return editor === responder }
            return false
        }
        let index = current.map { ($0 + (backwards ? -1 : 1) + controls.count) % controls.count } ?? (backwards ? controls.count - 1 : 0)
        let target = controls[index]
        target.window?.makeKey(); target.window?.makeFirstResponder(target)
    }

    func cancel(restoreFocus: Bool = true, reason: StaticString = "user_or_finished") {
        if isActive { os_log("screenshot_cancel reason=%{public}@", log: Self.log, type: .info, String(describing: reason)) }
        generation = nil; task?.cancel(); task = nil
        captureDeadlineTask?.cancel(); captureDeadlineTask = nil
        setPreparing(false)
        copyWaitReason = nil; copyAfterProcessing = false
        toolbar?.closeAuxiliaryWindows()
        if let settingsPanel { settingsPanel.parent?.removeChildWindow(settingsPanel); settingsPanel.orderOut(nil); settingsPanel.close() }
        settingsPanel = nil
        if let toolbarPanel { toolbarPanel.parent?.removeChildWindow(toolbarPanel); toolbarPanel.orderOut(nil); toolbarPanel.close() }
        toolbarPanel = nil; toolbar = nil; selectedCanvas = nil
        for window in windows { window.orderOut(nil); window.close() }; windows.removeAll()
        sharePicker = nil; activityChanged(false)
        let target = previousApp; previousApp = nil
        if restoreFocus, target?.processIdentifier != ProcessInfo.processInfo.processIdentifier { target?.activate(options: []) }
    }

    private func output(_ canvas: ScreenshotCanvas) throws -> CGImage {
        try ScreenshotRenderer.image(source: canvas.source, size: canvas.documentSize, annotations: canvas.annotations, crop: canvas.selection)
    }
    private func report(_ text: String, canvas: ScreenshotCanvas) { canvas.message = text; canvas.needsDisplay = true }

    private func blur(_ rect: CGRect, mode: ScreenshotBlurMode, canvas: ScreenshotCanvas) {
        guard !canvas.busy, let token = generation else { return }
        let source = canvas.source, size = canvas.documentSize, annotations = canvas.annotations
        canvas.busyMessage = "Blurring on this Mac… · Return: copy when ready · Esc: cancel capture"
        canvas.busy = true; copyWaitReason = "Blur"
        task = Task { [weak self, weak canvas] in
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> CGImage in
                    try Task.checkCancellation()
                    let image = try ScreenshotRenderer.image(source: source, size: size, annotations: annotations, crop: rect)
                    let boxes: [CGRect]
                    if mode == .textAndNumbers {
                        boxes = try ScreenshotTextDetector.boxes(image)
                        guard !boxes.isEmpty else { throw ScreenshotImageError.noText }
                    } else { boxes = [CGRect(x: 0, y: 0, width: 1, height: 1)] }
                    try Task.checkCancellation()
                    return try ScreenshotRenderer.blurred(image, boxes: boxes)
                }
                let patch = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, let canvas, self.generation == token, !Task.isCancelled else { return }
                canvas.commit(ScreenshotAnnotation(tool: .blur, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], patch: patch))
                canvas.busy = false; self.copyWaitReason = nil
                self.report(mode == .textAndNumbers ? "Text and numbers blurred · Check the result · ⌘Z Undo" : "Area blurred · ⌘Z Undo", canvas: canvas)
                if self.copyAfterProcessing { self.copyAfterProcessing = false; self.perform(.copy) }
            } catch {
                guard let self, let canvas, self.generation == token else { return }
                canvas.busy = false; self.copyWaitReason = nil; self.copyAfterProcessing = false
                self.report(error is ScreenshotImageError ? error.localizedDescription : "Text detection failed. Try Entire area, or try again.", canvas: canvas)
            }
        }
    }

    func perform(_ command: ScreenshotCommand) {
        if case .cancel = command { cancel(); return }
        guard let canvas = selectedCanvas, !canvas.selection.isEmpty else { return }
        if canvas.busy {
            if case .copy = command, let reason = copyWaitReason {
                copyAfterProcessing = true
                canvas.busyMessage = "Copying when \(reason) finishes… · Esc: cancel capture"
                report(canvas.busyMessage, canvas: canvas)
            }
            return
        }
        canvas.finishTextEditing()
        do {
            switch command {
            case .copy:
                export(canvas, download: false)
            case .copyText: copyText(canvas)
            case .download: export(canvas, download: true)
            case .share:
                guard let toolbar else { return }
                let image = NSImage(cgImage: try output(canvas), size: .zero)
                let picker = NSSharingServicePicker(items: [image]); picker.delegate = self; sharePicker = picker
                picker.show(relativeTo: toolbar.bounds, of: toolbar, preferredEdge: .minY)
            case .cancel: break
            }
        } catch { report(error.localizedDescription, canvas: canvas) }
    }

    private func export(_ canvas: ScreenshotCanvas, download: Bool) {
        guard let token = generation else { return }
        let source = canvas.source, size = canvas.documentSize, annotations = canvas.annotations, crop = canvas.selection
        canvas.busyMessage = download ? "Downloading to Downloads…" : "Preparing clipboard…"
        copyWaitReason = download ? "Download" : nil
        canvas.busy = true
        task = Task { [weak self, weak canvas] in
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> (Data, URL?) in
                    try Task.checkCancellation()
                    let image = try ScreenshotRenderer.image(source: source, size: size, annotations: annotations, crop: crop)
                    let bytes = try ScreenshotDownload.png(image, scale: CGFloat(source.width) / size.width)
                    try Task.checkCancellation()
                    let url = try download ? ScreenshotDownload.write(bytes, directory: FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) : nil
                    return (bytes, url)
                }
                let (bytes, url) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, let canvas, self.generation == token, !Task.isCancelled else { return }
                canvas.busy = false; self.copyWaitReason = nil
                if let url {
                    self.report("Downloaded to Downloads as “\(url.lastPathComponent)”", canvas: canvas)
                    NSAccessibility.post(element: canvas, notification: .announcementRequested,
                                         userInfo: [.announcement: canvas.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                    if self.copyAfterProcessing { self.copyAfterProcessing = false; self.perform(.copy) }
                } else {
                    let board = NSPasteboard.general; board.clearContents()
                    guard board.setData(bytes, forType: .png) else { throw ScreenshotImageError.rendering }
                    self.cancel()
                }
            } catch {
                guard let self, let canvas, self.generation == token else { return }
                canvas.busy = false
                self.copyWaitReason = nil; self.copyAfterProcessing = false
                self.report(download ? "Couldn’t download to Downloads. Check folder access and free space, then try again." : error.localizedDescription, canvas: canvas)
            }
        }
    }

    private func copyText(_ canvas: ScreenshotCanvas) {
        guard let token = generation else { return }
        let source = canvas.source, size = canvas.documentSize, annotations = canvas.annotations, crop = canvas.selection
        canvas.busyMessage = "Reading text on this Mac… · Esc: cancel capture"
        copyWaitReason = nil; copyAfterProcessing = false
        canvas.busy = true
        task = Task { [weak self, weak canvas] in
            let result = await ScreenshotTextCopy.perform(source: source, size: size, annotations: annotations, crop: crop,
                                                          isCurrent: { [weak self] in self?.generation == token })
            guard let self, let canvas, self.generation == token, !Task.isCancelled else { return }
            canvas.busy = false
            switch result {
            case .copied: self.cancel()
            case .empty:
                self.report("No readable text or numbers found. Adjust the selection or copy the image.", canvas: canvas)
            case .failed:
                self.report("Couldn’t copy text. Try again or copy the image.", canvas: canvas)
            case .discarded: break
            }
        }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service != nil { Task { @MainActor [weak self] in self?.cancel() } }
    }
}
