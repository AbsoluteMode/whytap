import XCTest
import WebKit
@testable import Sidekey

/// Stage 8a — guards the BlockNote bundle that the future Meetings viewer
/// (Stage 8b) hosts inside a WKWebView. The bundle is built by
/// `scripts/build-blocknote.sh` (npm + vite) and committed under
/// `Resources/blocknote/`. Two invariants matter for downstream stages:
///
/// 1. The expected files (`index.html` + at least one asset under `assets/`)
///    are present on disk. `build-dmg.sh` / `dev-run.sh` literally `cp -R`
///    this directory into `<App>.app/Contents/Resources/blocknote/`, so a
///    missing file here means the WKWebView in 8b would fail to load.
///
/// 2. A throwaway WKWebView can navigate to `index.html` over `file://`
///    without a load error — i.e. the HTML parses, asset paths resolve, the
///    Content-Security-Policy header doesn't reject the document itself,
///    and the `<script type="module">` entry tag is present in the DOM.
///    Full BlockNote boot (window.blockNoteReady) is verified manually as
///    part of the Stage 8b user gate; in this test environment ES-module
///    script execution under `file://` is constrained by WebKit's CORS
///    rules in a way only the Stage 8b production host code can address
///    (custom WKURLSchemeHandler / loadHTMLString with baseURL / etc.), so
///    asserting `window.blockNoteReady` here would be a false-positive
///    failure of the bundle, not a real defect.
///
/// Resource discovery quirk: this package's executable target does NOT
/// declare `Resources/` as SPM resources (see `Package.swift`; mirrored by
/// the comment in `OrbActionsViewTests.testIconPDFsExistInProjectResources`).
/// The production .app gets the bundle via explicit `cp -R` in the build
/// scripts; `swift test` doesn't run those scripts, so `Bundle.main` /
/// `Bundle.module` would not see the files. Both tests walk up from
/// `#filePath` until they find a sibling `Resources/blocknote/` directory
/// on disk; that pattern catches the "bundle missing from source tree"
/// regression regardless of how SPM is wired.
@MainActor
final class BlockNoteBundleTests: XCTestCase {

    // MARK: - Source-tree bundle discovery

    /// Locate `Resources/blocknote/` by walking up from this test file.
    /// Returns the directory URL or fails the test with a clear message.
    private func locateBundleDirectory(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL? {
        let thisFile = URL(fileURLWithPath: "\(file)")
        var cursor = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = cursor
                .appendingPathComponent("Resources")
                .appendingPathComponent("blocknote")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            cursor = cursor.deletingLastPathComponent()
        }
        XCTFail(
            "Resources/blocknote/ directory missing in source tree. "
            + "Run: bash scripts/build-blocknote.sh",
            file: file, line: line
        )
        return nil
    }

    // MARK: - Test 1: files are on disk

