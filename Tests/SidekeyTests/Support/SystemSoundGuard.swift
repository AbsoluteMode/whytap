import AppKit
import ObjectiveC
import XCTest

/// Keeps a test run from playing sounds on the developer's Mac and names the
/// test that asked for one.
///
/// What made a run audible, and what is done about it:
/// - Every AppKit alert goes through `NSBeep`. AppKit keeps the alert type
///   (sound, screen flash) per process; the guard sets it to "none" with
///   `+[NSSound _setAlertType:]`, so no `NSBeep` in the test process reaches
///   the sound server, whichever AppKit path asked for it. Private API, used
///   only in this test target; without it the two recorded paths below are
///   still silent or reported.
/// - `NSApp.sendEvent(keyDown)` while the process has no key window: a test
///   process never has one, and `-[NSApplication sendEvent:]` then calls
///   `NSBeep` itself unless an event monitor took the key. An artifact of the
///   test (an app without a key window receives no keys): reported, never a
///   failure. This was the audible source on main: twelve alerts per full run.
/// - A key that reaches the end of a window's responder chain: AppKit calls
///   `noResponder(for: keyDown:)`, whose default is `NSBeep`. The user hears
///   the same in the app, so this one fails the test (see `expectingSound`).
/// - `NSSound.play()` is not played; it fails the test the same way.
/// Each call is recorded with the running test and the run ends with a report.
///
/// Installed by the `SidekeyTestBootstrap` constructor when the test bundle
/// loads, so it covers every test whatever `--filter` selects.
/// WHY: .project-docs/decisions/2026-11-23-silent-test-runs.md
@objc(WhytapSystemSoundGuard)
final class SystemSoundGuard: NSObject, XCTestObservation {
    static let shared = SystemSoundGuard()

    enum Kind: String {
        /// A key sent through `NSApp.sendEvent` with no key window.
        case noKeyWindow = "key sent to the app while it has no key window (test artifact; AppKit beeps unless a monitor takes the key)"
        /// AppKit would have played the alert sound for a key nobody took.
        case unhandledKey = "alert sound for an unhandled key"
        /// `NSSound.play()`.
        case soundFile = "sound file"
    }

    struct Record: Equatable {
        /// `-[Class testMethod]`, or `outside tests (after …)`.
        let test: String
        let kind: Kind
        let detail: String
        let expected: Bool
    }

    private let lock = NSLock()
    private var installed = false
    private var records: [Record] = []
    private weak var runningCase: XCTestCase?
    private var runningName: String?
    private var lastFinishedName: String?
    private var expectationDepth = 0

    // MARK: Install

    /// Called from `SidekeyTestBootstrap.m` at bundle load.
    @objc static func installAtLoad() {
        shared.install()
    }

