import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// On macOS 14/15 the History drawer opted out of the hover backdrop, so the
/// gaps between its dark rows showed the window underneath (seen on a Mac
/// running an older macOS than the maintainer's).
// WHY: .project-docs/decisions/2026-11-21-history-backdrop-always.md
@MainActor
final class HistoryBackdropTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Policy

    func test_without_native_glass_the_drawer_keeps_the_legacy_material() {
        XCTAssertEqual(
            IslandHoverBackdropPolicy.backdrop(nativeGlassAvailable: false, reduceTransparency: false),
            .legacyMaterial
        )
    }

    func test_reduce_transparency_gets_an_opaque_card_on_every_system() {
        for native in [false, true] {
            XCTAssertEqual(
                IslandHoverBackdropPolicy.backdrop(nativeGlassAvailable: native, reduceTransparency: true),
                .opaque
            )
        }
    }

    func test_native_glass_is_used_when_available() {
        XCTAssertEqual(
            IslandHoverBackdropPolicy.backdrop(nativeGlassAvailable: true, reduceTransparency: false),
            .nativeGlass
        )
    }

    func test_the_opaque_card_is_fully_opaque_and_dark() throws {
        let color = try XCTUnwrap(NSColor(IslandHoverBackdropPolicy.opaqueFill).usingColorSpace(.sRGB))
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        XCTAssertLessThan(color.redComponent + color.greenComponent + color.blueComponent, 0.5)
    }

    func test_the_legacy_backdrop_hides_the_window_underneath_without_blur() {
        // Over a bright window the dark layer plus the depth wash leave at
        // at most ~20% of what is underneath, before any blur.
        let layer = IslandDetachedHoverPanelGlassStyle.legacyDarkLayerOpacity
        XCTAssertGreaterThanOrEqual(layer, 0.7)
        XCTAssertLessThanOrEqual(layer, 0.85)
        let throughTop = (1 - layer) * (1 - IslandDetachedHoverPanelGlassStyle.depthWashTopOpacity)
        XCTAssertLessThanOrEqual(throughTop, 0.2)
    }

    // MARK: - No panel opts out

    func test_no_hover_drawer_can_turn_its_backdrop_off() throws {
        let glass = try source("Sources/Sidekey/DynamicIsland/IslandHoverGlass.swift")
        XCTAssertFalse(glass.contains("showGlass"), "the see-through opt-out is gone")
        XCTAssertFalse(glass.contains(".background(Color.clear)"))
        let island = try source("Sources/Sidekey/DynamicIsland/IslandView.swift")
        XCTAssertFalse(island.contains("hoverPanelMode != .history"), "History gets the drawer backdrop")
        XCTAssertTrue(island.contains(".islandHoverGlassSurface()\n"))
    }

    func test_the_history_preview_uses_the_shared_backdrop_on_every_system() throws {
        let preview = try source("Sources/Sidekey/History/HistoryHoverPreview.swift")
        XCTAssertTrue(preview.contains(".islandHoverGlassSurface(cornerRadius: 11)"))
        XCTAssertFalse(preview.contains("Color.black.opacity(0.46)"))
    }

    // MARK: - Row text

    private func clip(_ text: String) -> HistoryStripCard {
        .clipboard(.init(id: 1, createdAt: Date(timeIntervalSince1970: 1), payload: .text(text)))
    }

    func test_a_copy_starting_with_a_line_break_still_shows_its_text_in_the_row() {
        XCTAssertEqual(HistoryHoverContent.rowText(for: clip("\n\nInternet Accounts,\nmore")),
                       "Internet Accounts, more")
        XCTAssertEqual(HistoryHoverContent.rowText(for: clip("\r\n  Internet Accounts,")), "Internet Accounts,")
    }

    func test_indentation_and_blank_lines_do_not_shift_the_row() {
        XCTAssertEqual(HistoryHoverContent.rowText(for: clip("    let a = 1\n\n\tlet b = 2  ")),
                       "let a = 1 let b = 2")
    }

    func test_row_text_keeps_the_entry_from_its_first_character() {
        // The row never removes visible characters: a copy that starts
        // mid-word is shown as it was copied.
        XCTAssertEqual(HistoryHoverContent.rowText(for: clip("nternet Accounts,")), "nternet Accounts,")
        XCTAssertEqual(HistoryHoverContent.rowText(for: clip(" \n ")), "")
    }

    // MARK: - Offscreen review images

    private static let cards: [HistoryStripCard] = [
        .clipboard(.init(id: 1, createdAt: Date(timeIntervalSince1970: 1),
                         payload: .text("Image"))),
        .clipboard(.init(id: 2, createdAt: Date(timeIntervalSince1970: 2),
                         payload: .text("nternet Accounts,"))),
        .clipboard(.init(id: 3, createdAt: Date(timeIntervalSince1970: 3),
                         payload: .text("Internet Accounts, iCloud, Game Center and Wallet & Apple Pay"))),
        .clipboard(.init(id: 4, createdAt: Date(timeIntervalSince1970: 4),
                         payload: .text("\nInternet Accounts, on the second line"))),
        .clipboard(.init(id: 5, createdAt: Date(timeIntervalSince1970: 5),
                         payload: .text("    Internet Accounts, after leading spaces"))),
    ]

    /// Saves PNGs of the History drawer over a busy window: the former
    /// see-through drawer, the macOS 14/15 material and Reduce transparency.
    /// Offscreen windows only; nothing is shown on screen.
    func testRenderHistoryBackdrops() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_HISTORY_BG_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_HISTORY_BG_RENDER_DIR to save offscreen review images")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 312, height: HistoryHoverView.requiredContentHeight + 8)
        // Rows as macOS 14/15 draws them (dark plates), whatever this Mac runs.
        IslandHoverGlass.drawsLegacyPathForReview = true
        defer { IslandHoverGlass.drawsLegacyPathForReview = false }
        try await renderMaterialProbe(into: directory)
        let variants: [(String, IslandHoverBackdrop?)] = [
            ("before-no-backdrop", nil),
            ("after-legacy-material", .legacyMaterial),
            ("after-reduce-transparency", .opaque),
        ]
        for (name, backdrop) in variants {
            let panel = HistoryHoverView(
                mode: .constant(.clipboard), cards: Self.cards, targetAppName: nil,
                onSelectMode: { _ in }, onCopy: { _ in },
                onPreviewAnchorChange: { _, _ in }, onPaste: { _ in },
                allowsKeyboardPaste: false
            )
            .frame(width: size.width, height: size.height, alignment: .top)
            .background {
                if let backdrop { IslandHoverBackdropView(backdrop: backdrop) }
            }
            .clipShape(RoundedRectangle(cornerRadius: IslandDropModeControl.detachedPanelCornerRadius,
                                        style: .continuous))
            let scene = ZStack { BusyWindow(); panel }
                .frame(width: size.width + 48, height: size.height + 48)
                .coordinateSpace(name: HistoryHoverView.hoverZoneSpaceName)
            let host = NSHostingView(rootView: scene)
            host.frame = NSRect(x: 0, y: 0, width: size.width + 48, height: size.height + 48)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: host.frame.width,
                                                      height: host.frame.height),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            XCTAssertFalse(window.isVisible)
            window.contentView = nil
            window.close()
        }
    }
}

