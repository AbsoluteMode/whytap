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
