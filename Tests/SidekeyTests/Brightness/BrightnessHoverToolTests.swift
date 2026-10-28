import AppKit
import Combine
import CoreGraphics
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class BrightnessHoverToolTests: XCTestCase {
    // MARK: Catalog

    func testBrightnessIsAnInlinePanelOfferedOnlyFromTheCatalog() {
        let info = HoverToolRegistry.info(for: .brightness)
        XCTAssertEqual(info.title, "Display")
        XCTAssertEqual(info.kind, .inlinePanel)
        XCTAssertEqual(HoverSlotRouter.effect(for: .brightness), .openPanel(.brightness))
        XCTAssertTrue(HoverSlotRouter.effect(for: .brightness).requiresExpansion)
        XCTAssertFalse(HoverLayoutStore.defaultSlots.contains(.brightness),
                       "Existing layouts do not change; the user adds Brightness from Toolbox or search.")
    }

    func testSearchFindsBrightnessByItsOwnWordsInBothLanguages() {
        for query in ["brightness", "display", "яркость", "vivid", "xdr"] {
            XCTAssertEqual(IslandHoverToolSearch.results(for: query).first, .brightness, query)
        }
    }

    func testCapsuleTitleFitsOneLineOfTheNarrowestCapsule() {
        // 310 pt island: the text column is the capsule minus 6 pt padding on both sides,
        // the icon disk and 5 pt spacing. A longer single word breaks mid-word ("Brightne" / "ss").
        let column = IslandHoverControlsLayout.tileWidth(panelWidth: 310) - 12 - IslandHoverPanelControl.iconSize - 5
        let title = HoverToolRegistry.info(for: .brightness).title
        let width = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]).size().width
        XCTAssertLessThanOrEqual(width, column, title)
    }

    func testCapsuleStatusShowsTheLevelOrExtra() {
        func status(_ brightness: HoverBrightnessStatus?) -> String? {
            HoverToolPresentation.resolve(tool: .brightness, mode: .smart, inputLanguage: nil, outputLanguage: nil,
                                          meetingRecordingActive: false, brightness: brightness).status
        }
        XCTAssertEqual(status(.level(0.42)), "42%")
        XCTAssertEqual(status(.level(1.7)), "100%")
        XCTAssertEqual(status(.level(.nan)), "0%")
        XCTAssertEqual(status(.extra), "Extra")
        XCTAssertNil(status(nil), "An unreadable display shows no invented level.")
    }

    // MARK: Island

    func testStripBandIsShortWithAndWithoutMusic() {
        for count in [1, 6, 13] {
            XCTAssertEqual(IslandView.hoverPanelHeight(for: .brightness, musicActive: false, toolCount: count), 76)
            XCTAssertEqual(IslandView.hoverPanelHeight(for: .brightness, musicActive: true, toolCount: count), 126)
        }
        XCTAssertEqual(IslandDropModeControl.detachedPanelGap + IslandBrightnessStrip.contentHeight, 76)
    }

    func testHeldZoneKeepsTheTallerHeightUntilReleased() {
        XCTAssertEqual(IslandView.heldHoverPanelHeight(76, hold: 243), 243)
        XCTAssertEqual(IslandView.heldHoverPanelHeight(76, hold: nil), 76)
        XCTAssertEqual(IslandView.heldHoverPanelHeight(243, hold: 76), 243)
    }

    func testHeldZoneIsTransparentSpaceReleasedOnReachingTheStrip() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Sidekey/DynamicIsland/IslandView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains(".frame(width: compactWidth, height: activeHoverPanelHeight, alignment: .top)"),
                      "The drawer stays top-aligned; the held height extends below it.")
        let release = try XCTUnwrap(source.range(of: ".onContinuousHover { phase in"))
        let releaseEnd = try XCTUnwrap(source.range(
            of: ".frame(width: compactWidth, height: activeHoverPanelHeight, alignment: .top)",
            range: release.upperBound..<source.endIndex
        ))
        let releaseBody = source[release.upperBound..<releaseEnd.lowerBound]
        XCTAssertTrue(releaseBody.contains("hoverPanelHeightHold = nil"),
                      "Reaching the visible strip releases the held zone.")
        XCTAssertTrue(releaseBody.contains("releasesHeldHoverZone(pointerY: location.y"),
                      "Only a pointer over the drawer's final frame releases it.")
    }

    func testHeldZoneIsReleasedOnlyOverTheDrawersFinalFrame() {
        // While the drawer shrinks to the strip, its animated frame still covers the held
        // zone; releasing there closed the drawer under a pointer moving up from the third row.
        let strip = IslandBrightnessStrip.contentHeight
        XCTAssertTrue(IslandView.releasesHeldHoverZone(pointerY: 0, drawerHeight: strip))
        XCTAssertTrue(IslandView.releasesHeldHoverZone(pointerY: strip, drawerHeight: strip))
        XCTAssertFalse(IslandView.releasesHeldHoverZone(pointerY: strip + 1, drawerHeight: strip))
        XCTAssertFalse(IslandView.releasesHeldHoverZone(pointerY: 194, drawerHeight: strip),
                       "The third row's pointer is still in the held zone.")
    }

    func testStripTakesKeyStatusForItsControls() {
        XCTAssertTrue(IslandHoverPanelMode.brightness.needsKeyboardFocus)
    }

    // MARK: Strip

    func testSliderMapsThePointerFromTheSunToTheEnd() {
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 12, width: 200), 0)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 188, width: 200), 1)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 100, width: 200), 0.5)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: -10, width: 200), 0)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 300, width: 200), 1)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 10, width: 20), 0)
    }

    func testFillAlwaysCoversTheSun() {
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 0, width: 200), 24)
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 0.5, width: 200), 112)
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 1, width: 200), 200)
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 2, width: 200), 200)
    }

    func testEveryStatusLineFitsTheNarrowestIsland() {
        // 310 pt island, 10 pt padding on both sides, 32 pt under the back button.
        let lineWidth: CGFloat = 310 - 20 - 32
        let iconAndSpacing: CGFloat = 19
        let notices = [ScreenBrightnessController.writeFailedNotice,
                       ScreenBrightnessController.extraUnavailableNotice,
                       ScreenBrightnessController.otherAppNotice,
                       ScreenBrightnessController.coolingNotice,
                       ScreenBrightnessController.holdFailedNotice,
                       ScreenBrightnessController.holdCoolingNotice]
        for notice in notices {
            XCTAssertLessThanOrEqual(Self.width(notice, size: 10) + iconAndSpacing, lineWidth, notice)
        }
        XCTAssertLessThanOrEqual(Self.width(IslandBrightnessStrip.unavailableText, size: 11), lineWidth)
    }

    /// The real strip with fake hardware, laid out in an unordered offscreen window.
    func testStripFitsItsBandInEveryState() throws {
        for width in [CGFloat(310), 330, 500] {
            for state in StripState.allCases {
                let fixture = StripFixture(state: state, width: width)
                defer { fixture.close() }
                fixture.settle()
                // Without a status line only the control row and its padding remain.
                let expected: CGFloat = [.notice, .unavailable].contains(state) ? IslandBrightnessStrip.contentHeight : 44
                XCTAssertEqual(fixture.idealHeight, expected, accuracy: 0.5, "\(state) at \(width) pt")
                try saveProofImage(of: fixture.host, named: "brightness-\(state)-\(Int(width))")
            }
        }
    }

    /// The island never becomes the active app's key window, and there the native switch drew
    /// Extra's on state gray (user screenshot, 2026-10-19). The unordered fixture window is not key.
    func testExtraSwitchShowsTheAccentColorOnlyWhenOnInAnInactiveWindow() throws {
        for state in [StripState.extraOn, .extraOff] {
            let fixture = StripFixture(state: state, width: 310)
            defer { fixture.close() }
            fixture.settle()
            XCTAssertFalse(fixture.window.isKeyWindow)
            // The switch ends the control row: 10 pt padding, then the 24 pt row.
            // The compact island switch stays fixed blue (#0064D2) in both themes.
            // Adaptive Settings accent resolves against the caller's appearance and
            // can differ from this fill; it is not the inactive-island contract.
            let fixedBlue = NSColor(srgbRed: 0, green: 100.0 / 255, blue: 210.0 / 255, alpha: 1)
            let accent = try fixture.pixelCount(in: CGRect(x: 310 - 10 - 44, y: 10, width: 44, height: 24),
                                                near: fixedBlue)
            if state == .extraOn {
                XCTAssertGreaterThan(accent, 40, "On draws the accent color without key status.")
            } else {
                XCTAssertEqual(accent, 0, "Off stays neutral.")
            }
        }
    }

    func testOnlyAShownStripPollsTheDisplay() {
        let fixture = StripFixture(state: .extraOff, width: 310)
        defer { fixture.close() }
        fixture.settle()
        XCTAssertTrue(fixture.controller.isPolling)

        fixture.removeStrip()
        XCTAssertFalse(fixture.controller.isPolling)
    }

    func testHoldButtonFirstMouseHonorsLocalAndInheritedDisabledState() {
        for (local, inherited) in [(true, true), (false, true), (true, false)] {
            let bridge = IslandHoverHitBridge()
            bridge.setEnabled(true)
            bridge.setSurface(.navigation)
            bridge.setContext("brightness")
            var activations = 0
            let host = NSHostingView(rootView:
                BrightnessHoldButton(isOn: false, isEnabled: local, action: { activations += 1 })
                    .disabled(!inherited)
                    .frame(width: 40, height: 40)
                    .environment(\.islandHoverNavigation, .init(bridge: bridge, context: "brightness"))
                    .islandHoverHitRegion(bridge: bridge, surface: .navigation))
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 40, height: 40),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let point = host.convert(CGPoint(x: 20, y: 20), to: nil)
            XCTAssertEqual(bridge.mouseDown(at: point, in: window, allowed: true), local && inherited)
            bridge.mouseUp(at: point, in: window, allowed: true)
            XCTAssertEqual(activations, local && inherited ? 1 : 0)
        }
    }

    func testHoldFeedbackSurfaces() throws {
        for isOn in [false, true] {
            for state in ["idle", "hover", "pressed", "focus", "disabled"] {
                let host = NSHostingView(rootView:
                    Image(systemName: isOn ? "lock.fill" : "lock.open")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .frame(width: 24, height: 24)
                        .background(BrightnessHoldSurface(isOn: isOn, hovered: state == "hover" || state == "disabled",
                            pressed: state == "pressed", focused: state == "focus", enabled: state != "disabled"))
                        .opacity(state == "disabled" ? 0.42 : 1)
                        .padding(8).background(Color(white: 0.11)))
                host.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
                host.layoutSubtreeIfNeeded()
                try saveProofImage(of: host, named: "hold-\(isOn ? "on" : "off")-\(state)")
            }
        }
    }

    // MARK: Settings

    func testSettingsPaneReadsTheDisplayWithoutPolling() {
        let fixture = SettingsPaneFixture(state: .extraOff, prepared: false)
        defer { fixture.close() }
        XCTAssertFalse(fixture.controller.supportsExtra, "Nothing has read the display yet.")

        fixture.settle()

        XCTAssertTrue(fixture.controller.supportsExtra, "Opening the pane offers Extra without the island.")
        XCTAssertFalse(fixture.controller.isPolling,
                       "Closing the Settings window may skip onDisappear, so the pane starts no timer.")
    }

    func testSettingsPaneRetriesARefusedBrightnessKeyTap() {
        let fixture = SettingsPaneFixture(state: .extraOff, keys: .refused)
        defer { fixture.close() }
        XCTAssertFalse(fixture.keys.isListening)
        fixture.tap.accepts = true

        fixture.settle()

        XCTAssertTrue(fixture.keys.isListening,
                      "Accessibility allowed after the refusal takes effect when Settings shows the switch.")
    }

    /// The real pane with fake hardware, rendered in an unordered offscreen window.
    func testSettingsPaneRemainsReachableInTheToolViewportInEveryState() throws {
        for state in StripState.allCases {
            for keys in PaneKeys.allCases {
                let fixture = SettingsPaneFixture(state: state, keys: keys)
                defer { fixture.close() }
                fixture.settle()
                XCTAssertLessThanOrEqual(fixture.idealHeight, SettingsPaneFixture.availableHeight,
                                         "\(state), keys \(keys)")
                try saveProofImage(of: fixture.host, named: "settings-display-\(state)-keys-\(keys)-top")
                let scroll = try XCTUnwrap(fixture.scrollView)
                let document = try XCTUnwrap(scroll.documentView)
                let clip = scroll.contentView
                XCTAssertGreaterThan(document.frame.height, clip.bounds.height,
                                     "The minimum-height tool content must scroll in a short viewport.")
                clip.scroll(to: NSPoint(x: document.bounds.minX,
                                        y: max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)))
                scroll.reflectScrolledClipView(clip)
                fixture.settle()
                XCTAssertGreaterThan(clip.bounds.minY, document.bounds.minY,
                                     "The viewport must actually move, rather than clipping a tall notice.")
                XCTAssertGreaterThanOrEqual(document.visibleRect.maxY, document.bounds.maxY - 1,
                                             "The bottom controls and notice remain reachable.")
                try saveProofImage(of: fixture.host, named: "settings-display-\(state)-keys-\(keys)-bottom")
            }
        }
    }

    private static func width(_ text: String, size: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
        ]).size().width
    }
}

