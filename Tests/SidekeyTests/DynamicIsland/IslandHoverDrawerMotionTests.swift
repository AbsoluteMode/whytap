import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The real hover drawer (`IslandDropModeHoverPanel`) hosted offscreen in a
/// never-shown panel, inside the same frame and glass surface `IslandView`
/// gives it. Measures the main thread's CPU time while the drawer animates a
/// removal, an addition and the More section, and writes frame strips.
/// Set WHYTAP_HOVER_MOTION_DIR to run it; it never shows a window.
@MainActor
final class IslandHoverDrawerMotionTests: XCTestCase {
    private final class Harness: ObservableObject {
        @Published var panelMode: IslandHoverPanelMode = .controls
        @Published var moreExpanded = false
    }

    private struct Drawer: View {
        @ObservedObject var harness: Harness
        @ObservedObject var store: HoverLayoutStore
        let bridge: IslandHoverHitBridge
        let deps: Deps

        var body: some View {
            let height = IslandView.hoverPanelHeight(
                for: harness.panelMode, musicActive: false, toolCount: store.slots.count,
                moreTools: harness.moreExpanded ? store.unpinnedTools.count : nil
            ) - IslandDropModeControl.detachedPanelGap
            VStack(spacing: 0) {
                IslandDropModeHoverPanel(
                    panelWidth: 312, mode: .fast, selectedLanguage: nil, targetLanguage: nil,
                    meetingRecordingActive: false,
                    panelMode: $harness.panelMode, moreToolsExpanded: $harness.moreExpanded,
                    hoverHitBridge: bridge,
                    onSearchFocusChange: { _ in }, onVocabularyFocusChange: { _ in }, onSearchWillActivate: { _ in },
                    hoverStore: store, hotkeys: deps.hotkeys,
                    vocabularyViewModel: deps.vocab, fillerViewModel: deps.filler, caseViewModel: deps.caseVM,
                    onToggle: {}, onOpenSettings: {}, onOpenHotkeys: {}, onOpenHistory: { .clipboard },
                    historyCards: { _ in [] }, onSelectHistoryMode: { _ in }, onCopyHistoryCards: { _ in },
                    onHistoryPreviewAnchorChange: { _, _ in }, onPasteHistoryCards: { _ in },
                    historyPasteTargetName: { nil }, onOpenNotes: {}, onOpenHelp: {}, onQuit: {},
                    onSelectLanguage: { _ in }, onSelectOutputLanguage: { _ in }
                )
                .frame(width: 312, height: height)
                .modifier(GlassIfWanted())
                Spacer(minLength: 0)
            }
            .frame(width: 312, height: 640, alignment: .top)
            .coordinateSpace(name: IslandView.hoverZoneSpace)
            .overlay(alignment: .topLeading) {
                IslandHoverFloatingLayer(stage: bridge.stage, motion: bridge.motion)
            }
            .background(Color(white: 0.32))
            .environment(\.colorScheme, .dark)
        }
    }

    private struct GlassIfWanted: ViewModifier {
        func body(content: Content) -> some View {
            if ProcessInfo.processInfo.environment["WHYTAP_HOVER_MOTION_NO_GLASS"] != nil {
                content.background(Color(white: 0.15))
            } else {
                content.islandHoverGlassSurface()
            }
        }
    }

    private struct Deps {
        let hotkeys: HotkeyPreferences
        let vocab: IslandVocabularyViewModel
        let filler: IslandFillerViewModel
        let caseVM: CaseViewModel
    }

    private struct MemoryVault: CaseVaultStoring {
        func load(using key: SymmetricKey) throws -> CaseVaultPayload { CaseVaultPayload() }
        func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws {}
        func reset() throws {}
    }

    private struct Keys: CaseVaultKeyProviding {
        func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
    }

    private final class NoAuth: CaseAuthenticating {
        func authenticate(reason: String) async throws {}
    }

    private var suiteName = ""
    /// How the drawer's strip toggles More (`toggleMoreTools`); nil reproduces
    /// the toggle before 2026-11-27, which changed the drawer's height unanimated.
    static var toggleAnimation: Animation? {
        ProcessInfo.processInfo.environment["WHYTAP_HOVER_MOTION_UNANIMATED_TOGGLE"] != nil
            ? nil : IslandHoverHitBridge.reorderAnimation
    }

    override func tearDown() async throws {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
    }

    func testMeasureAndRenderDrawerMotion() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_HOVER_MOTION_DIR"] else {
            throw XCTSkip("Set WHYTAP_HOVER_MOTION_DIR to measure and render the drawer's motion")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        suiteName = "IslandHoverDrawerMotionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.inputLang, .notes, .meetingRecord, .hotkeys, .monitor, .vocab])
        let bridge = IslandHoverHitBridge()
        bridge.layoutStore = store
        bridge.setEnabled(true)
        let deps = Deps(
            hotkeys: HotkeyPreferences(defaults: defaults),
            vocab: IslandVocabularyViewModel(vocabulary: VocabularyCache(defaults: defaults)),
            filler: IslandFillerViewModel(store: FillerTermsStore(defaults: defaults)),
            caseVM: CaseViewModel(service: CaseVaultService(store: MemoryVault(), keyProvider: Keys()),
                                  authenticator: NoAuth())
        )
        let harness = Harness()
        let host = NSHostingView(rootView: Drawer(harness: harness, store: store, bridge: bridge, deps: deps))
        let size = NSSize(width: 312, height: 640)
        let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        pump(host, seconds: 0.6)