    var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    private func install() {
        lock.lock()
        let already = installed
        installed = true
        lock.unlock()
        guard !already else { return }

        silenceAlerts()
        replaceSendEvent()
        replaceNoResponder()
        replaceSoundPlay()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    /// 0 = neither sound nor flash for `NSBeep` in this process.
    private func silenceAlerts() {
        let selector = NSSelectorFromString("_setAlertType:")
        guard let meta = object_getClass(NSSound.self),
              class_respondsToSelector(meta, selector),
              let implementation = class_getMethodImplementation(meta, selector) else { return }
        typealias Setter = @convention(c) (AnyClass, Selector, Int) -> Void
        unsafeBitCast(implementation, to: Setter.self)(NSSound.self, selector, 0)
    }

    private func replaceSendEvent() {
        let selector = #selector(NSApplication.sendEvent(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        typealias Original = @convention(c) (NSApplication, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSApplication, NSEvent) -> Void = { [unowned self] app, event in
            if event.type == .keyDown, app.keyWindow == nil {
                self.note(.noKeyWindow, detail: "key code \(event.keyCode)")
            }
            original(app, selector, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private func replaceNoResponder() {
        let selector = #selector(NSResponder.noResponder(for:))
        guard let method = class_getInstanceMethod(NSResponder.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, Selector) -> Void = { [unowned self] responder, eventSelector in
            // AppKit beeps only for keyDown:; every other selector is a no-op
            // there and stays with AppKit.
            guard eventSelector == #selector(NSResponder.keyDown(with:)) else {
                original(responder, selector, eventSelector)
                return
            }
            self.note(.unhandledKey, detail: Self.describe(responder: responder))
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private func replaceSoundPlay() {
        let selector = #selector(NSSound.play)
        guard let method = class_getInstanceMethod(NSSound.self, selector) else { return }
        let replacement: @convention(block) (NSSound) -> Bool = { [unowned self] sound in
            self.note(.soundFile, detail: sound.name ?? "unnamed sound")
            return true
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func describe(responder: AnyObject) -> String {
        func short(_ object: AnyObject) -> String {
            let name = String(describing: type(of: object))
            return name.count > 80 ? String(name.prefix(80)) + "…" : name
        }
        var parts = ["end of chain: \(short(responder))"]
        let window = (responder as? NSWindow) ?? (responder as? NSView)?.window
        if let window, window !== responder { parts.append("window: \(short(window))") }
        if let first = window?.firstResponder, first !== responder {
            parts.append("first responder: \(short(first))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Expectations

    /// Runs `body` where a sound is the behavior under test (for example
    /// "this key is passed on"). Nothing is played either way.
    @discardableResult
    static func expectingSound<T>(_ body: () throws -> T) rethrows -> (value: T, sounds: [Record]) {
        let start = shared.beginExpectation()
        defer { shared.endExpectation() }
        let value = try body()
        return (value, shared.records(from: start))
    }

    private func beginExpectation() -> Int {
        lock.lock(); defer { lock.unlock() }
        expectationDepth += 1
        return records.count
    }

    private func endExpectation() {
        lock.lock(); defer { lock.unlock() }
        expectationDepth -= 1
    }

    private func records(from start: Int) -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return Array(records[start...])
    }

    var allRecords: [Record] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    // MARK: Recording

    private func note(_ kind: Kind, detail: String) {
        lock.lock()
        let name = runningName
        let test = name ?? "outside tests (after \(lastFinishedName ?? "none"))"
        let expected = kind == .noKeyWindow || expectationDepth > 0
        records.append(Record(test: test, kind: kind, detail: detail, expected: expected))
        let testCase = runningCase
        lock.unlock()

        guard !expected, let testCase else { return }
        testCase.record(XCTIssue(
            type: .assertionFailure,
            compactDescription: """
            This test asked for a sound (\(kind.rawValue); \(detail)). \
            If the app would do the same, the user hears it: fix the app. \
            If the sound is the point of the test, wrap the call in \
            SystemSoundGuard.expectingSound { }.
            """
        ))
    }

    // MARK: XCTestObservation

    func testCaseWillStart(_ testCase: XCTestCase) {
        // AppKit rereads the alert type when the user's sound settings change.
        silenceAlerts()
        lock.lock(); defer { lock.unlock() }
        runningCase = testCase
        runningName = testCase.name
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock(); defer { lock.unlock() }
        lastFinishedName = testCase.name
        runningCase = nil
        runningName = nil
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let report = Self.report(allRecords)
        FileHandle.standardError.write(Data((report + "\n").utf8))
        if let path = ProcessInfo.processInfo.environment["WHYTAP_TEST_SOUND_REPORT"], !path.isEmpty {
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func report(_ records: [Record]) -> String {
        guard !records.isEmpty else { return "SystemSoundGuard: no test asked for a sound." }
        var order: [String] = []
        var grouped: [String: (count: Int, record: Record)] = [:]
        for record in records {
            let key = "\(record.test)|\(record.kind.rawValue)|\(record.detail)"
            if let existing = grouped[key] {
                grouped[key] = (existing.count + 1, record)
            } else {
                order.append(key)
                grouped[key] = (1, record)
            }
        }
        var lines = ["SystemSoundGuard: \(records.count) sound(s) kept silent, \(records.filter { !$0.expected }.count) unexpected."]
        for key in order {
            guard let (count, record) = grouped[key] else { continue }
            let mark = record.kind == .noKeyWindow ? "artifact" : record.expected ? "expected" : "UNEXPECTED"
            lines.append("  [\(mark)] \(record.test) ×\(count): \(record.kind.rawValue); \(record.detail)")
        }
        return lines.joined(separator: "\n")
    }
}
