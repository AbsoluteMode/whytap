import AppKit
import WebKit
import XCTest
@testable import Sidekey

/// Stage 8b tests for `MeetingsViewerView` — the AppKit view that hosts
/// the BlockNote-backed `WKWebView` (read-only in this stage; edit sync
/// lands in Stage 8c). The plan pins three tests:
///
/// 1. `test_loadMarkdown_invokes_evaluateJavaScript_with_escaped_content`
///    — `loadMeeting(id:markdown:)` must invoke the injected JS evaluator
///    with a JSON-encoded markdown payload (so backticks, dollar signs,
///    newlines, and template-literal sequences cannot escape into the
///    BlockNote JS bridge). The script is shaped as an async IIFE wrapped
///    in try/catch — required so the bridge-ready poll can `await` and so
///    a thrown parse error does not surface as a generic WKErrorDomain
///    Code 5.
/// 2. `test_webview_crash_triggers_reload_under_cap` — when the WKWebView
///    content process terminates fewer than 3 times the view must reload
///    the BlockNote bundle.
/// 3. `test_webview_crash_3x_fallback_to_textview` — after the third
///    termination the view must swap the WKWebView out for an `NSTextView`
///    showing the cached raw markdown plus an "Editor failed to load,
///    showing source" banner.
@MainActor
final class MeetingsViewerViewTests: XCTestCase {

    // MARK: - Stubs

    /// Records every `evaluate(_:)` invocation so the markdown-escape
    /// test can assert the exact JS string the production view would
    /// send to the BlockNote bridge.
    final class StubJSEvaluator: MeetingsViewerJavaScriptEvaluating, @unchecked Sendable {
        private let lock = NSLock()
        private var _scripts: [String] = []

        var scripts: [String] {
            lock.lock(); defer { lock.unlock() }
            return _scripts
        }

        func evaluate(_ script: String) async throws -> Any? {
            lock.lock(); defer { lock.unlock() }
            _scripts.append(script)
            return nil
        }
    }

    /// Counts bundle reloads triggered by the WebContent-process crash
    /// recovery path.
    final class StubBundleLoader: MeetingsViewerBundleLoading, @unchecked Sendable {
        private(set) var reloadCalls = 0

        func reloadBundle() {
            reloadCalls += 1
        }
    }

    // MARK: - Helpers

    private func makeViewer(
        evaluator: StubJSEvaluator,
        bundleLoader: StubBundleLoader,
        crashCap: Int = 3
    ) -> MeetingsViewerView {
        MeetingsViewerView(
            evaluator: evaluator,
            bundleLoader: bundleLoader,
            crashCap: crashCap,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
    }

    // MARK: - Test 1: loadMarkdown escapes via JSON encoder

    func test_loadMarkdown_invokes_evaluateJavaScript_with_escaped_content() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader)
        let id = UUID()
        // Markdown chosen to exercise every JS-string interpolation
        // hazard the plan flags: backtick, dollar sign, template-literal
        // `${` opener, double quote, single quote, backslash, newline.
        let markdown = """
        Decisions: `${shell}` \"quoted\" 'single'
        Backslash: \\ end.
        """

        // Pull-model: announce editorReady first so the load below
        // pushes immediately. Without this, the load would buffer in
        // `pendingLoad` and the evaluator would never be invoked.
        // Pre-pull-model the load fired unconditionally and the test
        // didn't need this prologue.
        viewer.handleScriptMessage(name: MeetingsViewerView.editorReadyHandlerName, body: [:])
        await Task.yield()

        await viewer.loadMeeting(id: id, markdown: markdown)

        XCTAssertEqual(evaluator.scripts.count, 1)
        let script = try XCTUnwrap(evaluator.scripts.first)

