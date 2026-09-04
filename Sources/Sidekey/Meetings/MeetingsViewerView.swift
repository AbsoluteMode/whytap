import AppKit
import Foundation
import WebKit
import os.log

/// Abstract JS evaluator the viewer uses to push markdown into the
/// BlockNote bridge. Production wraps `WKWebView.evaluateJavaScript`;
/// tests inject a recorder so the escape contract can be asserted
/// without spinning up a real web view.
@MainActor
protocol MeetingsViewerJavaScriptEvaluating: AnyObject {
    func evaluate(_ script: String) async throws -> Any?
}

/// Abstract bundle reload hook used by the crash-recovery path. The
/// production view re-loads the BlockNote bundle into the WKWebView;
/// tests substitute a counting stub so the cap-3 / fallback contract
/// can be exercised without a real web view crash.
@MainActor
protocol MeetingsViewerBundleLoading: AnyObject {
    func reloadBundle()
}

/// Production WKWebView adapter that conforms to both protocols above.
@MainActor
final class MeetingsViewerWebView: NSObject, MeetingsViewerJavaScriptEvaluating, MeetingsViewerBundleLoading {
    let webView: WKWebView
    private let bundleURL: URL?
    private let bundleAccessRoot: URL?

    init(webView: WKWebView, bundleURL: URL?, bundleAccessRoot: URL?) {
        self.webView = webView
        self.bundleURL = bundleURL
        self.bundleAccessRoot = bundleAccessRoot
        super.init()
    }

    /// Bridges the legacy `evaluateJavaScript(_:completionHandler:)`
    /// ObjC callback API into Swift's `async throws` shape via an
    /// explicit `withCheckedThrowingContinuation`.
    ///
    /// CRITICAL — DO NOT "modernize" this to
    /// `try await webView.evaluateJavaScript(script)`.
    ///
    /// Swift's `evaluateJavaScript(_:)` async wrapper on macOS 26 routes
    /// the call through the private SPI
    /// `_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:`
    /// `forceUserGesture:inFrame:inWorld:completionHandler:`. That SPI's
    /// `@objc completion handler block ... with result type Any` hits
    /// `EXC_BREAKPOINT` (SIGTRAP) on every Meetings window open in
    /// Sidekey 1.4.2. PR #213's outer-sync-wrapper attempt to coax the
    /// marshaler into accepting `undefined` did not help — the SPI
    /// itself, not the script's return value, is the failure path.
    /// Crash log: `~/Library/Logs/DiagnosticReports/Sidekey-2026-05-20-213253.ips`.
    ///
    /// The legacy callback form below binds directly to
    /// `-[WKWebView evaluateJavaScript:completionHandler:]` and does
    /// NOT go through the SPI. Sidekey 1.3.2 / 1.3.3 / 1.4.0 / 1.4.1
    /// ran this same callback API path (via the Swift async wrapper
    /// that calls into it on older macOS) without crashing — what
    /// changed on macOS 26 is the routing of the Swift `async` wrapper
    /// itself. Wrapping `evaluateJavaScript(_:completionHandler:)` in
    /// `withCheckedThrowingContinuation` keeps our caller's `async`
    /// surface intact while opting out of the broken SPI selection.
    ///
    /// Trade-offs we accept:
    ///   - `evaluateJavaScript(_:completionHandler:)` is soft-deprecated
    ///     on macOS 14+ in favour of the 3-arg
    ///     `evaluateJavaScript(_:in:contentWorld:completionHandler:)`.
    ///     We get a deprecation warning at build time. We accept it —
    ///     the 3-arg form historically returned `WKErrorDomain Code 5
    ///     "result of an unsupported type"` on larger payloads (see
    ///     prior comment history below), and switching to it on macOS 26
    ///     is out of scope for this hotfix.
    ///   - The Code 5 marshal warning may return in os_log. Cosmetic,
    ///     not a crash. Production stability over log cleanliness.
    ///
    /// For our IIFE: the JS callback fires after the synchronous portion
    /// of the script runs. We get back the Promise object (treated as
    /// `nil` by the Swift bridge), and the inner async work continues
    /// on the JS event loop. The script must still defend against
    /// `window.loadMarkdown` not being defined yet (poll loop inside
    /// the IIFE) and against its own errors (top-level try/catch
    /// inside the IIFE), because Swift no longer sees them.
    func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func reloadBundle() {
        // Falling back to `loadFileURL` re-creates the document inside a
        // fresh WebContent process — equivalent to a hard refresh.
        if let url = bundleURL, let root = bundleAccessRoot {
            webView.loadFileURL(url, allowingReadAccessTo: root)
        } else {
            webView.reload()
        }
    }
}

