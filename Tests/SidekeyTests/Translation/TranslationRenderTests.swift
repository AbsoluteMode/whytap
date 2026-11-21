import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class TranslationRenderTests: XCTestCase {
    func testOffscreenTranslationStates() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_TRANSLATION_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTap translation render directory for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = TextTranslationModel(makeService: { TranslationPreviewService() })
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let subtitles = LiveSubtitleModel(makeAudio: { audio }, open: { _ in upstream }, makeService: { FixtureTranslator() })
        let presentation = TranslationWindowController.Presentation()
        let view = TranslationView(text: text, subtitles: subtitles, presentation: presentation, openSettings: { _ in })
            .environment(\.colorScheme, .dark)
        let suite = "translation-native-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranslationWindowController(textModel: text, subtitleModel: subtitles, defaults: defaults,
                                                      openSettings: { _ in }, activityChanged: { _ in })
        defer { controller.window.close() }
        // Include the real panel's frame view, so an empty native title bar cannot
        // hide outside the SwiftUI-only fixture as it did in the previous review.
        let nativeFrame = try XCTUnwrap(controller.window.contentView?.superview)
        nativeFrame.layoutSubtreeIfNeeded()
        let nativeBitmap = try XCTUnwrap(nativeFrame.bitmapImageRepForCachingDisplay(in: nativeFrame.bounds))
        nativeFrame.cacheDisplay(in: nativeFrame.bounds, to: nativeBitmap)
        try XCTUnwrap(nativeBitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("text-native-panel-empty.png"))
        XCTAssertFalse(controller.window.isVisible)
        XCTAssertFalse(controller.window.styleMask.contains(.titled))
        try render(view, size: NSSize(width: 560, height: 140), to: directory.appendingPathComponent("text-empty.png"))
        try render(TranslationView(text: text, subtitles: subtitles, presentation: presentation, openSettings: { _ in }, embedded: true)
            .padding(16).background(Color(white: 0.13)), size: NSSize(width: 320, height: 160),
            to: directory.appendingPathComponent("toolbox-text-empty.png"))
        text.input = "что нового?"
        await text.translate()?.value
        try render(view, size: NSSize(width: 560, height: 140), to: directory.appendingPathComponent("text-result.png"))
        try render(view, size: NSSize(width: 360, height: 120), to: directory.appendingPathComponent("text-minimum.png"))
        text.input = String(repeating: "Очень длинная фраза с английскими words и числами 123. ", count: 12)
        await text.translate()?.value
        try render(view, size: NSSize(width: 360, height: 180), to: directory.appendingPathComponent("text-long.png"))
        text.input = "что нового?"
        await text.translate()?.value
        try renderWorkspace(text: text, subtitles: subtitles, presentation: presentation, directory: directory)
        try render(view, size: NSSize(width: 360, height: 150), to: directory.appendingPathComponent("text-narrow.png"))
        try render(TranslationView(text: text, subtitles: subtitles, presentation: presentation, openSettings: { _ in }, embedded: true)
            .padding(16).background(Color(white: 0.13)), size: NSSize(width: 320, height: 160),
            to: directory.appendingPathComponent("toolbox-text-result.png"))
        presentation.mode = .subtitles
        try render(view, size: NSSize(width: 620, height: 400), to: directory.appendingPathComponent("subtitles-empty.png"))
        try render(TranslationView(text: text, subtitles: subtitles, presentation: presentation, openSettings: { _ in }, embedded: true)
            .padding(16).background(Color(white: 0.13)), size: NSSize(width: 320, height: 330),
            to: directory.appendingPathComponent("toolbox-subtitles.png"))
        let task = subtitles.start()
        for _ in 0..<100 where subtitles.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }
        try render(TranslationView(text: text, subtitles: subtitles, presentation: presentation, openSettings: { _ in }, embedded: true)
            .padding(16).background(Color(white: 0.13)), size: NSSize(width: 320, height: 330),
            to: directory.appendingPathComponent("toolbox-subtitles-listening.png"))
        upstream.pair.continuation.yield(.final("Let’s go through the changes together. Everything is ready for the next release."))
        for _ in 0..<100 where subtitles.lines.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        subtitles.stop()
        await task?.value
        try render(view, size: NSSize(width: 620, height: 400), to: directory.appendingPathComponent("subtitles-result.png"))
        try render(view, size: NSSize(width: 480, height: 340), to: directory.appendingPathComponent("subtitles-narrow.png"))
        let failed = TextTranslationModel(makeService: { throw OpenRouterLLMError.notConfigured })
        failed.input = "hello"
        await failed.translate()?.value
        presentation.mode = .text
        try render(TranslationView(text: failed, subtitles: subtitles, presentation: presentation, openSettings: { _ in }, embedded: true)
            .padding(16).background(Color(white: 0.13)), size: NSSize(width: 320, height: 160),
            to: directory.appendingPathComponent("toolbox-text-setup.png"))
        try render(TranslationView(text: failed, subtitles: subtitles, presentation: presentation, openSettings: { _ in })
            .environment(\.colorScheme, .dark), size: NSSize(width: 360, height: 150),
            to: directory.appendingPathComponent("text-setup.png"))
    }

    private func renderWorkspace(text: TextTranslationModel, subtitles: LiveSubtitleModel,
                                 presentation: TranslationWindowController.Presentation, directory: URL) throws {
        let suite = "toolbox-workspace-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: HoverTool.allCases.filter { $0 != .settings })
        let workspace = ToolboxWorkspace {
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR HOVER").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                ToolboxHoverEditor(hoverStore: store, reduceMotion: true) { item in
                    Group {
                        switch item {
                        case .tool(let tool):
                            let info = HoverToolRegistry.info(for: tool)
                            ToolboxTileView(title: info.title, sfSymbol: info.sfSymbol,
                                            isSelected: false, isLocked: tool == .settings,
                                            isAdded: false, onTap: {})
                        case .add: ToolboxAddTile()
                        }
                    }
                }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                Text("Drag tools to Add, or click Add to choose. Drag saved tools to reorder.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        } catalog: {
            VStack(alignment: .leading, spacing: 10) {
                Text("TOOLBOX").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 90))], spacing: 12) {
                        ForEach(HoverTool.allCases.filter { $0 != .settings }, id: \.self) { tool in
                            let info = HoverToolRegistry.info(for: tool)
                            ToolboxTileView(title: info.title, sfSymbol: info.sfSymbol,
                                            isSelected: tool == .translate, isLocked: false,
                                            isAdded: true, onTap: {})
                        }
                    }
                }.padding(16).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            }
        } tool: {
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTION").font(.caption).foregroundStyle(.secondary)
                ToolboxToolViewport {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Translate", systemImage: "character.bubble").font(.headline)
                        Divider()
                        TranslationView(text: text, subtitles: subtitles, presentation: presentation,
                                        openSettings: { _ in }, embedded: true)
                    }
                }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .background(Color(white: 0.12)).environment(\.colorScheme, .dark)
        try render(workspace, size: NSSize(width: 820, height: 600), to: directory.appendingPathComponent("toolbox-workspace.png"))
        try render(workspace, size: NSSize(width: 740, height: 500), to: directory.appendingPathComponent("toolbox-workspace-minimum.png"))
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}