        // The production script wraps the call in an async IIFE with a
        // try/catch so that (a) the bridge-ready poll can `await`, (b)
        // a thrown error from `tryParseMarkdownToBlocks` is caught and
        // logged instead of arriving back to Swift as a generic
        // WKErrorDomain Code 5 ("unsupported type"). The script is a
        // plain `(async () => { ... })()` — no outer sync wrapper.
        // History: PR #213 (Sidekey 1.4.2) tried wrapping this in an
        // outer sync arrow IIFE to drop the Code 5 marshal warning;
        // that combination crashed production with EXC_BREAKPOINT inside
        // `_evaluateJavaScript:asAsyncFunction:` on macOS 26 (see crash
        // log `~/Library/Logs/DiagnosticReports/Sidekey-2026-05-20-213253.ips`
        // and PR #215 / Sidekey 1.4.3 revert). The Code 5 warning is
        // cosmetic; the crash is not.
        XCTAssertTrue(
            script.hasPrefix("(async () => {"),
            "Viewer must use a plain async IIFE — no outer sync wrapper. PR #213's sync wrapper crashed prod on macOS 26, reverted in 1.4.3."
        )
        XCTAssertTrue(
            script.contains("try {"),
            "Viewer must wrap the IIFE body in try/catch so thrown errors don't surface as WKErrorDomain Code 5."
        )
        XCTAssertTrue(
            script.contains("} catch"),
            "Viewer must wrap the IIFE body in try/catch so thrown errors don't surface as WKErrorDomain Code 5."
        )
        XCTAssertTrue(
            script.contains("await window.loadMarkdown("),
            "Viewer must await the loadMarkdown bridge so the IIFE resolves after the editor swaps blocks."
        )
        XCTAssertFalse(
            script.hasPrefix("void "),
            "Viewer must NOT use the `void` operator on the IIFE — PR #205 tried that on macOS 26 and crashed production with EXC_BREAKPOINT in WKWebView's async marshaler (reverted in 1.3.2)."
        )
        XCTAssertFalse(
            script.hasPrefix("(() => {"),
            "Viewer must NOT wrap the async IIFE in an outer sync arrow IIFE — PR #213 tried that to drop the Code 5 marshal warning, but the combination crashed prod with EXC_BREAKPOINT on macOS 26 (reverted in 1.4.3)."
        )

        // Reproduce the encode the production path is expected to do
        // and assert the call site embeds the same encoded literal. If
        // an implementation regresses to template-literal interpolation
        // this comparison will fail (raw markdown would appear inline,
        // not the JSON-encoded form).
        let data = try JSONSerialization.data(
            withJSONObject: markdown, options: [.fragmentsAllowed]
        )
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(
            script.contains(encoded),
            "Viewer must embed the JSON-encoded markdown literal verbatim. Got: \(script)"
        )