/// Weak proxy for `WKScriptMessageHandler` — a `WKUserContentController`
/// retains its message handlers, so registering `self` would leak the
/// viewer view via the WKWebView's content controller. The proxy holds
/// a weak ref back to the viewer and forwards every postMessage call.
/// Stage 8b only logs incoming messages (the `noteEdit` payload arrives
/// for real in Stage 8c).
///
/// `owner` is wrapped in a lock-protected `WeakRef` instead of a
/// `@MainActor`-isolated property because WebKit invokes the delegate
/// from a non-isolated context (the message arrives on its own
/// runloop) and we must not hop the actor just to read a weak pointer.
final class MeetingsViewerMessageProxy: NSObject, WKScriptMessageHandler {
    private final class WeakRef {
        weak var view: MeetingsViewerView?
    }

    private let weakOwner = WeakRef()
    private let lock = NSLock()

    func setOwner(_ owner: MeetingsViewerView) {
        lock.lock(); defer { lock.unlock() }
        weakOwner.view = owner
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let name = message.name
        let owner: MeetingsViewerView? = {
            lock.lock(); defer { lock.unlock() }
            return weakOwner.view
        }()
        Task { @MainActor [weak owner] in
            owner?.handleScriptMessage(name: name, body: message.body)
        }
    }
}