private struct TranslationPreviewService: TextTranslating {
    func translate(_ text: String, target: TranslationTarget) async throws -> String {
        text == "что нового?" ? "What’s new?" : "Translation: " + text
    }
}

/// Fixed EN -> RU answers for the phrase-pair renders; a phrase in `holds`
/// never answers, so its pair shows the pending mark.
private struct PairPreviewService: TextTranslating {
    static let answers = [
        "Welcome back everyone.": "С возвращением, друзья.",
        "Today we have a special guest,": "Сегодня у нас особый гость,",
        "who has spent ten years building speech systems.": "который десять лет создаёт системы распознавания речи.",
        "Before we start, let me explain": "Прежде чем начать, позвольте объяснить,",
        "how a neural network is structured.": "как устроена нейронная сеть.",
        SubtitlePairRenderTests.longPhrase:
            "И самое главное: каждый слой передаёт свои числа следующему, и тот постепенно превращает сырой звук в слова, которые мы можем прочитать.",
    ]
    var holds: Set<String> = []
    func translate(_ text: String, target: TranslationTarget) async throws -> String {
        if holds.contains(text) { try await Task.sleep(for: .seconds(3600)) }
        return Self.answers[text] ?? text
    }
}

@MainActor
final class SubtitlePairRenderTests: XCTestCase {
    /// One sentence longer than the segmenter's length cut: it stays whole.
    nonisolated static let longPhrase =
        "And the most important part is that every layer passes its numbers to the next one, which slowly turns raw sound into words we can read."
    private static let script = ["Welcome back everyone.", "Today we have a special guest,",
                                 "who has spent ten years building speech systems.", "Before we start, let me explain",
                                 "how a neural network is structured."]

