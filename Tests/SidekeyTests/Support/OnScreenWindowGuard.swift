import AppKit
import ObjectiveC
import QuartzCore
import XCTest

/// Keeps a test run from putting windows on the developer's screen, taking
/// focus or opening modal UI, and names the test that asked for it.
///
/// What a run did on the developer's Mac, and what is done about it:
/// - Code under test shows real windows (`makeKeyAndOrderFront`,
///   `orderFrontRegardless`, `showWindow`, sheets, …). Every such request in
///   AppKit ends in `-[NSWindow _doOrderWindow:]`. The guard does not pass an
///   order-in on to the window server, so the window never reaches the screen.
///   It remembers the request instead: `isVisible` answers true until the
///   window is ordered out or closed, so "show() shows the window", "toggle
///   hides a visible window" and the like are still checked. Layout, drawing
///   into a bitmap, first responder and events sent to the window need no
///   screen and work as before.
/// - `NSApp.activate` and `NSRunningApplication.activate` are recorded and not
///   performed: the test process never takes focus, and no other app is
///   brought forward on behalf of a test.
/// - Modal UI (`runModal`, alert and panel sheets, `NSOpenPanel.begin`, menu
///   pop-ups) and `NSWorkspace.open` would block the run or open another app.
///   They are not performed, answer "cancelled", and **fail the test**: such
///   code needs an injected presenter or opener.
/// - SwiftUI delivers gestures only in a window the window server has ordered
///   in. A test that needs that calls `orderInBeyondEveryDisplay`: the window
///   is really ordered, at zero opacity, ignoring the mouse and far outside
///   every display, and the test must order it out before it ends.
/// - After every test the window server is asked which windows of this
///   process are on screen and whether the process is active. Anything found
///   fails that test and is ordered out: this catches a path the hooks miss.
///
/// Installed by the `SidekeyTestBootstrap` constructor when the test bundle
/// loads, so it covers every test whatever `--filter` selects.
/// WHY: .project-docs/decisions/2026-11-24-windowless-test-runs.md
@objc(WhytapOnScreenWindowGuard)
final class OnScreenWindowGuard: NSObject, XCTestObservation {
    static let shared = OnScreenWindowGuard()

    enum Kind: String {
        /// A window asked to be ordered in; kept off screen, `isVisible` is true.
        case window = "window kept off screen"
        /// Ordered in for real by `orderInBeyondEveryDisplay`.
        case beyondDisplays = "window ordered in beyond every display at zero opacity"
        /// `NSApp.activate`; not performed.
        case activation = "activation of the test process not performed"
        /// `NSRunningApplication.activate`; not performed.
        case otherAppActivation = "activation of another app not performed"
        /// `runModal`, a sheet of an alert or panel, `NSSavePanel.begin`.
        case modal = "modal UI"
        /// `NSMenu.popUp` and `popUpContextMenu`.
        case menu = "menu pop-up"
        /// `NSWorkspace.open` and `openApplication`.
        case workspaceOpen = "NSWorkspace open"
        /// Found on screen by the check after the test.
        case onScreen = "window on screen"
        /// The test process became the active app.
        case active = "test process is active"

        /// Kinds that fail the test that caused them.
        var fails: Bool {
            switch self {
            case .window, .beyondDisplays, .activation, .otherAppActivation: return false
            case .modal, .menu, .workspaceOpen, .onScreen, .active: return true
            }
        }
    }

    struct Record: Equatable {
        /// `-[Class testMethod]`, or `outside tests (after …)`.
        let test: String
        let kind: Kind
        let detail: String
        /// Asked for inside `recording { }`: the request is what the test checks.
        var expected = false

        /// Counts against the test that caused it.
        var isFailure: Bool { kind.fails && !expected }
    }

    /// One window of a process as the window server lists it.
    struct ScreenWindow: Equatable {
        let number: Int
        let layer: Int
        let bounds: CGRect
        let alpha: Double
    }

    private let lock = NSLock()
    private var installed = false
    private var records: [Record] = []
    private weak var runningCase: XCTestCase?
    private var runningName: String?
    private var lastFinishedName: String?
    private var hookedSelectors: [String] = []
    private var realOrderingDepth = 0

