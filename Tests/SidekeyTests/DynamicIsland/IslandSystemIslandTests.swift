import AppKit
import XCTest
@testable import Sidekey

/// Scenarios for the island beside the system Dynamic Island (touch MacBook
/// Pro, macOS 27). Apple publishes neither the island's size nor what
/// `safeAreaInsets` / `auxiliaryTop*Area` report on that display, so the touch
/// screens below are hypotheses: a reported cutout like today's notch, a
/// narrow one, and none at all. The regression criterion is the first group:
/// every ordinary Mac keeps exactly the frames it had.
@MainActor
final class IslandSystemIslandTests: XCTestCase {

    // MARK: - Screens

    /// Notched 14" MacBook Pro today (same baseline as IslandFrameLayoutTests).
    private static func notchedMac(touch: Bool = false) -> IslandScreenDescriptor {
        IslandScreenDescriptor(
            uuid: "builtin",
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 76, width: 1512, height: 868),
            safeAreaTopInset: 38,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 944, width: 670, height: 38),
            auxiliaryTopRightArea: NSRect(x: 842, y: 944, width: 670, height: 38),
            isBuiltIn: true,
            isTouchCapable: touch
        )
    }

    /// Touch MacBook Pro 14" (3024×1986 px → 1512×993 pt) reporting a cutout
    /// of `cutout` points, or no camera housing when `cutout` is nil.
    private static func touchMac(cutout: CGFloat?, width: CGFloat = 1512) -> IslandScreenDescriptor {
        let frame = NSRect(x: 0, y: 0, width: width, height: 993)
        guard let cutout else {
            return IslandScreenDescriptor(
                uuid: "touch",
                frame: frame,
                visibleFrame: NSRect(x: 0, y: 70, width: width, height: 899),
                safeAreaTopInset: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil,
                isBuiltIn: true,
                isTouchCapable: true
            )
        }
        let left = (width - cutout) / 2
        return IslandScreenDescriptor(
            uuid: "touch",
            frame: frame,
            visibleFrame: NSRect(x: 0, y: 70, width: width, height: 891),
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 961, width: left, height: 32),
            auxiliaryTopRightArea: NSRect(x: left + cutout, y: 961, width: left, height: 32),
            isBuiltIn: true,
            isTouchCapable: true
        )
    }

    private static let external = IslandScreenDescriptor(
        uuid: "external",
        frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1415),
        safeAreaTopInset: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    private static func resolved(
        _ screens: [IslandScreenDescriptor],
        placement: IslandSystemIslandPlacement = .automatic,
        preferred: String? = nil
    ) -> IslandScreenDescriptor {
        IslandScreenResolver.selectDescriptor(
            preferredUUID: preferred, descriptors: screens, placement: placement)
    }

    /// The frames every island surface takes from one descriptor.
    private struct Frames: Equatable {
        let island: NSRect
        let host: NSRect
        let agentHost: NSRect
        let leftNotification: NSRect
        let notificationPanel: NSRect
        let meetingSuggestion: NSRect
        let gap: CGFloat
    }

    private static func frames(_ screen: IslandScreenDescriptor) -> Frames {
        Frames(
            island: IslandFrameLayout.islandFrame(on: screen),
            host: IslandFrameLayout.hostPanelFrame(on: screen),
            agentHost: IslandFrameLayout.hostPanelFrame(on: screen, agentActive: true),
            leftNotification: IslandFrameLayout.leftNotificationFrame(on: screen),
            notificationPanel: IslandFrameLayout.notificationPanelFrame(on: screen),
            meetingSuggestion: MeetingPillPanel.suggestionFrame(on: screen),
            gap: IslandFrameLayout.capsuleGapWidth(on: screen)
        )
    }

    /// The pre-change math: raw parameters without any placement.
    private static func legacyFrames(_ screen: IslandScreenDescriptor) -> Frames {
        let island = IslandFrameLayout.islandFrame(
            frame: screen.frame, visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaTopInset,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea)
        return Frames(
            island: island,
            host: IslandFrameLayout.hostPanelFrame(
                frame: screen.frame, visibleFrame: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaTopInset,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea),
            agentHost: IslandFrameLayout.hostPanelFrame(
                frame: screen.frame, visibleFrame: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaTopInset,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea, agentActive: true),
            leftNotification: IslandFrameLayout.leftNotificationFrame(
                frame: screen.frame, visibleFrame: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaTopInset,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea),
            notificationPanel: IslandFrameLayout.notificationPanelFrame(
                frame: screen.frame, visibleFrame: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaTopInset,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea),
            meetingSuggestion: MeetingPillPanel.suggestionFrame(
                frame: screen.frame, visibleFrame: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaTopInset,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea),
            gap: IslandFrameLayout.notchMetrics(on: screen).width
        )
    }

    // MARK: - Ordinary Macs do not change

    func test_notchedMacWithoutTouchKeepsEveryFrameOnAutomatic() {
        let screen = Self.resolved([Self.notchedMac()])
        XCTAssertFalse(screen.besideSystemIsland)
        XCTAssertEqual(Self.frames(screen), Self.legacyFrames(Self.notchedMac()))
        XCTAssertEqual(IslandFrameLayout.islandFrame(on: screen).minX, 600, accuracy: 0.001,
                       "capsule still wraps the notch: 670 - 70")
    }

    func test_externalMonitorKeepsEveryFrameOnAutomatic() {
        let screen = Self.resolved([Self.external])
        XCTAssertFalse(screen.besideSystemIsland)
        XCTAssertEqual(Self.frames(screen), Self.legacyFrames(Self.external))
    }

    func test_sidecarMakingEveryScreenReportTouchDoesNotMoveTheNotchedIsland() {
        // TN3212: a touch Sidecar makes touchCapabilities true for all displays.
        var sidecar = Self.external
        sidecar = IslandScreenDescriptor(
            uuid: "sidecar", frame: NSRect(x: 1512, y: 0, width: 1180, height: 820),
            visibleFrame: NSRect(x: 1512, y: 0, width: 1180, height: 795),
            safeAreaTopInset: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
            isBuiltIn: false, isTouchCapable: true)
        let screen = Self.resolved([Self.notchedMac(touch: true), sidecar])
        XCTAssertEqual(screen.uuid, "builtin")
        XCTAssertFalse(screen.besideSystemIsland)
        XCTAssertEqual(Self.frames(screen), Self.legacyFrames(Self.notchedMac()))
    }

    func test_sidecarDoesNotPromoteANotchlessBuiltInDisplayOverThePrimary() {
        let builtIn = Self.touchMac(cutout: nil)
        let primary = IslandScreenDescriptor(
            uuid: "primary", frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1415),
            safeAreaTopInset: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
            isBuiltIn: false, isTouchCapable: true)
        let movedBuiltIn = IslandScreenDescriptor(
            uuid: builtIn.uuid, frame: builtIn.frame.offsetBy(dx: 2560, dy: 0),
            visibleFrame: builtIn.visibleFrame.offsetBy(dx: 2560, dy: 0),
            safeAreaTopInset: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
            isBuiltIn: true, isTouchCapable: true)
        XCTAssertEqual(Self.resolved([movedBuiltIn, primary]).uuid, "primary")
    }

    // MARK: - Touch MacBook Pro

    func test_touchMacReportingANotchPutsTheCapsuleRightOfTheSystemIsland() {
        let screen = Self.resolved([Self.touchMac(cutout: 172)])
        XCTAssertTrue(screen.besideSystemIsland)
        let zone = IslandFrameLayout.systemIslandZone(on: screen)
        let island = IslandFrameLayout.islandFrame(on: screen)
        XCTAssertEqual(zone.midX, 756, accuracy: 0.001)
        XCTAssertEqual(zone.width, IslandSystemIslandPlacement.defaultReservedWidth, accuracy: 0.001)
        XCTAssertEqual(island.minX, zone.maxX + IslandFrameLayout.systemIslandGap, accuracy: 0.001)
        XCTAssertEqual(island.width, 310, accuracy: 0.001, "external-monitor shape keeps the drawer width")
        XCTAssertEqual(island.height, 32, accuracy: 0.001)
        XCTAssertEqual(island.maxY, 993, accuracy: 0.001)
        XCTAssertFalse(island.intersects(zone))
        XCTAssertEqual(IslandFrameLayout.capsuleGapWidth(on: screen), IslandFrameLayout.syntheticNotchWidth)
    }

    func test_narrowReportedCutoutStillKeepsTheFullReservedZone() {
        for cutout: CGFloat in [90, 125] {
            let screen = Self.resolved([Self.touchMac(cutout: cutout)])
            let zone = IslandFrameLayout.systemIslandZone(on: screen)
            let island = IslandFrameLayout.islandFrame(on: screen)
            XCTAssertEqual(zone.width, 260, accuracy: 0.001)
            XCTAssertEqual(zone.midX, 756, accuracy: 0.001)
            XCTAssertFalse(island.intersects(zone), "cutout \(cutout)")
            XCTAssertEqual(island.width, 310, accuracy: 0.001, "drawer keeps 90 pt tiles")
            XCTAssertEqual(IslandHoverControlsLayout.tileWidth(panelWidth: island.width), 90, accuracy: 0.001)
        }
    }

    func test_touchMacReportingNoCameraHousingCentersTheZoneOnTheScreen() {
        let screen = Self.resolved([Self.touchMac(cutout: nil)])
        XCTAssertTrue(screen.besideSystemIsland)
        let zone = IslandFrameLayout.systemIslandZone(on: screen)
        let island = IslandFrameLayout.islandFrame(on: screen)
        XCTAssertEqual(zone.midX, 756, accuracy: 0.001)
        XCTAssertFalse(island.intersects(zone))
        XCTAssertEqual(island.height, 24, accuracy: 0.001, "menu-bar height clamp as on an external monitor")
    }

    func test_reportedCutoutWiderThanTheReserveWidensTheZone() {
        let screen = Self.touchMac(cutout: 300).placing(besideSystemIsland: true, reservedWidth: 260)
        let zone = IslandFrameLayout.systemIslandZone(on: screen)
        XCTAssertEqual(zone.width, 300, accuracy: 0.001)
        XCTAssertFalse(IslandFrameLayout.islandFrame(on: screen).intersects(zone))
    }

    func test_notificationCardMovesLeftOfTheSystemIslandNotOverIt() {
        let screen = Self.resolved([Self.touchMac(cutout: 172)])
        let zone = IslandFrameLayout.systemIslandZone(on: screen)
        let panel = IslandFrameLayout.notificationPanelFrame(on: screen)
        XCTAssertEqual(panel.maxX, zone.minX, accuracy: 0.001)
        XCTAssertEqual(panel.width, IslandFrameLayout.leftNotificationWidth
                       + IslandNotificationPill.panelLeadingOverflow, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(panel.minX, 0)
    }

    func test_widestAgentFaceStaysOnTheDefault14InchScreen() {
        let screen = Self.resolved([Self.touchMac(cutout: 172)])
        let island = IslandFrameLayout.islandFrame(on: screen)
        let widestFace = IslandFrameLayout.mergedCapsuleWidth(
            compactWidth: island.width,
            extension: IslandFrameLayout.agentWingExtension(faceWidth: IslandFrameLayout.agentWingComposingWidth))
        XCTAssertLessThanOrEqual(island.minX + widestFace, screen.frame.maxX)
    }

    func test_narrowScaledScreenKeepsTheAgentFaceOnScreenBeforeTheGap() {
        let screen = Self.resolved([Self.touchMac(cutout: 172, width: 1024)])
        let island = IslandFrameLayout.islandFrame(on: screen)
        XCTAssertEqual(island.maxX + IslandFrameLayout.besideWingReserve, 1024, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(island.minX, 0)
    }

    func test_meetingNudgeFollowsTheMovedCapsule() {
        let screen = Self.resolved([Self.touchMac(cutout: 172)])
        let island = IslandFrameLayout.islandFrame(on: screen)
        let nudge = MeetingPillPanel.suggestionFrame(on: screen)
        XCTAssertEqual(nudge.midX, island.midX, accuracy: 0.001)
        XCTAssertEqual(nudge.maxY, island.minY, accuracy: 0.001)
    }

    func test_builtInTouchDisplayWinsOverThePrimaryWhenItReportsNoNotch() {
        let builtIn = Self.touchMac(cutout: nil)
        let primary = IslandScreenDescriptor(
            uuid: "primary", frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1415),
            safeAreaTopInset: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
        let movedBuiltIn = IslandScreenDescriptor(
            uuid: "touch", frame: builtIn.frame.offsetBy(dx: 2560, dy: 0),
            visibleFrame: builtIn.visibleFrame.offsetBy(dx: 2560, dy: 0),
            safeAreaTopInset: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
            isBuiltIn: true, isTouchCapable: true)
        let screen = Self.resolved([primary, movedBuiltIn])
        XCTAssertEqual(screen.uuid, "touch")
        XCTAssertTrue(screen.besideSystemIsland)
    }

    func test_islandOnAnExternalMonitorOfATouchMacStaysCentered() {
        let screen = Self.resolved([Self.touchMac(cutout: 172), Self.external], preferred: "external")
        XCTAssertEqual(screen.uuid, "external")
        XCTAssertFalse(screen.besideSystemIsland)
        XCTAssertEqual(Self.frames(screen), Self.legacyFrames(Self.external))
    }

    // MARK: - User choice

    func test_besideIsAPreviewOnAnOrdinaryNotchedMac() {
        let screen = Self.resolved([Self.notchedMac()], placement: .beside)
        XCTAssertTrue(screen.besideSystemIsland)
        let zone = IslandFrameLayout.systemIslandZone(on: screen)
        XCTAssertEqual(zone.midX, 756, accuracy: 0.001, "centered on the real notch 670...842")
        XCTAssertFalse(IslandFrameLayout.islandFrame(on: screen).intersects(zone))
    }

    func test_aroundKeepsTheOldLayoutOnATouchMac() {
        let touch = Self.touchMac(cutout: 172)
        let screen = Self.resolved([touch], placement: .around)
        XCTAssertFalse(screen.besideSystemIsland)
        XCTAssertEqual(Self.frames(screen), Self.legacyFrames(touch))
    }

    func test_placementPersistsAndPostsOnlyRealChanges() {
        let suite = "IslandSystemIslandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(
            forName: IslandScreenResolver.selectionDidChangeNotification, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        XCTAssertEqual(IslandSystemIslandPlacement.current(in: defaults), .automatic)
        IslandSystemIslandPlacement.set(.automatic, in: defaults, center: center)
        XCTAssertEqual(posts, 0)
        IslandSystemIslandPlacement.set(.around, in: defaults, center: center)
        XCTAssertEqual(defaults.string(forKey: IslandSystemIslandPlacement.defaultsKey), "around")
        XCTAssertEqual(posts, 1)
        IslandSystemIslandPlacement.set(.around, in: defaults, center: center)
        XCTAssertEqual(posts, 1)
        IslandSystemIslandPlacement.set(.automatic, in: defaults, center: center)
        XCTAssertNil(defaults.object(forKey: IslandSystemIslandPlacement.defaultsKey))
        XCTAssertEqual(posts, 2)

        defaults.set("sideways", forKey: IslandSystemIslandPlacement.defaultsKey)
        XCTAssertEqual(IslandSystemIslandPlacement.current(in: defaults), .automatic,
                       "an unknown value from a newer build reads as Automatic")
    }

    func test_reservedWidthOverrideIsClamped() {
        let suite = "IslandSystemIslandTests.width.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = IslandSystemIslandPlacement.reservedWidthDefaultsKey
        XCTAssertEqual(IslandSystemIslandPlacement.reservedWidth(in: defaults), 260)
        defaults.set(320, forKey: key)
        XCTAssertEqual(IslandSystemIslandPlacement.reservedWidth(in: defaults), 320)
        defaults.set(10, forKey: key)
        XCTAssertEqual(IslandSystemIslandPlacement.reservedWidth(in: defaults), 120)
        defaults.set(5000, forKey: key)
        XCTAssertEqual(IslandSystemIslandPlacement.reservedWidth(in: defaults), 600)
        defaults.set("wide", forKey: key)
        XCTAssertEqual(IslandSystemIslandPlacement.reservedWidth(in: defaults), 260)
    }

    func test_placementStaysOnThisMacButIsBackedUp() {
        XCTAssertFalse(SettingsSyncItem.syncsPreference(IslandSystemIslandPlacement.defaultsKey))
    }

    // MARK: - Live screens

    @MainActor
    func test_thisMacsScreensReportNoTouchBeforeATouchDisplayExists() throws {
        // On every Mac without a touch display (macOS < 27 has no selector)
        // the live read must be false, so Automatic changes nothing here.
        let anyTouch = NSScreen.screens.contains { $0.sidekeyIsTouchCapable }
        if anyTouch {
            throw XCTSkip("a touch display or touch Sidecar is connected")
        }
        XCTAssertFalse(anyTouch)
    }
}

/// Offscreen schematic PNGs of the computed frames for review. They draw the
/// real layout functions (capsule, drawer for six tools, notification card,
/// widest agent face and the reserved system-island zone), not the SwiftUI
/// island itself, and never open a window.
@MainActor
final class IslandSystemIslandRenderTests: XCTestCase {
    func testRenderPlacements() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_ISLAND_PLACEMENT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_ISLAND_PLACEMENT_RENDER_DIR to save offscreen placement images")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func touch(_ cutout: CGFloat?, width: CGFloat = 1512) -> IslandScreenDescriptor {
            let frame = NSRect(x: 0, y: 0, width: width, height: 993)
            guard let cutout else {
                return IslandScreenDescriptor(
                    uuid: "t", frame: frame, visibleFrame: NSRect(x: 0, y: 70, width: width, height: 899),
                    safeAreaTopInset: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
                    isBuiltIn: true, isTouchCapable: true)
            }
            let left = (width - cutout) / 2
            return IslandScreenDescriptor(
                uuid: "t", frame: frame, visibleFrame: NSRect(x: 0, y: 70, width: width, height: 891),
                safeAreaTopInset: 32,
                auxiliaryTopLeftArea: NSRect(x: 0, y: 961, width: left, height: 32),
                auxiliaryTopRightArea: NSRect(x: left + cutout, y: 961, width: left, height: 32),
                isBuiltIn: true, isTouchCapable: true)
        }
        let notched = IslandScreenDescriptor(
            uuid: "n", frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 76, width: 1512, height: 868), safeAreaTopInset: 38,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 944, width: 670, height: 38),
            auxiliaryTopRightArea: NSRect(x: 842, y: 944, width: 670, height: 38),
            isBuiltIn: true, isTouchCapable: false)

        let cases: [(String, IslandScreenDescriptor, IslandSystemIslandPlacement)] = [
            ("1-notched-mac-automatic-unchanged", notched, .automatic),
            ("2-notched-mac-beside-preview", notched, .beside),
            ("3-touch-cutout-172", touch(172), .automatic),
            ("4-touch-cutout-125", touch(125), .automatic),
            ("5-touch-cutout-90", touch(90), .automatic),
            ("6-touch-no-safe-area", touch(nil), .automatic),
            ("7-touch-around-off", touch(125), .around),
            ("8-touch-scaled-1024", touch(172, width: 1024), .automatic),
        ]
        for (name, raw, placement) in cases {
            let screen = IslandScreenResolver.selectDescriptor(
                preferredUUID: nil, descriptors: [raw], placement: placement)
            let png = try Self.render(screen: screen, title: name)
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private static func render(screen: IslandScreenDescriptor, title: String) throws -> Data {
        let scale: CGFloat = 1
        let bandHeight: CGFloat = 330
        let size = NSSize(width: screen.frame.width * scale, height: bandHeight)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw NSError(domain: "render", code: 1) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Map screen coordinates (y-up, top = frame.maxY) into the band.
        let top = screen.frame.maxY
        func map(_ r: NSRect) -> NSRect {
            NSRect(x: (r.minX - screen.frame.minX) * scale,
                   y: bandHeight - (top - r.minY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let menuBar = top - screen.visibleFrame.maxY
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        map(NSRect(x: screen.frame.minX, y: top - menuBar, width: screen.frame.width, height: menuBar)).fill()

        let metrics = IslandFrameLayout.notchMetrics(on: screen)
        if metrics.isRealNotch, let left = metrics.leftEdgeX {
            NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
            map(NSRect(x: left, y: top - screen.safeAreaTopInset, width: metrics.width,
                       height: screen.safeAreaTopInset)).fill()
        }
        if screen.besideSystemIsland {
            let zone = IslandFrameLayout.systemIslandZone(on: screen)
            let zoneRect = map(NSRect(x: zone.minX, y: top - 36, width: zone.width, height: 36))
            let path = NSBezierPath(roundedRect: zoneRect.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.lineWidth = 2
            NSColor.systemRed.setStroke()
            path.stroke()
        }

        let island = IslandFrameLayout.islandFrame(on: screen)
        let drawerHeight = IslandDropModeControl.controlsHoverPanelHeight(toolCount: 6)
        let drawer = NSRect(x: island.minX,
                            y: island.minY - IslandDropModeControl.detachedPanelGap - drawerHeight,
                            width: island.width, height: drawerHeight)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: map(drawer), xRadius: 14, yRadius: 14).fill()
        let tile = IslandHoverControlsLayout.tileWidth(panelWidth: island.width)
        for row in 0..<2 {
            for column in 0..<3 {
                let x = drawer.minX + IslandHoverControlsLayout.horizontalInset
                    + CGFloat(column) * (tile + IslandHoverControlsLayout.columnSpacing)
                let y = drawer.maxY - IslandHoverControlsLayout.gridVerticalInset
                    - IslandHoverControlsLayout.rowVerticalInset - IslandHoverPanelControl.tileHeight
                    - CGFloat(row) * IslandHoverControlsLayout.rowStride
                NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
                NSBezierPath(roundedRect: map(NSRect(x: x, y: y, width: tile, height: IslandHoverPanelControl.tileHeight)),
                             xRadius: 10, yRadius: 10).fill()
            }
        }

        let wing = IslandFrameLayout.agentWingExtension(faceWidth: IslandFrameLayout.agentWingComposingWidth)
        let wingPath = NSBezierPath(rect: map(NSRect(x: island.maxX, y: island.minY, width: wing,
                                                     height: island.height)).insetBy(dx: 1, dy: 1))
        wingPath.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemGray.setStroke()
        wingPath.stroke()

        NSColor.black.setFill()
        NSBezierPath(roundedRect: map(island), xRadius: 8, yRadius: 8).fill()

        let panel = IslandFrameLayout.notificationPanelFrame(on: screen)
        let card = NSRect(x: panel.maxX - IslandFrameLayout.agentWingGap - IslandFrameLayout.leftNotificationWidth,
                          y: top - IslandNotificationPill.pillHeight,
                          width: IslandFrameLayout.leftNotificationWidth, height: IslandNotificationPill.pillHeight)
        let cardPath = NSBezierPath(roundedRect: map(card).insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        cardPath.lineWidth = 2
        NSColor.systemBlue.setStroke()
        cardPath.stroke()

        let text = "\(title) — capsule \(Int(island.minX))…\(Int(island.maxX)) × \(Int(island.height)) pt, "
            + "tile \(Int(tile)) pt, beside: \(screen.besideSystemIsland)"
            + "  [red: system island zone, blue: notification card, gray: widest agent face]"
        (text as NSString).draw(at: NSPoint(x: 12, y: 12), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "render", code: 2)
        }
        return png
    }
}