private enum StripState: String, CaseIterable {
    case extraOff, extraOn, holdOn, noExtra, unavailable, notice

    @MainActor
    func makeController() -> ScreenBrightnessController {
        let device = StaticBrightnessDevice(
            headroom: self == .noExtra ? 1 : 16,
            level: self == .unavailable ? nil : 0.62,
            canWrite: self != .notice)
        return ScreenBrightnessController(device: device, selectedDisplayID: { 1 }, observeSystem: false,
                                          isDisplayAwake: { _ in true })
    }

    @MainActor
    func prepare(_ controller: ScreenBrightnessController) {
        controller.refresh()
        switch self {
        case .extraOn: controller.setExtra(true)
        case .holdOn: controller.setHoldingLevel(true)
        case .notice: controller.setLevel(0.3)
        default: break
        }
    }
}

/// Saved only when EXODIA_BRIGHTNESS_PROOF_DIR names a folder.
@MainActor
private func saveProofImage(of host: NSView, named name: String) throws {
    guard let output = ProcessInfo.processInfo.environment["EXODIA_BRIGHTNESS_PROOF_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: directory.appendingPathComponent(name + ".png"))
}

/// No real backlight, overlay or input events.
@MainActor
private final class StripFixture {
    let controller: ScreenBrightnessController
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init(state: StripState, width: CGFloat) {
        let controller = state.makeController()
        self.controller = controller
        state.prepare(controller)

        window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width,
                                              height: IslandBrightnessStrip.contentHeight),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host = NSHostingView(rootView: AnyView(
            IslandBrightnessStrip(controller: controller, onBack: {})
                .frame(width: width)
                .background(Color(white: 0.11))
                .environment(\.colorScheme, .dark)))
        // Default sizing options keep fittingSize at the strip's ideal size (with none it is zero);
        // the drawer gives the strip exactly its content height.
        host.frame = CGRect(x: 0, y: 0, width: width, height: IslandBrightnessStrip.contentHeight)
        window.contentView = host
    }

    /// The strip's own height, independent of the frame the drawer gives it.
    var idealHeight: CGFloat { host.fittingSize.height }

    func settle() {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
        host.layoutSubtreeIfNeeded()
    }

    /// Rendered pixels within `rect` (points, top-left origin) close to `color` in sRGB.
    func pixelCount(in rect: CGRect, near color: NSColor) throws -> Int {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let target = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var count = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let distance = abs(pixel.redComponent - target.redComponent)
                    + abs(pixel.greenComponent - target.greenComponent)
                    + abs(pixel.blueComponent - target.blueComponent)
                if distance < 0.15 { count += 1 }
            }
        }
        return count
    }

    func removeStrip() {
        host.rootView = AnyView(EmptyView())
        settle()
    }

    func close() {
        removeStrip()
        controller.shutdown()
        window.contentView = nil
        window.close()
    }
}

