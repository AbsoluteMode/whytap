import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The Harness row's disclosure (the whole 54 pt row) and Check again answer
/// hover, press and keyboard focus, and show none of it when disabled. Draws
/// the interaction surface those controls use, at their own geometry, in
/// light and dark, offscreen.
@MainActor
final class HarnessCardInteractionTests: XCTestCase {
    private enum State: CaseIterable { case rest, hover, pressed, focus, disabledHover }

    private func pixels(width: CGFloat, height: CGFloat, highlight: Color, radius: CGFloat,
                        state: State, dark: Bool) throws -> Data {
        let surface = MacButtonInteractionSurface(
            background: .clear, highlight: highlight,
            hovered: state == .hover || state == .disabledHover, pressed: state == .pressed,
            focused: state == .focus, enabled: state != .disabledHover, cornerRadius: radius)
            .frame(width: width, height: height)
            .padding(4)
            .background(MacSettingsTheme.bgContent)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: surface)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width + 8, height: height + 8)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["EXODIA_APIMODELS_RENDER_DIR"] {
            let name = "harness-\(Int(width))-\(state)-\(dark ? "dark" : "light").png"
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testDisclosureAndCheckAgainShowHoverPressAndFocusButNothingWhenDisabled() throws {
        let controls: [(CGFloat, CGFloat, Color, CGFloat)] = [
            (420, HarnessModelsCard.headerHeight, MacSettingsTheme.text, HarnessModelsCard.headerCornerRadius),
            (80, 18, MacSettingsTheme.accent, 5),
        ]
        for dark in [false, true] {
            for (width, height, highlight, radius) in controls {
                var images: [State: Data] = [:]
                for state in State.allCases {
                    images[state] = try pixels(width: width, height: height, highlight: highlight,
                                               radius: radius, state: state, dark: dark)
                }
                let rest = try XCTUnwrap(images[.rest])
                for state in [State.hover, .pressed, .focus] {
                    XCTAssertNotEqual(images[state], rest, "\(state) is visible (\(Int(width)) pt, dark \(dark))")
                }
                XCTAssertNotEqual(images[.hover], images[.pressed], "press differs from hover")
                XCTAssertEqual(images[.disabledHover], rest, "disabled shows no hover")
            }
        }
    }
}