    /// Offscreen @2x renders of the subtitle overlay with phrase pairs over a
    /// dark video-like frame. Nothing is put on screen.
    func testOffscreenSubtitlePairs() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_TRANSLATION_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_TRANSLATION_RENDER_DIR for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let all = try await session(phrases: Self.script, holds: [], live: nil)
        try renderOverlay(all, name: "subtitles-pairs.png")
        let live = try await session(phrases: Self.script,
                                     holds: ["how a neural network is structured."],
                                     live: "Every layer takes the numbers")
        try renderOverlay(live, name: "subtitles-pairs-live.png")
        try renderToolbox(live, name: "toolbox-subtitles-pairs.png")
        // Chunk-boundary marks for the user to choose from.
        // A long sentence wraps only at the box's right edge.
        let long = try await session(phrases: Self.script + [Self.longPhrase], holds: [], live: nil)
        let short = try await session(phrases: Array(Self.script.prefix(2)), holds: [], live: nil)
        for marker in SubtitlePairMarker.allCases {
            try renderOverlay(all, name: "markers/subtitles-pairs-\(marker.rawValue).png", marker: marker)
            try renderOverlay(long, name: "markers/subtitles-long-\(marker.rawValue).png", marker: marker)
        }
        try renderOverlay(short, name: "markers/subtitles-short-none.png")
        await long.model.cancel().value
        await short.model.cancel().value
        // Stopped: the language row and Start return above the newest pairs.
        all.model.stop()
        for _ in 0..<400 where all.model.phase != .idle { try await Task.sleep(for: .milliseconds(5)) }
        try renderOverlay(all, name: "subtitles-pairs-stopped.png")
        await all.model.cancel().value
        await live.model.cancel().value
    }

    private struct Session { let model: LiveSubtitleModel; let upstream: FixtureSubtitleUpstream }

    private func session(phrases: [String], holds: Set<String>, live: String?) async throws -> Session {
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        upstream.finalsJoin = .wordBoundary
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { audio }, open: { _ in upstream },
                                      makeService: { PairPreviewService(holds: holds) })
        model.sourceCode = "en"
        model.targetCode = "ru"
        model.start()
        for _ in 0..<200 where model.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }
        for phrase in phrases {
            upstream.pair.continuation.yield(.final(phrase))
            for _ in 0..<200 where model.lines.last?.source != phrase { try await Task.sleep(for: .milliseconds(5)) }
        }
        for _ in 0..<200 where model.lines.contains(where: { !$0.isSettled && !holds.contains($0.source) }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        if let live {
            upstream.pair.continuation.yield(.partial(live))
            for _ in 0..<200 where model.live != live { try await Task.sleep(for: .milliseconds(5)) }
        }
        return Session(model: model, upstream: upstream)
    }

    private func view(_ session: Session, embedded: Bool) -> TranslationView {
        let presentation = TranslationWindowController.Presentation()
        presentation.mode = .subtitles
        return TranslationView(text: TextTranslationModel(makeService: { FixtureTranslator() }), subtitles: session.model,
                               presentation: presentation, openSettings: { _ in }, embedded: embedded)
    }

    /// The overlay panel is 760 x 190 pt; it floats over whatever plays.
    private func renderOverlay(_ session: Session, name: String, marker: SubtitlePairMarker = .none) throws {
        let frame = ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.20, green: 0.16, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.35, green: 0.42, blue: 0.55).opacity(0.45)).frame(width: 260).blur(radius: 50)
                .offset(x: -220, y: -40)
            Circle().fill(Color(red: 0.55, green: 0.40, blue: 0.32).opacity(0.35)).frame(width: 200).blur(radius: 50)
                .offset(x: 260, y: 20)
            VStack {
                Spacer()
                view(session, embedded: false).frame(width: 760, height: 190)
                    .environment(\.subtitlePairMarker, marker)
            }
        }
        .frame(width: 860, height: 300)
        .environment(\.colorScheme, .dark)
        try write(frame, to: directoryURL().appendingPathComponent(name))
    }

    private func renderToolbox(_ session: Session, name: String) throws {
        let pane = view(session, embedded: true)
            .padding(16)
            .frame(width: 360, height: 300, alignment: .topLeading)
            .background(Color(white: 0.13))
            .environment(\.colorScheme, .dark)
        try write(pane, to: directoryURL().appendingPathComponent(name))
    }

    private func directoryURL() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["WHYTAP_TRANSLATION_RENDER_DIR"] ?? NSTemporaryDirectory())
    }

    private func write<V: View>(_ content: V, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