extension HistoryBackdropTests {
    /// Evidence for the review images: offscreen capture of SwiftUI's
    /// material and of NSVisualEffectView (behind and within window) over the
    /// same text. Crisp text inside all three means capture draws no blur.
    fileprivate func renderMaterialProbe(into directory: URL) async throws {
        struct Effect: NSViewRepresentable {
            let mode: NSVisualEffectView.BlendingMode
            func makeNSView(context: Context) -> NSVisualEffectView {
                let view = NSVisualEffectView()
                view.material = .hudWindow
                view.blendingMode = mode
                view.state = .active
                return view
            }
            func updateNSView(_ view: NSVisualEffectView, context: Context) {}
        }
        let probe = ZStack {
            BusyWindow()
            HStack(spacing: 12) {
                Rectangle().fill(.ultraThinMaterial)
                Effect(mode: .behindWindow)
                Effect(mode: .withinWindow)
            }
            .padding(24)
        }
        .frame(width: 520, height: 260)
        let host = NSHostingView(rootView: probe)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 260),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("probe-material-offscreen.png"))
        window.contentView = nil
        window.close()
    }
}

/// Bright wallpaper with a chat-like column of dark text, like the window
/// that showed through on the reported Mac.
private struct BusyWindow: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.98, green: 0.78, blue: 0.35),
                                    Color(red: 0.42, green: 0.70, blue: 0.98)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<14, id: \.self) { index in
                    Text("Message \(index): the chat underneath stays readable here")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.12))
                }
            }
            .padding(12)
        }
    }
}
