import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Review images of island History with the ⌘-click hint and marked rows.
/// Offscreen, invisible, never key; synthetic rows only.
@MainActor
final class HistoryMultiPasteRenderTests: XCTestCase {
    func testOffscreenHistoryMultiPasteRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_HISTORY_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_HISTORY_RENDER_DIR for History multi-paste review images")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        func file(_ id: Int64, _ name: String) -> HistoryStripCard {
            .clipboard(.init(id: id, createdAt: Date(timeIntervalSinceNow: -Double(id) * 60),
                             payload: .fileURLs([URL(fileURLWithPath: "/Users/demo/Documents/\(name)")])))
        }
        func text(_ id: Int64, _ value: String) -> HistoryStripCard {
            .clipboard(.init(id: id, createdAt: Date(timeIntervalSinceNow: -Double(id) * 60),
                             payload: .text(value)))
        }
        let cards: [HistoryStripCard] = [
            file(1, "Invoice-November.pdf"),
            text(2, "Order #4821, delivery on Tuesday"),
            file(3, "Passport-scan.jpg"),
            file(4, "Contract-signed.pdf"),
            text(5, "https://example.com/booking/7731"),
        ]

        let states: [(String, String?, [HistoryStripCard])] = [
            ("hint", "Telegram", []),
            ("three-files", "Telegram", [cards[2], cards[0], cards[3]]),
            ("mixed", "Mail", [cards[1], cards[0], cards[3]]),
            ("no-target", nil, []),
        ]
        let width: CGFloat = 312
        let height = HistoryHoverView.requiredContentHeight + 12
        for (name, target, marked) in states {
            let view = HistoryHoverView(
                mode: .constant(.clipboard), cards: cards, targetAppName: target,
                onSelectMode: { _ in }, onCopy: { _ in }, onPreviewAnchorChange: { _, _ in },
                onPaste: { _ in }, allowsKeyboardPaste: true, initialSelection: marked
            )
            .frame(width: width, height: height, alignment: .top)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
            host.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("history-\(name).png"))
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
        }
    }
}
