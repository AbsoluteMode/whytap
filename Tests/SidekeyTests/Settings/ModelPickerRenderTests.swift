import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Sidekey

@MainActor
final class ModelPickerRenderTests: XCTestCase {
    func testShortSearchRendersAfterScrollingAndAnEmptyQueryResult() throws {
        guard ProcessInfo.processInfo.environment["EXODIA_MODEL_PICKER_RENDER_DIR"] != nil else {
            throw XCTSkip("Set EXODIA_MODEL_PICKER_RENDER_DIR for offscreen visual proof")
        }
        let hydrogen = "google/gemini-4-hydrogen"
        let current = "google/gemini-3.8-flash"
        let ids = (0..<70).map { "aa/model-\($0)" }
            + (0..<25).map { "google/gemini-3.0-\($0)" }
            + [current, hydrogen, "qwen/qwen3.8-27b"]
            + (0..<50).map { "zz/model-\($0)" }
        let section = PickerSection(account: .openRouter, title: "OpenRouter", options: ids.map {
            PickerOption(model: $0, state: .new, isSelected: $0 == current, hint: nil)
        }, refreshFailed: false)
        let picker = ModelPicker(sections: [section], missingProviderHint: nil,
                                 onSelect: { _, _ in }, onRefresh: {}, onAddKey: {}, onClose: {})
        let size = NSSize(width: 440, height: 400)
        let host = NSHostingView(rootView: picker)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        func layout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.18))
            host.layoutSubtreeIfNeeded()
        }
        func searchField(in view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        layout()
        let field = try XCTUnwrap(searchField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        func renderedText(afterTyping query: String) throws -> String {
            editor.selectAll(nil)
            for character in query {
                editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            XCTAssertEqual(editor.string, query)
            layout()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }

        XCTAssertTrue(try renderedText(afterTyping: "hydro").contains(hydrogen))
        XCTAssertTrue(try renderedText(afterTyping: "googl").contains(current))
        let empty = try renderedText(afterTyping: "zzzzz")
        let short = try renderedText(afterTyping: "hydro")
        XCTAssertTrue(empty.contains("No matching models"), empty)
        XCTAssertTrue(short.contains(hydrogen), short)
        XCTAssertFalse(window.isVisible)
    }

    func testSearchResultsAndEmptyStatesInBothAppearances() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_MODEL_PICKER_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_MODEL_PICKER_RENDER_DIR for offscreen visual proof")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sections = [PickerSection(account: .openRouter, title: "OpenRouter", options: [
            PickerOption(model: "anthropic/claude-sonnet-5.5", state: .verified, isSelected: false, hint: nil),
            PickerOption(model: "qwen/qwen3.8-27b", state: .new, isSelected: true, hint: nil),
            PickerOption(model: "qwen/qwen3-27b:free", state: .new, isSelected: false, hint: nil),
            PickerOption(model: "qwen/qwen3.8-27b-long-context-instruct-with-a-very-long-identifier",
                         state: .notSupported(reason: "This model cannot serve this feature"),
                         isSelected: false, hint: nil),
        ], refreshFailed: true)]

        let unlisted = PickerSection(account: .server(UUID()), title: "My server", options: [], refreshFailed: false,
                                     acceptsModelName: true)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z"))
        let datedSections: [PickerSection] = [ProviderAccount.anthropic, .openAI, .openRouter].map { account in
            PickerSection(account: account, title: account.kind.displayName, options: [
                PickerOption(model: account == .openRouter
                             ? "vendor/a-very-long-model-identifier-that-wraps-over-two-lines-in-this-picker"
                             : "example-model", state: .verified, isSelected: account == .anthropic, hint: nil,
                             dateLabel: ModelStatusResolver.catalogDateLabel(date, account: account)),
            ] + (account == .anthropic ? [
                PickerOption(model: "unknown-date", state: .new, isSelected: false, hint: nil),
            ] : []), refreshFailed: false)
        }
        let speechSections: [PickerSection] = [
            PickerSection(account: .soniox, title: "Soniox", options: [
                speechOption("stt-async-v5", account: .soniox, selected: true, hint: "with speakers"),
            ], refreshFailed: false),
            PickerSection(account: .deepgram, title: "Deepgram", options: [
                speechOption("nova-3", account: .deepgram, updated: "2026-10-20"),
                speechOption("nova-3-general", account: .deepgram, updated: "2026-10-20"),
                speechOption("nova-3-medical", account: .deepgram, updated: "2026-10-06"),
                speechOption("nova-3-pharma", account: .deepgram, updated: "2026-06-05"),
            ], refreshFailed: false),
            PickerSection(account: .elevenLabs, title: "ElevenLabs", options: [
                speechOption("scribe_v2_realtime", account: .elevenLabs),
            ], refreshFailed: false),
        ]
        for dark in [false, true] {
            for state in ["all", "qwen27", "empty", "no-provider", "unlisted-server", "dates", "speech-dates", "speech-scribe"] {
                let query = state == "qwen27" ? "qwen 27" : (state == "empty" ? "missing model" : (state == "speech-scribe" ? "scribe" : ""))
                let displayed: [PickerSection]
                switch state {
                case "no-provider": displayed = []
                case "unlisted-server": displayed = [unlisted]
                case "dates": displayed = datedSections
                case "speech-dates", "speech-scribe": displayed = speechSections
                default: displayed = sections
                }
                let picker = ModelPicker(sections: displayed,
                                         missingProviderHint: "Add API key", initialQuery: query,
                                         onSelect: { _, _ in }, onRefresh: {}, onAddKey: {},
                                         onClose: {})
                let host = NSHostingView(rootView: picker.environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 440, height: 400)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                window.contentView = nil
                window.close()
            }
        }
    }

    private func speechOption(_ model: String, account: ProviderAccount, updated: String? = nil,
                              selected: Bool = false, hint: String? = nil) -> PickerOption {
        let date = updated.flatMap(ModelCatalogFetcher.deepgramVersionDate)
            ?? ModelRegistry.documentedReleaseDate(for: model, kind: account.kind)
        return PickerOption(model: model, state: .verified, isSelected: selected, hint: hint,
                            dateLabel: ModelStatusResolver.catalogDateLabel(date, account: account), catalogDate: date)
    }
}
