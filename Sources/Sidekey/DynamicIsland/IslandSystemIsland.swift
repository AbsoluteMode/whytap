import AppKit
import CoreGraphics
import Foundation

/// Where Whytap's island goes on a Mac whose display has the system Dynamic
/// Island (MacBook Pro with PROLED XDR Display, macOS 27): there macOS shows
/// its own Live Activities, calls, AirDrop, Spotlight and the microphone and
/// camera privacy indicators around the camera, and a tap or swipe there
/// belongs to the system. Whytap's black capsule must not cover it.
///
/// - `automatic`: beside the system island only on a built-in touch display
///   (`IslandSystemIslandPolicy`); every other Mac keeps the capsule wrapped
///   around the camera exactly as before.
/// - `beside`: always beside the camera area, also on a notched Mac (a
///   preview of the touch-Mac layout on the hardware we have).
/// - `around`: always around the camera, the pre-2026-11 layout, also on a
///   touch Mac.
///
/// WHY: .project-docs/decisions/2026-11-22-island-beside-system-island.md
enum IslandSystemIslandPlacement: String, CaseIterable, Equatable {
    case automatic
    case beside
    case around

    static let defaultsKey = "sidekey.dynamicIsland.systemIslandPlacement"
    /// Width macOS keeps for its own island, centered on the camera. Apple
    /// publishes no size; Live Activities grow beyond the cutout on both sides,
    /// so the default reserves more than any cutout. A UserDefaults override
    /// (no UI) lets the owner calibrate it on the real MacBook.
    static let reservedWidthDefaultsKey = "sidekey.dynamicIsland.systemIslandReservedWidth"
    static let defaultReservedWidth: CGFloat = 260
    static let reservedWidthRange: ClosedRange<CGFloat> = 120...600

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .beside: return "Beside the camera"
        case .around: return "Around the camera"
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> IslandSystemIslandPlacement {
        defaults.string(forKey: defaultsKey).flatMap(IslandSystemIslandPlacement.init(rawValue:)) ?? .automatic
    }

    /// Persists a change and re-anchors every overlay panel through the same
    /// notification the display picker uses. Re-saving the same value posts
    /// nothing.
    static func set(
        _ placement: IslandSystemIslandPlacement,
        in defaults: UserDefaults = .standard,
        center: NotificationCenter = .default
    ) {
        guard placement != current(in: defaults) else { return }
        if placement == .automatic {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(placement.rawValue, forKey: defaultsKey)
        }
        center.post(name: IslandScreenResolver.selectionDidChangeNotification, object: nil)
    }

    static func reservedWidth(in defaults: UserDefaults = .standard) -> CGFloat {
        guard let value = defaults.object(forKey: reservedWidthDefaultsKey) as? NSNumber else {
            return defaultReservedWidth
        }
        let width = CGFloat(value.doubleValue)
        guard width.isFinite else { return defaultReservedWidth }
        return min(max(width, reservedWidthRange.lowerBound), reservedWidthRange.upperBound)
    }
}

/// Pure decision: does the island go beside the system Dynamic Island on
/// this screen?
enum IslandSystemIslandPolicy {
    /// `automatic` turns on only for a built-in display that reports touch.
    /// Apple's caveat (TN3212): with a touch Sidecar iPad connected,
    /// `NSScreen.touchCapabilities` reports touch for EVERY display, so when
    /// several screens all report touch the built-in one is not trusted and
    /// an ordinary notched Mac keeps its layout.
    static func placesBesideSystemIsland(
        placement: IslandSystemIslandPlacement,
        screen: IslandScreenDescriptor,
        allScreens: [IslandScreenDescriptor]
    ) -> Bool {
        switch placement {
        case .beside:
            return true
        case .around:
            return false
        case .automatic:
            guard screen.isBuiltIn, screen.isTouchCapable else { return false }
            return !touchReportIsAmbiguous(allScreens: allScreens)
        }
    }

    static func touchReportIsAmbiguous(allScreens: [IslandScreenDescriptor]) -> Bool {
        allScreens.count > 1 && allScreens.allSatisfy(\.isTouchCapable)
    }
}

extension NSScreen {
    /// `NSScreen.touchCapabilities` (macOS 27) without linking the macOS 27
    /// SDK: on older systems the selector is absent and this is `false`.
    /// The only documented capability is multi-touch, so any non-zero mask
    /// counts as a touch display.
    @MainActor
    var sidekeyIsTouchCapable: Bool {
        let selector = NSSelectorFromString("touchCapabilities")
        guard responds(to: selector),
              let mask = value(forKey: "touchCapabilities") as? NSNumber
        else { return false }
        return mask.uintValue != 0
    }

    @MainActor
    var sidekeyIsBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