/// Brightness keys as the Settings pane finds them: off, listening, or refused by macOS.
private enum PaneKeys: String, CaseIterable {
    case off, on, refused
}

/// Settings -> Toolbox -> Display with fake hardware and a fake key tap, in an unordered
/// offscreen window.
@MainActor
private final class SettingsPaneFixture {
    /// The Toolbox action pane is 300 pt wide with 16 pt padding.
    static let width: CGFloat = 268
    /// At the Toolbox row's 300 pt minimum height: the 13 pt ACTION label, 10 pt spacing and 32 pt
    /// padding leave 245 pt, and the tool header, its divider and their spacing take 57 pt.
    static let availableHeight: CGFloat = 188

    let controller: ScreenBrightnessController
    let tap = FakeKeyTap()
    let keys: BrightnessKeys
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private let suite = "BrightnessHoverToolTests-\(UUID().uuidString)"

    init(state: StripState, keys keysState: PaneKeys = .off, prepared: Bool = true) {
        controller = state.makeController()
        if prepared { state.prepare(controller) }
        keys = BrightnessKeys(defaults: UserDefaults(suiteName: suite)!, controller: controller, tap: tap,
                              hoverHidden: Just(false).eraseToAnyPublisher())
        keys.start(showStrip: {})
        if keysState != .off {
            tap.accepts = keysState == .on
            keys.setEnabled(true)
        }
        let size = CGSize(width: Self.width, height: Self.availableHeight)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let displayController = controller
        let brightnessKeys = keys
        host = NSHostingView(rootView: AnyView(
            ToolboxToolViewport {
                ToolboxDisplayPane(controller: displayController, keys: brightnessKeys)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
                .frame(width: Self.width, height: Self.availableHeight)
                .background(Color(white: 0.13))
                .environment(\.colorScheme, .dark)))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
    }

    /// The visible tool viewport remains bounded while its document can scroll.
    var idealHeight: CGFloat { host.fittingSize.height }

    var scrollView: NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews {
                if let scroll = find(in: child) { return scroll }
            }
            return nil
        }
        return find(in: host)
    }

    func settle() {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        settle()
        keys.stop()
        controller.shutdown()
        window.contentView = nil
        window.close()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class StaticBrightnessDevice: ScreenBrightnessDevice {
    private let headroom: Double
    private var level: Double?
    private let canWrite: Bool

    init(headroom: Double, level: Double?, canWrite: Bool) {
        self.headroom = headroom
        self.level = level
        self.canWrite = canWrite
    }

    func displays() -> [ScreenBrightnessDisplay] { [ScreenBrightnessDisplay(id: 1, potentialHeadroom: headroom)] }

    func read(_ id: CGDirectDisplayID) -> Double? { level }

    func write(_ next: Double, to id: CGDirectDisplayID) -> Bool {
        guard canWrite, level != nil else { return false }
        level = next
        return true
    }

    func makeBoost(for id: CGDirectDisplayID, onEnd: @escaping (BrightnessBoostEnd) -> Void) -> BrightnessBoost? {
        NoBoost()
    }
}

@MainActor
private final class NoBoost: BrightnessBoost {
    func refresh() {}
    func close() {}
}