        // And the cached markdown must equal the original so the
        // crash-fallback NSTextView can render the source the user
        // last saw.
        XCTAssertEqual(viewer.currentMarkdown, markdown)
    }

    // MARK: - Plain async IIFE (1.4.3 hotfix — sync wrapper crashed prod)

    /// Anti-regression test pinning the script shape that production
    /// must ship after the 1.4.3 hotfix.
    ///
    /// Two prior attempts to suppress the WKErrorDomain Code 5 marshal
    /// warning each crashed production with `EXC_BREAKPOINT` inside
    /// WebKit's `_evaluateJavaScript:asAsyncFunction:` SPI:
    ///
    ///   - PR #205 (Sidekey 1.3.1): prefixed the IIFE with the JS
    ///     `void` operator. Reverted in PR #207 / 1.3.2.
    ///   - PR #213 (Sidekey 1.4.2): wrapped the async IIFE in an outer
    ///     synchronous arrow IIFE returning `undefined`. The outer
    ///     `undefined` was supposed to bypass the marshaler entirely,
    ///     but the crash hit anyway on macOS 26 — confirming the SPI
    ///     itself, not the return type, is the failure path. Reverted
    ///     in PR #215 / 1.4.3 (this hotfix). Crash log:
    ///     `~/Library/Logs/DiagnosticReports/Sidekey-2026-05-20-213253.ips`.
    ///
    /// The safe baseline (Sidekey 1.3.2 / 1.3.3 / 1.4.0 / 1.4.1) is a
    /// plain `(async () => { ... })()` with no outer wrapper and no
    /// `void` prefix. The hotfix pairs this script shape with an
    /// explicit `withCheckedThrowingContinuation` wrapper around the
    /// `evaluateJavaScript(_:completionHandler:)` callback API to bypass
    /// the Swift async wrapper that routes through the crashing SPI.
    /// We accept the Code 5 marshal warning as cosmetic; production
    /// stability over log cleanliness. See troubleshooting.db id 98.
    func test_makeLoadMarkdownScript_returns_plain_async_iife_after_1_4_3_hotfix() throws {
        let script = try MeetingsViewerView.makeLoadMarkdownScript(
            markdown: "test",
            generation: 1
        )

        XCTAssertTrue(
            script.hasPrefix("(async () => {"),
            "1.4.3 hotfix: script must be a plain async IIFE — the safe baseline shape that ran on macOS 26 in 1.3.2 / 1.3.3 / 1.4.0 / 1.4.1 without crashing."
        )
        XCTAssertFalse(
            script.hasPrefix("(() => {"),
            "1.4.3 hotfix anti-regression: PR #213 wrapped the async IIFE in an outer sync arrow IIFE to drop the Code 5 marshal warning; the combination crashed prod with EXC_BREAKPOINT on macOS 26. Do NOT re-introduce the outer sync wrapper without testing on macOS 26+."
        )
        XCTAssertFalse(
            script.contains("void "),
            "Anti-regression: script must NOT contain the `void` operator — PR #205 tried that on macOS 26 and crashed production with EXC_BREAKPOINT in WKWebView's async marshaler (reverted in 1.3.2)."
        )
        XCTAssertTrue(
            script.contains("await window.loadMarkdown("),
            "Bridge call to `window.loadMarkdown` must be preserved — it is the entire point of the script."
        )
        XCTAssertTrue(
            script.contains("try {"),
            "Body try/catch must be preserved so thrown errors land in console.error instead of bubbling as Code 5."
        )
        XCTAssertTrue(
            script.contains("} catch (e) {"),
            "Body try/catch must be preserved so thrown errors land in console.error instead of bubbling as Code 5."
        )
    }

    // MARK: - Test 2: crash under cap reloads the bundle

    func test_webview_crash_triggers_reload_under_cap() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader, crashCap: 3)

        viewer.handleWebContentProcessTermination()
        viewer.handleWebContentProcessTermination()

        XCTAssertEqual(
            bundleLoader.reloadCalls, 2,
            "Under the crash cap (< 3) each WebContent-process termination must trigger a fresh bundle reload."
        )
        XCTAssertFalse(
            viewer.isFallbackTextViewEngaged,
            "Fallback NSTextView must not engage until the crash cap is reached."
        )
    }

    // MARK: - Test 3: crash at cap engages NSTextView fallback

    func test_webview_crash_3x_fallback_to_textview() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader, crashCap: 3)

        // Pre-load a markdown so the fallback view has something to
        // render (the spec requires the source to remain visible when
        // BlockNote dies).
        let markdown = "# Plan\n- Ship Stage 8b\n- Wire edit bridge in 8c\n"
        await viewer.loadMeeting(id: UUID(), markdown: markdown)

        viewer.handleWebContentProcessTermination()
        viewer.handleWebContentProcessTermination()
        viewer.handleWebContentProcessTermination()

        XCTAssertEqual(
            bundleLoader.reloadCalls, 2,
            "Bundle must reload on terminations 1 and 2 only; the third triggers the fallback."
        )
        XCTAssertTrue(
            viewer.isFallbackTextViewEngaged,
            "Reaching the crash cap must engage the NSTextView fallback for the cached markdown."
        )

        // Subview hierarchy: the fallback path replaces the WKWebView
        // with an NSScrollView wrapping an NSTextView and a banner.
        let descendants = collectDescendants(of: viewer)
        XCTAssertTrue(
            descendants.contains(where: { $0 is NSTextView }),
            "Fallback subview hierarchy must contain an NSTextView."
        )
        XCTAssertFalse(
            descendants.contains(where: { $0 is WKWebView }),
            "Fallback subview hierarchy must no longer host the WKWebView."
        )

        let bannerText = descendants
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .first { $0.contains("Editor failed to load") }
        XCTAssertNotNil(
            bannerText,
            "Fallback must show an 'Editor failed to load, showing source' banner."
        )
    }

    // MARK: - Pull-model editorReady bridge (first-open fix)

    /// `loadMeeting` arriving before the BlockNote bundle has signalled
    /// `editorReady` must NOT push the markdown into the JS bridge.
    /// Pre-pull-model the call evaluated immediately and either lost
    /// the markdown (React's initial empty-doc render fired after) or
    /// hit `loadMarkdown` undefined. The new contract: buffer the load
    /// in `pendingLoad` and wait for the JS side to declare ready.
    func test_loadMeeting_before_editorReady_does_not_invoke_evaluator() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader)
        let id = UUID()
        let markdown = "# pending body"

        await viewer.loadMeeting(id: id, markdown: markdown)

        XCTAssertEqual(
            evaluator.scripts.count, 0,
            "Viewer must NOT invoke the JS evaluator before the bundle signals editorReady."
        )
        XCTAssertFalse(
            viewer.isEditorReady,
            "isEditorReady must start false until the bundle posts the editorReady message."
        )
        let pending = try XCTUnwrap(
            viewer.pendingLoad,
            "Viewer must buffer the load in pendingLoad while waiting for editorReady."
        )
        XCTAssertEqual(pending.id, id)
        XCTAssertEqual(pending.markdown, markdown)
        XCTAssertGreaterThan(pending.generation, 0)
    }

    /// When `editorReady` finally arrives, the viewer must drain the
    /// buffered `pendingLoad` by re-entering the push path (encode +
    /// evaluator.evaluate) exactly once. After draining the buffer is
    /// cleared and `isEditorReady` flips to true.
    func test_editorReady_drains_pending_load() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader)
        let id = UUID()
        let markdown = "# drain me"

        await viewer.loadMeeting(id: id, markdown: markdown)
        XCTAssertEqual(evaluator.scripts.count, 0)

        viewer.handleScriptMessage(name: MeetingsViewerView.editorReadyHandlerName, body: [:])
        // The drain runs as an async Task hop because `handleScriptMessage`
        // is synchronous but the evaluator is async. Yield once so the
        // hop completes before we assert.
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(viewer.isEditorReady)
        XCTAssertNil(
            viewer.pendingLoad,
            "Pending load must be cleared after draining."
        )
        XCTAssertEqual(
            evaluator.scripts.count, 1,
            "editorReady must drain pendingLoad with exactly one evaluator call."
        )
        let script = try XCTUnwrap(evaluator.scripts.first)
        let data = try JSONSerialization.data(
            withJSONObject: markdown, options: [.fragmentsAllowed]
        )
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(
            script.contains(encoded),
            "Drained script must embed the JSON-encoded markdown literal."
        )
    }

    /// Once `editorReady` has been received, subsequent `loadMeeting`
    /// calls push straight through — no buffering. This is the steady
    /// state for the second-and-later opens.
    func test_loadMeeting_after_editorReady_pushes_immediately() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader)
        viewer.handleScriptMessage(name: MeetingsViewerView.editorReadyHandlerName, body: [:])
        await Task.yield()
        XCTAssertTrue(viewer.isEditorReady)

        await viewer.loadMeeting(id: UUID(), markdown: "# direct push")

        XCTAssertEqual(
            evaluator.scripts.count, 1,
            "After editorReady, loadMeeting must push immediately (one script)."
        )
        XCTAssertNil(
            viewer.pendingLoad,
            "No pendingLoad should remain when push went through directly."
        )
    }

    /// Two back-to-back `loadMeeting` calls before `editorReady` must
    /// collapse — only the newer load survives as `pendingLoad`. When
    /// `editorReady` later drains, only the newest markdown is pushed.
    /// This matches the existing `loadGeneration` "newest wins" contract
    /// the post-editorReady path already enforces.
    func test_two_loadMeetings_before_editorReady_pending_keeps_latest() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader)

        let firstId = UUID()
        let secondId = UUID()
        await viewer.loadMeeting(id: firstId, markdown: "# first")
        await viewer.loadMeeting(id: secondId, markdown: "# second")

        XCTAssertEqual(
            evaluator.scripts.count, 0,
            "Neither pre-editorReady load may invoke the evaluator."
        )
        let pending = try XCTUnwrap(
            viewer.pendingLoad,
            "Latest load must remain buffered."
        )
        XCTAssertEqual(
            pending.id, secondId,
            "Newer load must replace older load in the pending slot."
        )
        XCTAssertEqual(pending.markdown, "# second")

        viewer.handleScriptMessage(name: MeetingsViewerView.editorReadyHandlerName, body: [:])
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            evaluator.scripts.count, 1,
            "Drain must push exactly one script for the latest meeting."
        )
        let script = try XCTUnwrap(evaluator.scripts.first)
        let data = try JSONSerialization.data(
            withJSONObject: "# second", options: [.fragmentsAllowed]
        )
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(
            script.contains(encoded),
            "Drained script must carry the latest markdown, not the earlier one."
        )
    }

    /// React strict-mode double-mounts (and crash-recovery reloads) can
    /// emit `editorReady` more than once. The viewer must dedupe — the
    /// second `editorReady` after a pending drain must NOT re-push the
    /// already-served markdown.
    func test_editorReady_received_twice_is_idempotent() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader)

        await viewer.loadMeeting(id: UUID(), markdown: "# once")
        viewer.handleScriptMessage(name: MeetingsViewerView.editorReadyHandlerName, body: [:])
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(evaluator.scripts.count, 1)

        viewer.handleScriptMessage(name: MeetingsViewerView.editorReadyHandlerName, body: [:])
        await Task.yield()

        XCTAssertEqual(
            evaluator.scripts.count, 1,
            "Repeated editorReady with no new pending load must not re-push markdown."
        )
        XCTAssertNil(viewer.pendingLoad)
    }

    /// WebContent process crash invalidates the JS context. The bundle
    /// reload re-fires `editorReady` once React remounts, so we must
    /// drop `isEditorReady` back to false on termination — otherwise
    /// `loadMeeting` calls landing in the crash→re-ready gap would push
    /// into a JS context where `window.loadMarkdown` is not yet defined.
    /// The existing crash-cap reload behaviour stays intact.
    func test_webcontent_termination_resets_editor_ready() async throws {
        let evaluator = StubJSEvaluator()
        let bundleLoader = StubBundleLoader()
        let viewer = makeViewer(evaluator: evaluator, bundleLoader: bundleLoader, crashCap: 3)

        viewer.handleScriptMessage(name: MeetingsViewerView.editorReadyHandlerName, body: [:])
        await Task.yield()
        XCTAssertTrue(viewer.isEditorReady)

        viewer.handleWebContentProcessTermination()

        XCTAssertFalse(
            viewer.isEditorReady,
            "WebContent process termination must reset isEditorReady so subsequent loads buffer until the reloaded bundle re-signals."
        )
        XCTAssertEqual(
            bundleLoader.reloadCalls, 1,
            "Existing crash-cap reload behaviour must remain intact."
        )

        let id = UUID()
        await viewer.loadMeeting(id: id, markdown: "# post-crash")

        XCTAssertEqual(
            evaluator.scripts.count, 0,
            "After termination loadMeeting must buffer, not push (the JS context is being rebuilt)."
        )
        let pending = try XCTUnwrap(viewer.pendingLoad)
        XCTAssertEqual(pending.id, id)
        XCTAssertEqual(pending.markdown, "# post-crash")
    }

    // MARK: - Subview traversal helper

    private func collectDescendants(of view: NSView) -> [NSView] {
        var out: [NSView] = []
        var stack: [NSView] = view.subviews
        while let next = stack.popLast() {
            out.append(next)
            stack.append(contentsOf: next.subviews)
        }
        return out
    }
}