    private static var shownKey: UInt8 = 0

    // MARK: Install

    /// Called from `SidekeyTestBootstrap.m` at bundle load.
    @objc static func installAtLoad() {
        shared.install()
    }

    var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    /// Selectors the guard replaced; the tests check the list is complete.
    var hooks: [String] {
        lock.lock(); defer { lock.unlock() }
        return hookedSelectors
    }

    private func install() {
        lock.lock()
        let already = installed
        installed = true
        lock.unlock()
        guard !already else { return }

        replaceWindowOrdering()
        replaceVisibility()
        replaceActivation()
        replaceModalUI()
        replaceMenus()
        replaceWorkspaceOpen()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    private func hooked(_ cls: AnyClass, _ selector: Selector, classMethod: Bool = false) -> Method? {
        let method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)
        if method != nil {
            lock.lock()
            hookedSelectors.append("\(classMethod ? "+" : "-")[\(NSStringFromClass(cls)) \(NSStringFromSelector(selector))]")
            lock.unlock()
        }
        return method
    }

    // MARK: Windows

    private func replaceWindowOrdering() {
        // Public entry: every order except `orderFrontRegardless` and sheets.
        let orderSelector = #selector(NSWindow.order(_:relativeTo:))
        if let method = hooked(NSWindow.self, orderSelector) {
            typealias Original = @convention(c) (NSWindow, Selector, Int, Int) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let replacement: @convention(block) (NSWindow, Int, Int) -> Void = { [unowned self] window, place, relative in
                if place == NSWindow.OrderingMode.out.rawValue {
                    self.setShown(window, false)
                    original(window, orderSelector, place, relative)
                } else if self.passesRealOrdering {
                    original(window, orderSelector, place, relative)
                } else {
                    self.keepOffScreen(window)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        let regardlessSelector = #selector(NSWindow.orderFrontRegardless)
        if let method = hooked(NSWindow.self, regardlessSelector) {
            typealias Original = @convention(c) (NSWindow, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let replacement: @convention(block) (NSWindow) -> Void = { [unowned self] window in
                if self.passesRealOrdering {
                    original(window, regardlessSelector)
                } else {
                    self.keepOffScreen(window)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        // The funnel behind every public path (sheets and whatever AppKit adds
        // later). Private; without it the two public hooks above still hold.
        let funnelSelector = NSSelectorFromString("_doOrderWindow:")
        if let method = hooked(NSWindow.self, funnelSelector) {
            typealias Original = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let replacement: @convention(block) (NSWindow, AnyObject?) -> Void = { [unowned self] window, options in
                if Self.orderingMode(of: options) == NSWindow.OrderingMode.out.rawValue {
                    self.setShown(window, false)
                    original(window, funnelSelector, options)
                } else if self.passesRealOrdering {
                    original(window, funnelSelector, options)
                } else {
                    self.keepOffScreen(window)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// `NSWindowActivationRequestOptions._orderingMode`; nil when AppKit no
    /// longer has it, and the request then counts as an order-in.
    private static func orderingMode(of options: AnyObject?) -> Int? {
        guard let options = options as? NSObject,
              class_getInstanceVariable(type(of: options), "_orderingMode") != nil else { return nil }
        return options.value(forKey: "orderingMode") as? Int
    }

    private func replaceVisibility() {
        let selector = #selector(getter: NSWindow.isVisible)
        guard let method = hooked(NSWindow.self, selector) else { return }
        typealias Original = @convention(c) (NSWindow, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        realVisibility = { original($0, selector) }
        let replacement: @convention(block) (NSWindow) -> Bool = { window in
            original(window, selector) || Self.isShown(window)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// AppKit's own answer, without the remembered show request.
    private var realVisibility: (NSWindow) -> Bool = { _ in false }

    /// True while a show request for the window is remembered.
    static func isShown(_ window: NSWindow) -> Bool {
        objc_getAssociatedObject(window, &shownKey) as? Bool == true
    }

    private func setShown(_ window: NSWindow, _ shown: Bool) {
        objc_setAssociatedObject(window, &Self.shownKey, shown ? true : nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func keepOffScreen(_ window: NSWindow) {
        let first = !Self.isShown(window)
        setShown(window, true)
        // A window that is shown again while "visible" is one request.
        if first { note(.window, detail: Self.describe(window)) }
    }

    private var passesRealOrdering: Bool {
        lock.lock(); defer { lock.unlock() }
        return realOrderingDepth > 0
    }

    private static func describe(_ window: NSWindow) -> String {
        let name = String(describing: type(of: window))
        let title = window.title.isEmpty ? "" : " “\(window.title.prefix(60))”"
        return "\(name.count > 80 ? String(name.prefix(80)) + "…" : name)\(title)"
    }

    // MARK: Activation

    private func replaceActivation() {
        let ignoringSelector = #selector(NSApplication.activate(ignoringOtherApps:))
        if let method = hooked(NSApplication.self, ignoringSelector) {
            let replacement: @convention(block) (NSApplication, Bool) -> Void = { [unowned self] _, _ in
                self.note(.activation, detail: "NSApp.activate(ignoringOtherApps:)")
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let plainSelector = NSSelectorFromString("activate")
        if let method = hooked(NSApplication.self, plainSelector) {
            let replacement: @convention(block) (NSApplication) -> Void = { [unowned self] _ in
                self.note(.activation, detail: "NSApp.activate()")
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let optionsSelector = #selector(NSRunningApplication.activate(options:))
        if let method = hooked(NSRunningApplication.self, optionsSelector) {
            let replacement: @convention(block) (NSRunningApplication, UInt) -> Bool = { [unowned self] app, _ in
                self.note(.otherAppActivation, detail: app.bundleIdentifier ?? "pid \(app.processIdentifier)")
                return false
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let fromSelector = NSSelectorFromString("activateFromApplication:options:")
        if let method = hooked(NSRunningApplication.self, fromSelector) {
            let replacement: @convention(block) (NSRunningApplication, AnyObject?, UInt) -> Bool = { [unowned self] app, _, _ in
                self.note(.otherAppActivation, detail: app.bundleIdentifier ?? "pid \(app.processIdentifier)")
                return false
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    // MARK: Modal UI, menus, other apps

    private func replaceModalUI() {
        let runForSelector = #selector(NSApplication.runModal(for:))
        if let method = hooked(NSApplication.self, runForSelector) {
            let replacement: @convention(block) (NSApplication, NSWindow) -> Int = { [unowned self] _, window in
                self.note(.modal, detail: "NSApp.runModal(for: \(Self.describe(window)))")
                return NSApplication.ModalResponse.abort.rawValue
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let alertSelector = #selector(NSAlert.runModal)
        if let method = hooked(NSAlert.self, alertSelector) {
            let replacement: @convention(block) (NSAlert) -> Int = { [unowned self] alert in
                self.note(.modal, detail: "NSAlert.runModal “\(alert.messageText.prefix(60))”")
                return NSApplication.ModalResponse.abort.rawValue
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let alertSheetSelector = #selector(NSAlert.beginSheetModal(for:completionHandler:))
        if let method = hooked(NSAlert.self, alertSheetSelector) {
            typealias Handler = @convention(block) (Int) -> Void
            let replacement: @convention(block) (NSAlert, NSWindow, Handler?) -> Void = { [unowned self] alert, _, handler in
                self.note(.modal, detail: "NSAlert.beginSheetModal “\(alert.messageText.prefix(60))”")
                handler?(NSApplication.ModalResponse.abort.rawValue)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        // NSOpenPanel inherits all three.
        let panelRunSelector = #selector(NSSavePanel.runModal)
        if let method = hooked(NSSavePanel.self, panelRunSelector) {
            let replacement: @convention(block) (NSSavePanel) -> Int = { [unowned self] panel in
                self.note(.modal, detail: "\(type(of: panel)).runModal")
                return NSApplication.ModalResponse.cancel.rawValue
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        typealias PanelHandler = @convention(block) (Int) -> Void
        let panelBeginSelector = #selector(NSSavePanel.begin(completionHandler:))
        if let method = hooked(NSSavePanel.self, panelBeginSelector) {
            let replacement: @convention(block) (NSSavePanel, PanelHandler?) -> Void = { [unowned self] panel, handler in
                self.note(.modal, detail: "\(type(of: panel)).begin")
                handler?(NSApplication.ModalResponse.cancel.rawValue)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let panelSheetSelector = #selector(NSSavePanel.beginSheetModal(for:completionHandler:))
        if let method = hooked(NSSavePanel.self, panelSheetSelector) {
            let replacement: @convention(block) (NSSavePanel, NSWindow, PanelHandler?) -> Void = { [unowned self] panel, _, handler in
                self.note(.modal, detail: "\(type(of: panel)).beginSheetModal")
                handler?(NSApplication.ModalResponse.cancel.rawValue)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    private func replaceMenus() {
        let popUpSelector = #selector(NSMenu.popUp(positioning:at:in:))
        if let method = hooked(NSMenu.self, popUpSelector) {
            let replacement: @convention(block) (NSMenu, NSMenuItem?, NSPoint, NSView?) -> Bool = { [unowned self] menu, _, _, _ in
                self.note(.menu, detail: "NSMenu.popUp “\(menu.title.prefix(60))”")
                return false
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let contextSelector = #selector(NSMenu.popUpContextMenu(_:with:for:))
        if let method = hooked(NSMenu.self, contextSelector, classMethod: true) {
            let replacement: @convention(block) (AnyObject, NSMenu, NSEvent, NSView) -> Void = { [unowned self] _, menu, _, _ in
                self.note(.menu, detail: "NSMenu.popUpContextMenu “\(menu.title.prefix(60))”")
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    private func replaceWorkspaceOpen() {
        let urlSelector = #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool)
        if let method = hooked(NSWorkspace.self, urlSelector) {
            let replacement: @convention(block) (NSWorkspace, NSURL) -> Bool = { [unowned self] _, url in
                self.note(.workspaceOpen, detail: Self.describe(url as URL))
                return false
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        typealias Completion = @convention(block) (NSRunningApplication?, NSError?) -> Void
        let refused = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: "Tests do not open other apps (OnScreenWindowGuard)."])
        let configuredSelector = NSSelectorFromString("openURL:configuration:completionHandler:")
        if let method = hooked(NSWorkspace.self, configuredSelector) {
            let replacement: @convention(block) (NSWorkspace, NSURL, AnyObject?, Completion?) -> Void = { [unowned self] _, url, _, completion in
                self.note(.workspaceOpen, detail: Self.describe(url as URL))
                completion?(nil, refused)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let applicationSelector = NSSelectorFromString("openApplicationAtURL:configuration:completionHandler:")
        if let method = hooked(NSWorkspace.self, applicationSelector) {
            let replacement: @convention(block) (NSWorkspace, NSURL, AnyObject?, Completion?) -> Void = { [unowned self] _, url, _, completion in
                self.note(.workspaceOpen, detail: "application \((url as URL).lastPathComponent)")
                completion?(nil, refused)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let withApplicationSelector = NSSelectorFromString("openURLs:withApplicationAtURL:configuration:completionHandler:")
        if let method = hooked(NSWorkspace.self, withApplicationSelector) {
            let replacement: @convention(block) (NSWorkspace, NSArray, NSURL, AnyObject?, Completion?) -> Void = { [unowned self] _, _, url, _, completion in
                self.note(.workspaceOpen, detail: "URLs with application \((url as URL).lastPathComponent)")
                completion?(nil, refused)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// Scheme and host only: a URL can carry a path or query nobody should log.
    private static func describe(_ url: URL) -> String {
        url.isFileURL ? "file \(url.lastPathComponent)" : "\(url.scheme ?? "?")://\(url.host ?? "")"
    }

    // MARK: Window server

    /// Windows of `pid` the window server has on screen, whatever their
    /// level, size or opacity.
    static func screenWindows(ofProcess pid: pid_t) -> [ScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return screenWindows(in: list, ofProcess: pid)
    }

    static func screenWindows(in list: [[String: Any]], ofProcess pid: pid_t) -> [ScreenWindow] {
        list.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
            let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            return ScreenWindow(
                number: (entry[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds ?? .zero,
                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    /// What the check after a test reports for a window-server state.
    static func violations(screenWindows: [ScreenWindow], processIsActive: Bool) -> [(kind: Kind, detail: String)] {
        var found: [(Kind, String)] = screenWindows.map { window in
            (.onScreen, "window \(window.number), layer \(window.layer), \(Int(window.bounds.width))×\(Int(window.bounds.height)), alpha \(window.alpha)")
        }
        if processIsActive { found.append((.active, "the test process is the active app")) }
        return found
    }

    /// This process's windows on screen once AppKit's pending order changes
    /// have reached the window server. AppKit sends an order-in or order-out
    /// with the next Core Animation commit, so the list is read after a
    /// flush; a window still listed gets up to half a second to leave
    /// (a window closed a moment ago, or still in its closing animation, is
    /// not a finding).
    static func settledOwnScreenWindows() -> [ScreenWindow] {
        CATransaction.flush()
        var windows = screenWindows(ofProcess: getpid())
        var turns = 0
        while !windows.isEmpty, turns < 25 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            CATransaction.flush()
            windows = screenWindows(ofProcess: getpid())
            turns += 1
        }
        return windows
    }

    /// Runs after every test, while a failure still belongs to it.
    private func checkScreen() {
        let onScreen = Self.settledOwnScreenWindows()
        let active = NSRunningApplication.current.isActive
        for violation in Self.violations(screenWindows: onScreen, processIsActive: active) {
            note(violation.kind, detail: violation.detail)
        }
        guard !onScreen.isEmpty else { return }
        // Do not leave it there for the rest of the run.
        for window in NSApplication.shared.windows where realVisibility(window) {
            window.orderOut(nil)
        }
    }

    /// Where a really ordered window is put: no display reaches this far.
    static let beyondEveryDisplay = NSPoint(x: -30_000, y: -30_000)

    /// Orders `window` in for real where nobody can see or click it: zero
    /// opacity, ignoring the mouse, far outside every display, never key.
    /// For a test of a SwiftUI gesture, which SwiftUI delivers only in a
    /// window the window server has ordered in. Events still arrive through
    /// `window.sendEvent`. The test orders the window out or closes it before
    /// it ends; the check after the test fails it otherwise.
    /// Returns false, leaving the window off screen, if AppKit did not keep
    /// it outside every display.
    @discardableResult
    static func orderInBeyondEveryDisplay(_ window: NSWindow) -> Bool {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // No closing animation: the window leaves the window server at once.
        window.animationBehavior = .none
        window.setFrameOrigin(beyondEveryDisplay)
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { return false }
        shared.withRealOrdering { window.orderFrontRegardless() }
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            window.orderOut(nil)
            return false
        }
        shared.note(.beyondDisplays, detail: describe(window))
        return true
    }

    private func withRealOrdering<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); realOrderingDepth += 1; lock.unlock()
        defer { lock.lock(); realOrderingDepth -= 1; lock.unlock() }
        return try body()
    }

    // MARK: Recording

    /// Runs `body` and returns what it asked of the screen. Requests of a
    /// failing kind inside `body` are the point of the test and do not fail it.
    @discardableResult
    static func recording<T>(_ body: () throws -> T) rethrows -> (value: T, requests: [Record]) {
        let start = shared.beginRecording()
        defer { shared.endRecording() }
        let value = try body()
        return (value, shared.records(from: start))
    }

    private var recordingDepth = 0

    private func beginRecording() -> Int {
        lock.lock(); defer { lock.unlock() }
        recordingDepth += 1
        return records.count
    }

    private func endRecording() {
        lock.lock(); defer { lock.unlock() }
        recordingDepth -= 1
    }

    private func records(from start: Int) -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return Array(records[start...])
    }

    /// Marks the latest request as intended. Only for the guard's own test
    /// of the failing path, so the run's summary lists real findings only.
    func markLatestRequestExpected() {
        lock.lock(); defer { lock.unlock() }
        guard let last = records.indices.last else { return }
        records[last].expected = true
    }

    var allRecords: [Record] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    private func note(_ kind: Kind, detail: String) {
        lock.lock()
        let test = runningName ?? "outside tests (after \(lastFinishedName ?? "none"))"
        let record = Record(test: test, kind: kind, detail: detail, expected: recordingDepth > 0)
        records.append(record)
        let testCase = runningCase
        lock.unlock()

        guard record.isFailure, let testCase else { return }
        testCase.record(XCTIssue(type: .assertionFailure, compactDescription: Self.failureText(kind, detail: detail)))
    }

    static func failureText(_ kind: Kind, detail: String) -> String {
        switch kind {
        case .modal, .menu:
            return """
            This test opened \(kind.rawValue) (\(detail)). It was not shown and answered "cancelled": \
            in a test run it would stop the suite with a window on the developer's screen. \
            Give the code an injected presenter, or wrap the call in OnScreenWindowGuard.recording { } \
            when the request itself is what the test checks.
            """
        case .workspaceOpen:
            return """
            This test asked NSWorkspace to open something (\(detail)). Nothing was opened: \
            a test run must not bring another app onto the developer's screen. \
            Inject the opener, or wrap the call in OnScreenWindowGuard.recording { }.
            """
        case .onScreen, .active:
            return """
            After this test the window server shows: \(detail). A test run must not put windows on the \
            developer's screen or take focus. Find the call that got past OnScreenWindowGuard \
            (Tests/SidekeyTests/Support/OnScreenWindowGuard.swift) and add it there.
            """
        case .window, .beyondDisplays, .activation, .otherAppActivation:
            return "\(kind.rawValue): \(detail)"
        }
    }

    // MARK: XCTestObservation

    func testCaseWillStart(_ testCase: XCTestCase) {
        lock.lock()
        runningCase = testCase
        runningName = testCase.name
        lock.unlock()
        // Teardown blocks run on the main thread after the test body and its
        // own teardown, before the test is reported.
        testCase.addTeardownBlock { [weak self] in
            self?.checkScreen()
        }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock(); defer { lock.unlock() }
        lastFinishedName = testCase.name
        runningCase = nil
        runningName = nil
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let all = allRecords
        FileHandle.standardError.write(Data((Self.summary(all) + "\n").utf8))
        if let path = ProcessInfo.processInfo.environment["WHYTAP_TEST_WINDOW_REPORT"], !path.isEmpty {
            try? Self.report(all).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// One line, plus one per request that failed its test.
    static func summary(_ records: [Record]) -> String {
        let windows = records.filter { $0.kind == .window }
        let failing = records.filter(\.isFailure)
        let beyond = records.filter { $0.kind == .beyondDisplays }
        var lines = ["""
            OnScreenWindowGuard: \(windows.count) window(s) kept off screen in \(Set(windows.map(\.test)).count) test(s), \
            \(beyond.count) ordered in beyond every display at zero opacity, \
            \(records.filter { $0.kind == .activation || $0.kind == .otherAppActivation }.count) activation(s) not performed, \
            \(failing.count) failing request(s) (modal UI, menu, open, window on screen).
            """]
        for record in failing {
            lines.append("  [\(record.kind.rawValue)] \(record.test): \(record.detail)")
        }
        return lines.joined(separator: "\n")
    }

    /// Every request grouped by test, for `WHYTAP_TEST_WINDOW_REPORT`.
    static func report(_ records: [Record]) -> String {
        var order: [String] = []
        var grouped: [String: Int] = [:]
        for record in records {
            let key = "\(record.test): \(record.kind.rawValue)\(record.isFailure ? " (FAILED THE TEST)" : ""); \(record.detail)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: 0] += 1
        }
        return ([summary(records)] + order.map { "  \($0) ×\(grouped[$0] ?? 0)" }).joined(separator: "\n")
    }
}
