import SwiftUI
import XCTest
@testable import Sidekey

/// Pins the idle-state visual contract: a thin adaptive ring
/// (Circle.stroke), not a filled disc. The old "filled dot" look was
/// visually heavy and didn't read as the Sidekey logo silhouette; Maxim
/// explicitly asked for a hollow ring matching the brand mark. The idle
/// surface used to live in `DotView.idleRing`; it now lives in
/// `VoiceOrbView.idleRing(palette:)` so the active→idle transition can
/// pause the same single TimelineView instance instead of swapping
/// between two views (which retained the outgoing active orb in the
/// view graph and kept its TimelineView ticking).
@MainActor
final class DotViewTests: XCTestCase {

    // MARK: - Source loading helpers (mirrors VoiceOrbViewTests pattern)

    private func loadDotViewSource() throws -> String {
        try loadSource(named: "DotView.swift")
    }

    private func loadVoiceOrbSource() throws -> String {
        try loadSource(named: "VoiceOrbView.swift")
    }

    private func loadSource(named filename: String) throws -> String {
        let candidates = candidateSourceURLs(for: filename)
        for url in candidates {
            if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        throw XCTSkip("\(filename) source not reachable from test bundle — tried: \(candidates.map(\.path).joined(separator: ", "))")
    }

    private func candidateSourceURLs(for filename: String) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        if let srcroot = env["SRCROOT"] { roots.append(URL(fileURLWithPath: srcroot)) }
        if let pkgRoot = env["PACKAGE_PATH"] { roots.append(URL(fileURLWithPath: pkgRoot)) }

        let thisFile = URL(fileURLWithPath: #filePath)
        var cursor = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
                roots.append(cursor)
                break
            }
            cursor = cursor.deletingLastPathComponent()
        }
        return roots.map { $0.appendingPathComponent("Sources/Sidekey/\(filename)") }
    }

    private func extractFunctionBody(source: String, header: String) throws -> String {
        guard let start = source.range(of: header) else {
            throw XCTSkip("Function header not found: \(header)")
        }
        guard let openBrace = source.range(of: "{", range: start.upperBound..<source.endIndex) else {
            throw XCTSkip("No opening brace after \(header)")
        }
        var depth = 1
        var idx = openBrace.upperBound
        while idx < source.endIndex && depth > 0 {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        return String(source[openBrace.upperBound..<idx])
    }

    // MARK: - Idle ring composition (hollow outline, not filled disc)
    //
    // The idle surface now lives in VoiceOrbView, but the visual contract
    // (stroked ring sized to `orbSize`, no fill on the main circle,
    // colour adapts to background) is the same one DotView used to
    // guarantee. We probe the new location.

    /// The idle composition must draw a stroked `Circle()` — a hollow
    /// ring matching the Sidekey logo silhouette. Anti-regression for
    /// the "filled puck" look Maxim explicitly rejected.
    func testIdleCompositionUsesCircleStroke() throws {
        let source = try loadVoiceOrbSource()
        let body = try extractFunctionBody(source: source, header: "private func idleRing(palette:")

        XCTAssertTrue(
            body.contains(".stroke("),
            "Idle composition must stroke the Circle to render as a hollow ring (no centre fill). Body:\n\(body)"
        )
    }

    /// The idle composition must NOT fill the main `orbSize` Circle. A
    /// halo (separate, much larger, blurred disc) is allowed — the test
    /// pins the ABSENCE of a `Circle().fill(...)` on the orb-sized
    /// circle itself.
    func testIdleCompositionDoesNotFillTheMainCircle() throws {
        let source = try loadVoiceOrbSource()
        let body = try extractFunctionBody(source: source, header: "private func idleRing(palette:")

        // Any reference to `Self.orbSize` in a `.frame(width:` line must
        // NOT be preceded by `.fill(` — that's the main orb-sized circle.
        let mainSizeNeedle = "width: Self.orbSize,"
        var search = body.startIndex
        var foundMain = false
        while let hit = body.range(of: mainSizeNeedle, range: search..<body.endIndex) {
            foundMain = true
            let backStart = body.index(hit.lowerBound, offsetBy: -200, limitedBy: body.startIndex) ?? body.startIndex
            let preceding = body[backStart..<hit.lowerBound]
            XCTAssertFalse(
                preceding.contains(".fill("),
                "Main orb-sized Circle must not be filled — render it as a stroked ring instead. Surrounding code:\n\(preceding)"
            )
            search = hit.upperBound
        }
        XCTAssertTrue(
            foundMain,
            "idleRing must include a Circle sized to Self.orbSize so the ring matches the orb footprint."
        )
    }

    /// The idle ring must adapt its colour from the background-luminance
    /// observer. After the merge into VoiceOrbView, that branching lives
    /// in `paletteFlavor(for:isDarkBackground:)` — the helper that
    /// `idleRing(palette:)` consumes via the resolved `PaletteFlavor`.
    /// The runtime invariants (white over dark, black over light) are
    /// pinned in VoiceOrbViewTests; here we just guarantee the wiring
    /// stays in place.
    func testIdleRingColorBranchesOnIsDarkBackground() {
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .idle, isDarkBackground: true),
            .adaptiveWhite,
            "Idle palette over a dark wallpaper must resolve to adaptiveWhite — the stroked ring needs to be white so it reads against the dark background."
        )
        XCTAssertEqual(
            VoiceOrbView.paletteFlavor(for: .idle, isDarkBackground: false),
            .adaptiveBlack,
            "Idle palette over a light wallpaper must resolve to adaptiveBlack — the stroked ring needs to be black so it reads against the light background."
        )
    }

    // MARK: - Active→idle CPU regression (zombie VoiceOrbView)
    //
    // The previous DotView swapped between a local idle ring and
    // VoiceOrbView via `if orbMode == .idle` with `.transition(.opacity)`.
    // SwiftUI kept the outgoing VoiceOrbView in the view graph during the
    // opacity transition with its last-known `mode` (e.g. `.agentVoice`),
    // so `paused: mode == .idle` evaluated to `false` on the zombie copy
    // and the BlobShape stack kept rendering at 60fps while invisible.
    // The fix is to render a single VoiceOrbView whose mode flips to
    // `.idle` — pause takes effect immediately.

    /// DotView body must NOT contain `if orbMode == .idle` branching
    /// that swaps between two view types — the swap is exactly what
    /// retained the outgoing active orb and kept its TimelineView
    /// ticking after the user returned to idle.
    func testDotViewBodyDoesNotSwapOnIdleMode() throws {
        let source = try loadDotViewSource()
        let body = try extractFunctionBody(source: source, header: "var body: some View")

        XCTAssertFalse(
            body.contains("orbMode == .idle"),
            "DotView body must not gate the orb on `orbMode == .idle` — branching there retains an outgoing VoiceOrbView in the view graph with its last active mode, so `paused: mode == .idle` evaluates false on the zombie copy and CPU stays at 60fps in idle. Render a single VoiceOrbView and let its internal composition switch handle the modes. Body:\n\(body)"
        )
    }

    // MARK: - Shared observer plumbing (Fix 2)

    /// The drop orb and the idle ring must read from the same
    /// `BackgroundLuminanceObserver` instance. The DotView body wires
    /// `luminance.isDarkBackground` into the `VoiceOrbView(...)` it
    /// instantiates — guaranteeing a single source of truth so the
    /// idle→drop transition cannot show two different palettes for
    /// the same wallpaper.
    func testDotViewThreadsObserverIntoVoiceOrbView() throws {
        let source = try loadDotViewSource()
        // The body block of the SwiftUI view (`var body: some View { ... }`).
        let body = try extractFunctionBody(source: source, header: "var body: some View")

        XCTAssertTrue(
            body.contains("VoiceOrbView(") && body.contains("isDarkBackground: luminance.isDarkBackground"),
            "DotView must forward `luminance.isDarkBackground` into VoiceOrbView so drop modes match the idle ring's palette exactly. Body:\n\(body)"
        )
    }
}