    func test_bundle_files_present() throws {
        guard let bundleDir = locateBundleDirectory() else { return }

        let indexHTML = bundleDir.appendingPathComponent("index.html")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexHTML.path),
            "Resources/blocknote/index.html must exist after running scripts/build-blocknote.sh"
        )

        let assetsDir = bundleDir.appendingPathComponent("assets")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: assetsDir.path),
            "Resources/blocknote/assets/ directory must exist after scripts/build-blocknote.sh"
        )

        let assetFiles = try FileManager.default.contentsOfDirectory(
            at: assetsDir,
            includingPropertiesForKeys: nil
        )
        XCTAssertGreaterThan(
            assetFiles.count, 0,
            "Resources/blocknote/assets/ must contain at least one bundle file"
            + " (expected JS at minimum; CSS is inlined under the IIFE format used here)."
        )

        // Sanity-check that the HTML the WKWebView in Stage 8b will load
        // actually points at a script tag inside `assets/`. If a future
        // vite config change accidentally drops the entry tag, this test
        // catches it before the production WKWebView host swallows the
        // failure silently.
        let html = try String(contentsOf: indexHTML, encoding: .utf8)
        XCTAssertTrue(
            html.contains("./assets/"),
            "Resources/blocknote/index.html must reference at least one ./assets/* file. "
            + "If the build started inlining everything, update this test and the WKWebView host."
        )
        XCTAssertTrue(
            html.contains("<script"),
            "Resources/blocknote/index.html must contain a <script> tag for the BlockNote bundle."
        )
        // No CSP meta-tag assertion: `scripts/build-blocknote.sh` strips it
        // as a post-processing step. WebKit treats every `file://` URL as
        // the null origin, so a Vite-scaffolded `default-src 'self'`
        // policy matches nothing and blocks the very script the page
        // needs. The bundle is 100% trusted, locally-shipped code, so we
        // drop CSP rather than try to express a self-compatible policy
        // under file://. If a future change moves the bundle behind a
        // custom URL scheme handler, re-add CSP (`default-src sidekey-app:`)
        // here and in the build script's post-processor.
    }

    func test_source_styles_shrink_note_headings() throws {
        guard let bundleDir = locateBundleDirectory() else { return }
        let root = bundleDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainSourceURL = root
            .appendingPathComponent("scripts")
            .appendingPathComponent("blocknote-src")
            .appendingPathComponent("src")
            .appendingPathComponent("main.tsx")
        let cssURL = root
            .appendingPathComponent("scripts")
            .appendingPathComponent("blocknote-src")
            .appendingPathComponent("src")
            .appendingPathComponent("sidekey.css")

        let mainSource = try String(contentsOf: mainSourceURL, encoding: .utf8)
        XCTAssertTrue(mainSource.contains("import \"./sidekey.css\";"))

        let css = try String(contentsOf: cssURL, encoding: .utf8)
        XCTAssertTrue(css.contains("data-content-type=\"heading\""))
        XCTAssertTrue(css.contains("data-level=\"1\""))
        XCTAssertTrue(css.contains("font-size: 26px"))
        XCTAssertTrue(css.contains("data-level=\"2\""))
        XCTAssertTrue(css.contains("font-size: 18px"))
        XCTAssertTrue(css.contains("data-level=\"3\""))
        XCTAssertTrue(css.contains("font-size: 15.5px"))
        XCTAssertTrue(css.contains("font-size: inherit"))
    }

    func test_built_bundle_contains_sidekey_heading_overrides() throws {
        guard let bundleDir = locateBundleDirectory() else { return }
        let assetsDir = bundleDir.appendingPathComponent("assets")
        let assetFiles = try FileManager.default.contentsOfDirectory(
            at: assetsDir,
            includingPropertiesForKeys: nil
        )

        let combinedAssets = try assetFiles
            .filter { ["js", "css"].contains($0.pathExtension) }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(combinedAssets.contains("sidekey-note-heading-overrides"))
        XCTAssertTrue(combinedAssets.contains("font-size:26px"))
        XCTAssertTrue(combinedAssets.contains("font-size:18px"))
        XCTAssertTrue(combinedAssets.contains("font-size:15.5px"))
        XCTAssertTrue(combinedAssets.contains("font-size:inherit"))
    }

    // MARK: - Test 2: WKWebView accepts the bundle URL

    func test_bundle_loads_in_throwaway_webview() async throws {
        guard let bundleDir = locateBundleDirectory() else { return }
        let indexURL = bundleDir.appendingPathComponent("index.html")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexURL.path),
            "Resources/blocknote/index.html must exist for the WKWebView load test"
        )

        // We attach the WebView to an offscreen window because WebKit's
        // module-script loader stays largely dormant when the view isn't
        // part of a window hierarchy — without it, even basic JS often
        // sits queued in headless tests and we'd not observe whether the
        // navigation actually finished.
        let probe = BlockNoteWebViewProbe()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.navigationDelegate = probe
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.contentView?.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadFileURL(indexURL, allowingReadAccessTo: bundleDir)

        // Poll up to ~10s for navigation completion. We are intentionally
        // checking only that the navigation finished (no `didFail`); the
        // full BlockNote boot is left to Stage 8b's user gate for the
        // reasons documented at the top of this file.
        let deadlineNs: UInt64 = 10_000_000_000
        let stepNs: UInt64 = 200_000_000
        var elapsedNs: UInt64 = 0
        while elapsedNs < deadlineNs, probe.navigationStatus == "none" {
            try await Task.sleep(nanoseconds: stepNs)
            elapsedNs += stepNs
        }

        XCTAssertEqual(
            probe.navigationStatus, "didFinish",
            "Throwaway WKWebView must finish loading Resources/blocknote/index.html "
            + "within 10s without a `didFail` / `didFailProvisional`. "
            + "Got: \(probe.navigationStatus)."
        )

        // After the navigation finishes, the document should have a non-zero
        // number of script tags — a 0 here would mean vite produced an HTML
        // shell with no entry script, which the production WKWebView host
        // would silently render as a blank page.
        let scriptCount = (try? await webView.evaluateJavaScript(
            "document.scripts.length"
        ) as? Int) ?? -1
        XCTAssertGreaterThan(
            scriptCount, 0,
            "Loaded Resources/blocknote/index.html must contain at least one <script> tag "
            + "after navigation completes; got \(scriptCount)."
        )
    }

    // MARK: - Test 3: bundle posts editorReady to webkit.messageHandlers

    /// Guards the pull-model bridge end of the BlockNote bundle. The
    /// Swift viewer waits for the bundle to post `editorReady` via
    /// `window.webkit.messageHandlers.editorReady.postMessage(...)`
    /// before it pushes any markdown. If a future refactor of
    /// `scripts/blocknote-src/src/main.tsx` accidentally deletes that
    /// line, the production app regresses to the "first-open empty
    /// editor" bug. This test catches that regression in CI: load the
    /// real bundle into a throwaway WKWebView with a stub
    /// `WKScriptMessageHandler` registered for `editorReady` and wait
    /// for it to be invoked. The expectation is fulfilled inside
    /// React's `useEffect`, so reaching it proves React mounted and
    /// the bridge surface is wired correctly.
    func test_bundle_posts_editorReady_message() async throws {
        guard let bundleDir = locateBundleDirectory() else { return }
        let indexURL = bundleDir.appendingPathComponent("index.html")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexURL.path),
            "Resources/blocknote/index.html must exist for the editorReady test"
        )

        let expectation = expectation(description: "bundle posts editorReady")
        let handler = EditorReadyMessageHandler(expectation: expectation)
        let config = WKWebViewConfiguration()
        config.userContentController.add(handler, name: "editorReady")

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: config
        )
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.contentView?.addSubview(webView)
        defer {
            webView.removeFromSuperview()
            // Drop the handler so the WKUserContentController doesn't
            // retain it across test invocations (and so a second test
            // can register a fresh handler under the same name).
            config.userContentController.removeScriptMessageHandler(forName: "editorReady")
        }

        webView.loadFileURL(indexURL, allowingReadAccessTo: bundleDir)

        await fulfillment(of: [expectation], timeout: 10)
    }
}

// MARK: - editorReady message handler

/// Fulfills the supplied XCTestExpectation the first time the bundle
/// posts an `editorReady` message. Subsequent posts are ignored — React
/// strict-mode double-mount fires `useEffect` twice in dev builds, and
/// XCTestExpectation crashes the test if it is over-fulfilled.
private final class EditorReadyMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    private let expectation: XCTestExpectation
    private let lock = NSLock()
    private var fulfilled = false

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        lock.lock(); defer { lock.unlock() }
        guard !fulfilled, message.name == "editorReady" else { return }
        fulfilled = true
        expectation.fulfill()
    }
}

// MARK: - Diagnostic probe

/// Captures WKWebView navigation events so a failing
/// `test_bundle_loads_in_throwaway_webview` reports the actual failure
/// reason instead of a generic 10s timeout.
@MainActor
private final class BlockNoteWebViewProbe: NSObject, WKNavigationDelegate {
    var navigationStatus: String = "none"

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationStatus = "didFinish"
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        let msg = "didFail: \(error.localizedDescription)"
        Task { @MainActor in
            self.navigationStatus = msg
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let msg = "didFailProvisional: \(error.localizedDescription)"
        Task { @MainActor in
            self.navigationStatus = msg
        }
    }
}