        var report: [String] = [try measure("idle (no change)", host: host) {}]
        let scenarios: [(String, () -> Void, () -> Void)] = [
            ("remove", { _ = bridge.unpin(.notes) }, { _ = bridge.pin(.notes) }),
            ("add", { _ = bridge.pin(.filler) }, { _ = bridge.unpin(.filler) }),
            ("more-open", { withAnimation(Self.toggleAnimation) { harness.moreExpanded = true } },
             { harness.moreExpanded = false }),
            ("add-from-more", { harness.moreExpanded = true; _ = bridge.pin(.filler) },
             { _ = bridge.unpin(.filler); harness.moreExpanded = false }),
            ("more-close", { withAnimation(Self.toggleAnimation) { harness.moreExpanded = false } },
             { harness.moreExpanded = true }),
            ("more-open (second time)", { withAnimation(Self.toggleAnimation) { harness.moreExpanded = true } },
             { harness.moreExpanded = false }),
            ("reorder (reference)", { withAnimation(IslandHoverHitBridge.reorderAnimation) {
                _ = store.placeTool(.vocab, at: 0) } }, {}),
        ]
        let original = store.slots
        for (name, change, revertChange) in scenarios {
            let revert = {
                revertChange()
                var plain = Transaction(); plain.disablesAnimations = true
                withTransaction(plain) { store.replaceEditableSlots(with: original) }
            }
            if name == "add-from-more" { harness.moreExpanded = true; pump(host, seconds: 0.5) }
            report.append(try measure(name, host: host, change: change))
            revert(); pump(host, seconds: 0.6)
            if name == "add-from-more" { harness.moreExpanded = true; pump(host, seconds: 0.5) }
            try capture(name, host: host, destination: destination, change: change)
            revert(); pump(host, seconds: 0.6)
            if name == "more-close" { harness.moreExpanded = false; pump(host, seconds: 0.5) }
            if name == "add-from-more" { harness.moreExpanded = true; pump(host, seconds: 0.5) }
        }
        try renderDragFeedback(to: destination.appendingPathComponent("drag-feedback.png"))
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: destination.appendingPathComponent("motion-report.txt"), atomically: true, encoding: .utf8)
        print(text)
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }

    private func pump(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
    }

    /// Main-thread CPU time and the longest single update while the change
    /// animates for 500 ms (no captures in this pass).
    private func measure(_ name: String, host: NSView, change: () -> Void) throws -> String {
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let start = Date()
        var longest = 0.0
        var steps = 0
        change()
        while Date().timeIntervalSince(start) < 0.5 {
            let stepStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            longest = max(longest, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - stepStart) / 1e6)
            steps += 1
        }
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6
        return String(format: "%@: main-thread CPU %.1f ms over 500 ms, longest update %.1f ms, %d updates",
                      name, cpu, longest, steps)
    }

    /// A strip of frames at fixed moments after the change.
    private func capture(_ name: String, host: NSView, destination: URL, change: () -> Void) throws {
        let moments: [Double] = [0, 0.05, 0.1, 0.15, 0.22, 0.3, 0.45]
        var frames: [NSBitmapImageRep] = []
        let start = Date()
        change()
        for moment in moments {
            while Date().timeIntervalSince(start) < moment {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 240))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            frames.append(rep)
        }
        try writeStrip(frames, to: destination.appendingPathComponent("\(name).png"))
    }

    /// The lifted tile inside the hover, outside it (letting go removes it)
    /// and puffing away after the release.
    private func renderDragFeedback(to url: URL) throws {
        let motion = IslandHoverReorderMotion()
        func tile(lifted: Bool, outside: Bool, vanished: Bool) -> some View {
            let control = IslandHoverPanelControl(title: "Notes", systemImage: "note.text", pdfResource: nil,
                                                  label: nil, circleSize: IslandHoverPanelControl.iconSize,
                                                  accessibilityLabel: "Notes", action: {})
            return IslandHoverFloatingTile(motion: outside ? Self.outsideMotion : motion, origin: CGPoint(x: 70, y: 50),
                                           settle: nil, lifted: lifted, vanished: vanished) { control }
                .frame(width: 140, height: 100)
        }
        let view = HStack(spacing: 0) {
            tile(lifted: true, outside: false, vanished: false)
            tile(lifted: true, outside: true, vanished: false)
            tile(lifted: true, outside: false, vanished: true)
        }
        .background(Color(white: 0.2))
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 420, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        defer { window.contentView = nil; window.close() }
        pump(host, seconds: 0.5)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private static let outsideMotion: IslandHoverReorderMotion = {
        let motion = IslandHoverReorderMotion()
        motion.setOutside(true)
        return motion
    }()

    private func writeStrip(_ frames: [NSBitmapImageRep], to url: URL) throws {
        guard let first = frames.first else { return }
        let width = first.pixelsWide, height = first.pixelsHigh * 3 / 4
        let strip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * frames.count, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width * frames.count, height: height).fill()
        for (index, frame) in frames.enumerated() {
            // The drawer is at the top of the host (bitmap y grows upward).
            let source = NSRect(x: 0, y: 0, width: width, height: height)
            frame.draw(in: NSRect(x: index * width, y: 0, width: width, height: height), from: source,
                       operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(strip.representation(using: .png, properties: [:])).write(to: url)
    }
}
