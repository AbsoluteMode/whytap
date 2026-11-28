import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The eye ("Hide Hover and Music") hides the drawer appearing under the
/// mouse, not panels the user explicitly asks for: Settings -> Features
/// Open/Edit, a tool's hotkey (Option N) or a whytap link.
/// WHY: .project-docs/decisions/2026-11-28-eye-hides-hover-not-explicit-panels.md
@MainActor
final class IslandEyeExplicitPanelTests: XCTestCase {
    private typealias Gate = IslandView

    func testTheGate() {
        func shown(eye: Bool, explicit: Bool = false, programmatic: Bool = false, pointer: Bool = false,
                   policy: Bool = true) -> Bool {
            Gate.hoverDrawerShown(eyeHidesHover: eye, explicitlyOpened: explicit, programmaticExpansion: programmatic,
                                  pointerOrFocusHolds: pointer, policyAllows: policy)
        }
        XCTAssertFalse(shown(eye: true, pointer: true), "Eye on: plain mouse hover shows nothing")
        XCTAssertFalse(shown(eye: true, programmatic: true), "Eye on: a glance alone shows nothing")
        XCTAssertTrue(shown(eye: true, explicit: true, programmatic: true), "Eye on: an explicit request opens it")
        XCTAssertTrue(shown(eye: true, explicit: true, pointer: true), "The pointer keeps an explicitly opened drawer")
        XCTAssertFalse(shown(eye: true, explicit: true), "Nothing holds it any more: it closes")
        XCTAssertFalse(shown(eye: true, explicit: true, programmatic: true, policy: false), "Meeting suggestion / agent still win")
        XCTAssertTrue(shown(eye: false, pointer: true), "Eye off: hover as before")
        XCTAssertTrue(shown(eye: false, programmatic: true), "Eye off: Option N as before")
    }

    private var suite = ""
    private var window: NSWindow!
    private var hosting: NSHostingView<AnyView>!
    private var state: AppState!
    private var bridge: IslandHoverHitBridge!
    private var prefs: DisplayPreferences!
    private var expansions: [Bool] = []

    override func setUp() async throws {
        suite = "IslandEyeExplicitPanelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        prefs = DisplayPreferences(defaults: defaults)
        prefs.hideIslandHoverWidgets = true
        state = AppState()
        bridge = IslandHoverHitBridge()
        bridge.dragEffects = .silent
        let store = HoverLayoutStore(defaults: defaults)
        let size = CGSize(width: 700, height: 520)
        let view = IslandView(appState: state, onHoverChange: { [unowned self] in expansions.append($0) },
                              hoverHitBridge: bridge, displayPreferences: prefs, hoverLayout: store)
            .frame(width: size.width, height: size.height, alignment: .top)
        hosting = NSHostingView(rootView: AnyView(view))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        settle(0.5)
    }

    override func tearDown() async throws {
        window.contentView = nil
        window.close()
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func settle(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            hosting.layoutSubtreeIfNeeded()
        }
    }

    /// What AppDelegate does for Settings -> Features Open/Edit, a tool's
    /// hotkey and a whytap link alike.
    private func request(_ panel: HoverInlinePanel, token: Int, glance: Bool = false) {
        state.programmaticHoverExpansion = true
        state.programmaticHoverPanelRequest = HoverPanelRequest(panel: panel, token: token, isGlance: glance)
    }

    func testEveryExplicitRequestOpensItsPanelWithTheEyeOnAndClosesNormally() throws {
        // Case is left out: opening it starts its own system interaction
        // (unlock), which no offscreen test should touch; it uses the same
        // request path.
        let panels: [HoverInlinePanel] = [.history, .vocabularyEditor, .fillerEditor, .tasks,
                                          .brightness, .notifications, .monitor]
        for (index, panel) in panels.enumerated() {
            expansions.removeAll()
            request(panel, token: index + 1)
            settle(0.4)
            XCTAssertEqual(expansions.last, true, "\(panel) opens with the eye on")
            XCTAssertTrue(bridge.dispatchEnabled, "\(panel) takes clicks")
            XCTAssertNotNil(bridge.drawerFrame(in: window), "\(panel) is on screen")
            XCTAssertTrue(prefs.hideIslandHoverWidgets, "the eye is unchanged")
            // Closing as it normally does: Escape or a click outside reach
            // the island's dismissal (`dismissHoverMenu`).
            bridge.dismissals.send()
            settle(0.4)
            XCTAssertEqual(expansions.last, false, "\(panel) closes")
            XCTAssertFalse(bridge.dispatchEnabled)
        }
    }

    func testAGlanceAndAPlainHoverSignalStayHiddenWithTheEyeOn() {
        request(.brightness, token: 100, glance: true)
        settle(0.4)
        XCTAssertNotEqual(expansions.last, true, "a brightness glance is not an explicit open")
        XCTAssertFalse(bridge.dispatchEnabled)
    }

    func testTurningTheEyeOnClosesAnExplicitlyOpenedPanel() {
        prefs.hideIslandHoverWidgets = false
        settle(0.2)
        prefs.hideIslandHoverWidgets = true
        settle(0.2)
        request(.history, token: 200)
        settle(0.4)
        XCTAssertEqual(expansions.last, true)
        prefs.hideIslandHoverWidgets = false
        settle(0.2)
        prefs.hideIslandHoverWidgets = true
        settle(0.4)
        XCTAssertEqual(expansions.last, false, "the eye turned on closes it")
    }
}
