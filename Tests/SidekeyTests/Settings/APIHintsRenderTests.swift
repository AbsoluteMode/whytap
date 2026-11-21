import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// No app launch, keys or network. Review both scroll extremes so an added
/// offer cannot silently disappear below the visible rows. The host is short
/// on purpose: the category rows must still scroll.
@MainActor
final class APIHintsRenderTests: XCTestCase {
    func testOffscreenOfferLayoutsAndScrollReachability() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_API_HINTS_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_API_HINTS_RENDER_DIR for API Hints review images")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(root.appendingPathComponent("Resources/UsefulLinkIcons"))
        defer {
            ProviderBrandIconAsset.clearCacheForTesting()
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        }
        for embedded in [false, true] {
            for dark in [false, true] {
                for width in [440.0, 560.0, 760.0] {
                    let host = NSHostingView(rootView: APIHintsView(onAddKey: {}, onClose: {}, embedded: embedded)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
                    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 300),
                                          styleMask: .borderless, backing: .buffered, defer: true)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.bounds.width, width)
                    XCTAssertEqual(host.bounds.height, 300)
                    let scroll = try XCTUnwrap(Self.scrollViews(in: host).first)
                    let document = try XCTUnwrap(scroll.documentView)
                    XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
                    let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    for bottom in [false, true] {
                        let y = bottom == document.isFlipped ? end : 0
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        host.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: image)
                        let name = "api-hints-\(embedded ? "embedded" : "sheet")-\(dark ? "dark" : "light")-\(Int(width))-\(bottom ? "bottom" : "top").png"
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name))
                        XCTAssertFalse(window.isVisible)
                        XCTAssertFalse(window.isKeyWindow)
                    }
                }
            }
        }
    }

    func testHeaderShowsNewestCheckDateAndRowsStayGrouped() {
        XCTAssertEqual(APIHintsView.displayDate("2026-10-22"), "October 22, 2026")
        XCTAssertEqual(APIHintsView.displayDate("not a date"), "not a date")
        let newest = APIHintsView.hints.map(\.checked).max()
        XCTAssertEqual(APIHintsView.lastChecked, APIHintsView.displayDate(newest ?? ""))
        // Every category has an offer, and none is hidden by an unknown category.
        for category in APIHintsView.Category.allCases {
            XCTAssertFalse(APIHintsView.hints.filter { $0.category == category }.isEmpty, category.title)
        }
        // Easiest start first: no card, then card, then paid plan.
        let order: [APIHintsView.Access] = [.noCard, .cardRequired, .paidPlan]
        for category in APIHintsView.Category.allCases {
            let ranks = APIHintsView.hints.filter { $0.category == category }.compactMap { order.firstIndex(of: $0.access) }
            XCTAssertEqual(ranks, ranks.sorted(), category.title)
        }
        XCTAssertEqual(Set(APIHintsView.hints.map(\.provider)).count, APIHintsView.hints.count)
    }

    /// README's "Free to use" cards are generated from these offers; stale cards
    /// would advertise terms the app no longer shows.
    func testReadmeFreeAPICardsMatchNoCardOffers() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        // Only up to the next heading: later sections (You may also like) have linked cards too.
        let rest = try XCTUnwrap(readme.range(of: "## Free to use").map { readme[$0.upperBound...] })
        let section = String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
        let cards = section.split(separator: "\n").filter { line in
            line.hasPrefix("<a href=") && line.contains("<picture>")
        }
        let free = APIHintsView.hints.filter { $0.access == .noCard }
        XCTAssertEqual(cards.count, free.count)
        let newest = try XCTUnwrap(free.map(\.checked).max())
        XCTAssertTrue(section.contains("Last checked \(APIHintsView.displayDate(newest))"))
        for hint in free {
            let card = try XCTUnwrap(cards.first { $0.hasPrefix("<a href=\"\(hint.url.absoluteString)\">") }, hint.provider)
            XCTAssertTrue(card.contains("alt=\"\(hint.provider): \(hint.allowance) \(hint.cadence) ("), hint.provider)
        }
    }

    /// A row without a bundled mark falls back to the generic globe, which reads as a missing logo.
    func testEveryOfferHasItsBundledMark() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        ProviderBrandIconAsset.setResourceDirectoryForTesting(root.appendingPathComponent("Resources/UsefulLinkIcons"))
        ProviderBrandIconAsset.clearCacheForTesting()
        defer {
            ProviderBrandIconAsset.clearCacheForTesting()
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        }
        for hint in APIHintsView.hints {
            let name = try XCTUnwrap(hint.assetName, hint.provider)
            XCTAssertNotNil(ProviderBrandIconAsset.image(named: name, pointSize: 17), hint.provider)
        }
        // The API keys tile draws the same Tavily mark.
        XCTAssertNotNil(ProviderBrandIconAsset.image(named: "tavily", pointSize: 28))
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