/// AppKit view that hosts the BlockNote `WKWebView` for the Meetings
/// window's content pane. Stage 8b ships read-only viewing; Stage 8c
/// wires the edit-sync bridge on top of the message-handler stub
/// registered here.
///
/// Responsibilities:
///
/// 1. Render the BlockNote bundle on demand via `loadFileURL`.
/// 2. Push a meeting's markdown into the bridge through
///    `window.loadMarkdown(JSON.parse(...))`. JSON encoding sidesteps
///    every JS-string interpolation hazard (backticks, dollar signs,
///    template-literal openers, newlines).
/// 3. Recover from WebContent process termination: reload the bundle
///    up to `crashCap` times, then fall back to an NSTextView showing
///    the cached markdown plus an "Editor failed to load, showing
///    source" banner.
@MainActor
final class MeetingsViewerView: NSView {

    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "viewer")

    /// Message-handler name registered with the `WKUserContentController`.
    /// Stage 8c builds the edit-sync handler on top of this name.
    static let noteEditHandlerName = "noteEdit"

    /// Message-handler name the BlockNote bundle posts to AFTER React
    /// mounts and `window.loadMarkdown` is wired. The viewer uses this
    /// signal to flip the push-model "fire and pray" gate into a
    /// pull-model: any `loadMeeting` arriving before this signal is
    /// buffered in `pendingLoad` and replayed once the signal lands.
    /// Eliminates the first-open empty-render bug where Swift pushed
    /// markdown into a JS context where the bridge function was either
    /// undefined or about to be clobbered by React's initial empty-doc
    /// render.
    static let editorReadyHandlerName = "editorReady"

    private let evaluator: MeetingsViewerJavaScriptEvaluating
    private let bundleLoader: MeetingsViewerBundleLoading
    private let crashCap: Int

    private(set) var crashCount: Int = 0
    private(set) var currentMarkdown: String?
    private(set) var currentMeetingId: UUID?

    /// Monotonic counter that lets `loadMeeting(id:markdown:)` detect
    /// that a newer selection came in while its `evaluateJavaScript`
    /// was still awaited. Without this guard, two fast back-to-back
    /// sidebar selects race inside the WKWebView and whichever
    /// `window.loadMarkdown(...)` Promise resolves LAST wins — so the
    /// user clicks meeting B but sees meeting A's markdown.
    private var loadGeneration: UInt64 = 0
    private(set) var isFallbackTextViewEngaged = false

    /// Tracks whether the BlockNote bundle has posted its `editorReady`
    /// signal since the most recent WebContent process boot. Starts
    /// false on init AND resets to false on
    /// `handleWebContentProcessTermination()` so loads landing in the
    /// crash→re-ready gap get buffered instead of pushed into a dying
    /// or re-mounting JS context.
    private(set) var isEditorReady: Bool = false

    /// Holds the most recent `loadMeeting` arguments when the viewer
    /// is asked to render before the bundle reports ready. The drain
    /// in `handleScriptMessage` consumes this slot exactly once and
    /// clears it; later loads after editorReady push directly without
    /// touching this field. Newest-wins: a second `loadMeeting` before
    /// drain replaces the slot rather than queueing — matches the
    /// `loadGeneration` contract the post-ready path already enforces.
    private(set) var pendingLoad: (id: UUID, markdown: String, generation: UInt64)?

    /// Stage 8c edit bridge. Optional so the Stage 8b test path
    /// (`MeetingsViewerViewTests`) can keep instantiating the view
    /// without wiring the bridge — the test harness does not exercise
    /// the edit pipeline. Production wires a real bridge in
    /// `MeetingsWindowController.makeProduction(...)` and forwards
    /// `noteEdit` messages straight through.
    private(set) var editBridge: MeetingsEditBridge?

    /// Subview slot that swaps between the WKWebView host (or, in test,
    /// nothing) and the crash-fallback NSScrollView+NSTextView.
    private var contentSubviews: [NSView] = []

    /// Production initialiser — wires a fresh `WKWebView` configured per
    /// the Stage 8b spec (no JS popups, `noteEdit` message handler
    /// registered via a weak proxy, navigation delegate restricted to
    /// the bundle URL). Use this from the window controller.
    convenience init(bundleURL: URL?, bundleAccessRoot: URL?) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // NOTE: The CORS-on-file:// problem for the BlockNote bundle is
        // fixed at the bundle layer (build/Resources patches strip the
        // `crossorigin` attribute from index.html) — NOT here. An earlier
        // attempt to relax it via `WKPreferences.setValue(true, forKey:
        // "allowUniversalAccessFromFileURLs")` crashed at the first menu
        // click: modern WKPreferences is not KVC-compliant for that
        // legacy key, AppKit's menu dispatcher catches the
        // NSUnknownKeyException and refuses to open Meetings. Anyone
        // tempted to add `preferences.setValue(..., forKey: "allow*")`
        // should instead extend `scripts/build-blocknote.sh` to strip
        // the offending HTML attributes.

        let proxy = MeetingsViewerMessageProxy()
        config.userContentController.add(proxy, name: Self.noteEditHandlerName)
        // Pull-model bridge: bundle posts `editorReady` once React mounts
        // and `window.loadMarkdown` is wired (see `scripts/blocknote-src/
        // src/main.tsx`). The proxy forwards both names through
        // `handleScriptMessage(name:body:)`, which dispatches on `name`.
        config.userContentController.add(proxy, name: Self.editorReadyHandlerName)

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: config
        )
        // Enable Web Inspector so we can right-click → Inspect Element to
        // see real JS errors / network failures inside the BlockNote
        // bundle when the right pane misbehaves. macOS 13.3+ only.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        // Kill the default WHITE WKWebView background. Two-layer fix
        // alongside the HTML <style> patch in scripts/build-blocknote.sh:
        //   - `setValue(false, forKey: "drawsBackground")` (the modern
        //     equivalent of NSView opaqueness) keeps WebKit from
        //     painting white during the brief window between loadFileURL
        //     and the bundle's first paint. Without it the user sees a
        //     visible white flash on every Meetings window open.
        //   - `underPageBackgroundColor` controls the color shown
        //     beyond the document edges on macOS 14+ (scroll overscroll
        //     and the area before bundle paint). Setting it to the
        //     same dark used inside the editor removes the white border
        //     seam around the BlockNote canvas.
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 14.0, *) {
            webView.underPageBackgroundColor = NSColor(
                calibratedRed: 0x1a / 255.0,
                green: 0x1a / 255.0,
                blue: 0x1a / 255.0,
                alpha: 1.0
            )
        }

        let adapter = MeetingsViewerWebView(
            webView: webView,
            bundleURL: bundleURL,
            bundleAccessRoot: bundleAccessRoot
        )

        self.init(
            evaluator: adapter,
            bundleLoader: adapter,
            crashCap: 3,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        proxy.setOwner(self)
        webView.navigationDelegate = self
        webView.uiDelegate = nil
        webView.allowsBackForwardNavigationGestures = false

        installContentView(webView)
        adapter.reloadBundle()
    }

    /// Test-friendly initialiser — accepts mockable JS evaluator + bundle
    /// loader. Production code never calls this directly.
    init(
        evaluator: MeetingsViewerJavaScriptEvaluating,
        bundleLoader: MeetingsViewerBundleLoading,
        crashCap: Int,
        frame: NSRect
    ) {
        self.evaluator = evaluator
        self.bundleLoader = bundleLoader
        self.crashCap = crashCap
        super.init(frame: frame)
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MeetingsViewerView only supports programmatic init.")
    }

    // MARK: - Public API

    /// Bind a Stage 8c `MeetingsEditBridge` so subsequent `noteEdit`
    /// messages from BlockNote flow through the bridge → coordinator
    /// pipeline. Production `MeetingsWindowController.makeProduction`
    /// calls this immediately after instantiation; Stage 8b tests
    /// don't call it (and the viewer keeps logging script messages as
    /// before).
    func attachEditBridge(_ bridge: MeetingsEditBridge) {
        editBridge = bridge
        if let id = currentMeetingId {
            bridge.attachMeeting(id: id)
        }
    }

    /// Pushes a meeting's markdown into the BlockNote bridge. The
    /// markdown is JSON-encoded so backticks, dollar signs, template
    /// literal openers, newlines, and quotes round-trip exactly. Also
    /// caches `currentMarkdown` so the crash fallback can render the
    /// last-loaded source.
    ///
    /// Pull-model gating (first-open fix): if the bundle has not yet
    /// posted `editorReady`, the markdown is parked in `pendingLoad`
    /// and the evaluator is NOT called. `handleScriptMessage` drains
    /// the slot when the signal arrives. Pre-pull-model the call
    /// fired into a JS context where `window.loadMarkdown` was either
    /// undefined or seconds away from being overwritten by React's
    /// initial empty-document render, which is exactly the
    /// first-open-empty bug the pull-model fixes.
    func loadMeeting(id: UUID, markdown: String) async {
        // Bump the generation BEFORE awaiting anything. Any older
        // in-flight `evaluate` Promises will resolve into a no-op
        // because `generation != loadGeneration` by the time they
        // come back. Wrapping arithmetic keeps the counter safe over
        // long sessions.
        loadGeneration &+= 1
        let generation = loadGeneration

        currentMeetingId = id
        currentMarkdown = markdown
        // Keep the edit bridge in step so `noteEdit` messages get
        // tagged with the meeting the user just selected.
        editBridge?.attachMeeting(id: id)

        os_log(
            "viewer loadMeeting (meetingId: %{public}@, chars: %{public}d, gen: %{public}llu)",
            log: Self.log, type: .info,
            id.uuidString, markdown.count, generation
        )

        // If we already fell back to the NSTextView path, the bridge
        // call would crash with "loadMarkdown is not a function" — push
        // the markdown straight into the text view instead.
        if isFallbackTextViewEngaged {
            renderFallbackText(markdown)
            return
        }

        // Pull-model: buffer the load if the bundle hasn't reported
        // ready yet. Newest-wins — a later `loadMeeting` arriving in
        // the same gap replaces this entry rather than queueing,
        // matching the existing `loadGeneration` "stale loads lose"
        // contract.
        guard isEditorReady else {
            pendingLoad = (id: id, markdown: markdown, generation: generation)
            os_log(
                "viewer loadMeeting deferred (waiting on editorReady, meetingId: %{public}@, gen: %{public}llu)",
                log: Self.log, type: .info,
                id.uuidString, generation
            )
            return
        }

        // editorReady has landed → push immediately, then clear any
        // stale pending slot (shouldn't be set, but a defense in
        // depth: a race where editorReady drains then we re-enter
        // with a fresh call shouldn't leave the old entry sitting).
        pendingLoad = nil
        await pushMarkdown(id: id, markdown: markdown, generation: generation)
    }

    /// JSON-encodes the markdown, builds the IIFE, and pushes it
    /// through the JS evaluator. Extracted from `loadMeeting` so the
    /// `editorReady` drain path in `handleScriptMessage` can reuse the
    /// exact same encode + log + stale-generation guard without
    /// duplicating logic.
    private func pushMarkdown(id: UUID, markdown: String, generation: UInt64) async {
        let script: String
        do {
            script = try Self.makeLoadMarkdownScript(markdown: markdown, generation: generation)
        } catch {
            os_log(
                "viewer markdown encode failed (meetingId: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
            return
        }

        do {
            let result = try await evaluator.evaluate(script)
            let resultDesc = (result as? String) ?? String(describing: result)
            guard generation == loadGeneration else {
                os_log(
                    "viewer markdown load dropped (stale gen: %{public}llu, current: %{public}llu)",
                    log: Self.log, type: .info,
                    generation, loadGeneration
                )
                return
            }
            os_log(
                "viewer markdown loaded (meetingId: %{public}@, chars: %{public}d, gen: %{public}llu, result: %{public}@)",
                log: Self.log, type: .info,
                id.uuidString, markdown.count, generation, resultDesc
            )
        } catch {
            os_log(
                "viewer evaluateJavaScript failed (meetingId: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
        }
    }

    /// Replaces whatever lives in the content slot with `view`, pinned
    /// edge-to-edge. Used by both the production init and the fallback
    /// engagement path.
    private func installContentView(_ view: NSView) {
        for old in contentSubviews { old.removeFromSuperview() }
        contentSubviews = []

        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        contentSubviews = [view]
    }

    /// Single entry point for every `WKScriptMessage` the bundle posts.
    /// Dispatches on `name`:
    ///   - `editorReady`: bundle has mounted and wired
    ///     `window.loadMarkdown`. Flip the gate, drain any buffered
    ///     load. Idempotent — a second `editorReady` (React strict-mode
    ///     double-mount, or post-crash bundle reload) with no buffered
    ///     load is a no-op.
    ///   - `noteEdit` (or anything else): forwarded to the attached
    ///     edit bridge as before. Stage 8b test path with no bridge
    ///     attached → message logged and dropped.
    func handleScriptMessage(name: String, body: Any) {
        os_log(
            "viewer script message received (name: %{public}@)",
            log: Self.log, type: .info,
            name
        )

        if name == Self.editorReadyHandlerName {
            let hadPending = pendingLoad != nil
            isEditorReady = true
            os_log(
                "viewer editor ready (had pending: %{public}@)",
                log: Self.log, type: .info,
                hadPending ? "yes" : "no"
            )
            if let pending = pendingLoad {
                // Consume the slot BEFORE awaiting the push so a
                // re-entrant `loadMeeting` arriving during the await
                // doesn't see a stale entry. The push itself honours
                // `loadGeneration`, so any newer call already won.
                pendingLoad = nil
                Task { @MainActor [weak self] in
                    await self?.pushMarkdown(
                        id: pending.id,
                        markdown: pending.markdown,
                        generation: pending.generation
                    )
                }
            }
            return
        }

        editBridge?.handleScriptMessage(name: name, body: body)
    }

    // MARK: - Crash recovery

    /// Called by `webViewWebContentProcessDidTerminate` in production
    /// and directly from the Stage 8b tests to exercise the cap-3
    /// contract without spinning up an actual WebContent crash.
    func handleWebContentProcessTermination() {
        crashCount += 1
        os_log(
            "viewer webContent terminated (crashCount: %{public}d)",
            log: Self.log, type: .error,
            crashCount
        )
        // The WebContent process crash invalidates the JS context. If
        // we reload the bundle the new React tree will re-fire
        // `editorReady`; until then, any `loadMeeting` arriving in the
        // gap must buffer (loadMarkdown is being re-wired). If we
        // engage the fallback textview, the flag is moot but resetting
        // is still correct — the pull-model gate stays accurate either
        // way.
        isEditorReady = false
        if crashCount >= crashCap {
            engageFallbackTextView()
        } else {
            bundleLoader.reloadBundle()
            os_log(
                "viewer webContent reload triggered (crashCount: %{public}d)",
                log: Self.log, type: .info,
                crashCount
            )
        }
    }

    private func engageFallbackTextView() {
        guard !isFallbackTextViewEngaged else { return }
        isFallbackTextViewEngaged = true
        os_log(
            "viewer fallback textview engaged (meetingId: %{public}@)",
            log: Self.log, type: .error,
            currentMeetingId?.uuidString ?? "nil"
        )

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let banner = NSTextField(labelWithString: "Editor failed to load, showing source")
        banner.font = .systemFont(ofSize: 12, weight: .medium)
        banner.textColor = .secondaryLabelColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.lineBreakMode = .byWordWrapping
        banner.maximumNumberOfLines = 2

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .userFixedPitchFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = currentMarkdown ?? ""

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(banner)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        installContentView(container)
    }

    private func renderFallbackText(_ markdown: String) {
        // Locate the NSTextView already mounted by `engageFallbackTextView`
        // and push the new markdown into it so the user sees the latest
        // source after a sidebar selection lands post-fallback.
        for view in contentSubviews {
            if let text = findTextView(in: view) {
                text.string = markdown
                return
            }
        }
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews {
            if let text = findTextView(in: sub) { return text }
        }
        return nil
    }

    // MARK: - JS string encoding

    /// JSON-encodes `markdown` and builds an IIFE that waits for the
    /// BlockNote bridge (`window.loadMarkdown`) to be exposed before
    /// calling it.
    ///
    /// HISTORY — 1.4.3 hotfix revert. PR #213 (Sidekey 1.4.2) attempted
    /// to drop the cosmetic `WKErrorDomain Code 5 "result of an
    /// unsupported type"` log line by wrapping the async IIFE in an
    /// outer synchronous arrow IIFE that returns `undefined`. The
    /// theory was sound (give the marshaler a plain `undefined` instead
    /// of a Promise) but the crash was not coming from the marshaler's
    /// return-type check — it was coming from the
    /// `_evaluateJavaScript:asAsyncFunction:` SPI that Swift's `async`
    /// `evaluateJavaScript(_:)` wrapper routes through on macOS 26.
    /// The sync-wrapper shape crashed prod with `EXC_BREAKPOINT` on
    /// every Meetings window open. Crash log:
    /// `~/Library/Logs/DiagnosticReports/Sidekey-2026-05-20-213253.ips`.
    /// This file restores the plain `(async () => { ... })()` shape
    /// that ran without crashing in 1.3.2 / 1.3.3 / 1.4.0 / 1.4.1. The
    /// real fix for the SPI crash lives in
    /// `MeetingsViewerWebView.evaluate(_:)`, which now bypasses the
    /// Swift async wrapper via explicit `withCheckedThrowingContinuation`
    /// around the `evaluateJavaScript(_:completionHandler:)` callback.
    /// See troubleshooting.db id 98.
    ///
    /// Why the wait loop matters: `window.loadMarkdown` is registered
    /// inside React's `useEffect`, which only fires AFTER the React
    /// tree mounts. The Swift host calls this script as soon as the
    /// sidebar selection lands — typically before mount has completed.
    /// A bare `window.loadMarkdown(...)` at that moment throws
    /// `TypeError: undefined is not a function` and the note never
    /// renders (right pane stays blank). Polling `window.loadMarkdown`
    /// up to 5 s closes that race without forcing the Swift side to
    /// duplicate `window.blockNoteReady` polling logic.
    ///
    /// Why JSON encoding (and NOT a `JSON.parse` wrap): a JSON-encoded
    /// string is already a valid JS string literal — same escaping
    /// rules for quotes, backslashes, newlines, control chars. Wrapping
    /// it in `JSON.parse(...)` was actively broken: it tried to
    /// `JSON.parse("# Title\n...")`, which throws `Unrecognized token
    /// '#'` because `#` is not a JSON token.
    ///
    /// `await window.loadMarkdown(...)` is important — the bridge is
    /// async (`tryParseMarkdownToBlocks` does IO) and we want the
    /// outer `evaluateJavaScript` to resolve only after the editor
    /// has actually swapped blocks, so the "viewer markdown loaded"
    /// log lines up with the user-visible render.
    static func makeLoadMarkdownScript(markdown: String, generation: UInt64) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: markdown,
            options: [.fragmentsAllowed]
        )
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "MeetingsViewerView",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "JSON encoding produced non-UTF8 output"]
            )
        }
        // `generation` is passed through to the JS side so the IIFE can
        // detect that a NEWER load arrived while it was awaiting either
        // the bridge-ready poll or `tryParseMarkdownToBlocks`. Without
        // this, two fast back-to-back sidebar selects race inside
        // WebKit's event loop and whichever Promise resolves last wins
        // — the user clicks meeting B but sees meeting A's blocks.
        // `window.__sidekeyLastLoadGen` lives in the page; we read +
        // CAS it atomically (single-threaded JS, so the read/write
        // pair has no interleaving risk).
        // Return type matters: WKWebView's evaluateJavaScript bridge only
        // marshals Number / String / Date / Array / Dictionary / NSNull
        // back to Swift. JS boolean → WKErrorDomain Code 5; an unhandled
        // Promise rejection from the IIFE ALSO arrives as Code 5, masking
        // the real error (e.g. `tryParseMarkdownToBlocks` throwing). We
        // therefore wrap the entire body in try/catch and ALWAYS return
        // a plain string — success or stringified error — so the Swift
        // side gets a usable result and the error message lands in our
        // logs instead of disappearing into a generic "unsupported type".
        // Fire-and-forget under legacy `evaluateJavaScript(_:completionHandler:)`.
        // Swift gets the Promise object (treated as nil) immediately; the
        // IIFE continues running in WebKit's event loop. All success /
        // failure signal goes through console.log / console.error so
        // Web Inspector shows them; the editor either renders or stays
        // blank, which is the only user-visible signal we have anyway.
        // Return value of the synchronous portion is `undefined` —
        // that's a Promise from Swift's perspective, but since the
        // callback evaluateJavaScript doesn't try to marshal it through
        // the crashing macOS 26 SPI (see `MeetingsViewerWebView.evaluate`
        // for why), we don't hit the unsupported-type error path.
        return """
        (async () => {
            const gen = \(generation);
            try {
                const deadline = Date.now() + 5000;
                while (typeof window.loadMarkdown !== 'function' && Date.now() < deadline) {
                    await new Promise(function(r) { setTimeout(r, 50); });
                }
                if (typeof window.loadMarkdown !== 'function') {
                    console.error('[sidekey] loadMarkdown bridge missing after 5s; blockNoteReady=', window.blockNoteReady);
                    return;
                }
                if (typeof window.__sidekeyLastLoadGen === 'number' && gen < window.__sidekeyLastLoadGen) {
                    console.log('[sidekey] skip stale-before gen=' + gen + ' last=' + window.__sidekeyLastLoadGen);
                    return;
                }
                window.__sidekeyLastLoadGen = gen;
                await window.loadMarkdown(\(encoded));
                if (gen < window.__sidekeyLastLoadGen) {
                    console.log('[sidekey] skip stale-after gen=' + gen + ' last=' + window.__sidekeyLastLoadGen);
                    return;
                }
                console.log('[sidekey] loadMarkdown ok gen=' + gen + ' chars=' + \(markdown.count));
            } catch (e) {
                console.error('[sidekey] loadMarkdown threw:', e);
            }
        })()
        """
    }
}

// MARK: - WKNavigationDelegate

extension MeetingsViewerView: WKNavigationDelegate {
    /// Navigation policy: only allow the initial bundle URL (file://) and
    /// the bundle's local assets. Anything else (an HTML link in the
    /// markdown, an injected redirect) is cancelled — the BlockNote
    /// editor is intended to be sandboxed.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased()
        if navigationAction.navigationType == .other,
           let scheme,
           scheme == "file" || scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            self?.handleWebContentProcessTermination()
        }
    }
}
