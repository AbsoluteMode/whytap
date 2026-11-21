import AppKit
import CoreGraphics
import Foundation

struct IslandScreenDescriptor: Equatable {
    let uuid: String?
    let frame: NSRect
    let visibleFrame: NSRect
    let safeAreaTopInset: CGFloat
    let auxiliaryTopLeftArea: NSRect?
    let auxiliaryTopRightArea: NSRect?
    /// The Mac's own display (not an external monitor or Sidecar iPad).
    let isBuiltIn: Bool
    /// `NSScreen.touchCapabilities` reports touch (macOS 27).
    let isTouchCapable: Bool
    /// Resolved placement: the island sits beside the system Dynamic Island
    /// instead of around the camera. Set by `IslandScreenResolver` from the
    /// user's choice and `IslandSystemIslandPolicy`; false for raw screens.
    let besideSystemIsland: Bool
    /// Width kept free for the system island, centered on the camera.
    let systemIslandReservedWidth: CGFloat

    init(
        uuid: String?,
        frame: NSRect,
        visibleFrame: NSRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?,
        isBuiltIn: Bool = false,
        isTouchCapable: Bool = false,
        besideSystemIsland: Bool = false,
        systemIslandReservedWidth: CGFloat = IslandSystemIslandPlacement.defaultReservedWidth
    ) {
        self.isBuiltIn = isBuiltIn
        self.isTouchCapable = isTouchCapable
        self.besideSystemIsland = besideSystemIsland
        self.systemIslandReservedWidth = systemIslandReservedWidth
        self.uuid = uuid
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea?.isEmpty == false
            ? auxiliaryTopLeftArea
            : nil
        self.auxiliaryTopRightArea = auxiliaryTopRightArea?.isEmpty == false
            ? auxiliaryTopRightArea
            : nil
    }

    @MainActor
    init(screen: NSScreen) {
        self.init(
            uuid: screen.sidekeyDisplayUUID,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            isBuiltIn: screen.sidekeyIsBuiltIn,
            isTouchCapable: screen.sidekeyIsTouchCapable
        )
    }

    var hasRealNotch: Bool {
        IslandFrameLayout.notchMetrics(on: self).isRealNotch
    }

    /// A built-in touch display: the MacBook Pro whose camera area holds the
    /// system Dynamic Island. Used only to rank screens; placement is decided
    /// by `IslandSystemIslandPolicy`.
    var isBuiltInTouchDisplay: Bool { isBuiltIn && isTouchCapable }

    /// The narrowest middle gap the capsule wraps: on a touch display a
    /// narrow reported cutout would shrink the drawer's tiles below 90 pt.
    var minimumCapsuleGap: CGFloat { isTouchCapable ? IslandFrameLayout.syntheticNotchWidth : 0 }

    func placing(besideSystemIsland: Bool, reservedWidth: CGFloat) -> IslandScreenDescriptor {
        IslandScreenDescriptor(
            uuid: uuid,
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTopInset: safeAreaTopInset,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            isBuiltIn: isBuiltIn,
            isTouchCapable: isTouchCapable,
            besideSystemIsland: besideSystemIsland,
            systemIslandReservedWidth: reservedWidth
        )
    }
}

extension NSScreen {
    @MainActor
    var sidekeyDisplayUUID: String? {
        guard
            let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}

enum IslandScreenResolver {
    static let preferredDisplayUUIDKey = "sidekey.dynamicIsland.preferredDisplayUUID"

    /// Posted after `setPreferredDisplayUUID` persists a DIFFERENT value.
    /// Overlay panels treat it exactly like
    /// `NSApplication.didChangeScreenParametersNotification`: re-resolve the
    /// selected screen and re-anchor.
    static let selectionDidChangeNotification = Notification.Name(
        "sidekey.dynamicIsland.screenSelectionDidChange"
    )

    static let fallbackDescriptor = IslandScreenDescriptor(
        uuid: nil,
        frame: NSRect(x: 0, y: 0, width: 1280, height: 824),
        visibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 800),
        safeAreaTopInset: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    static func preferredDisplayUUID(
        in defaults: UserDefaults = .standard
    ) -> String? {
        guard
            let value = defaults.string(forKey: preferredDisplayUUIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    static func setPreferredDisplayUUID(
        _ uuid: String?,
        in defaults: UserDefaults = .standard,
        center: NotificationCenter = .default
    ) {
        let previous = preferredDisplayUUID(in: defaults)
        let normalized: String?
        if
            let value = uuid?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        {
            normalized = value
        } else {
            normalized = nil
        }

        // Re-saving the same value must not re-anchor every overlay panel —
        // post only on a real change.
        guard normalized != previous else { return }

        if let normalized {
            defaults.set(normalized, forKey: preferredDisplayUUIDKey)
        } else {
            defaults.removeObject(forKey: preferredDisplayUUIDKey)
        }
        center.post(name: selectionDidChangeNotification, object: nil)
    }

    /// Selection order: the user's explicit pick, else the screen with the
    /// real notch, else the primary display (frame holds the global origin —
    /// same predicate as `SidekeyWindowChrome.primaryVisibleFrame`), else the
    /// first screen. `NSScreen.main` must NEVER participate: it is the KEY
    /// WINDOW's screen, so on multi-monitor setups it follows every click and
    /// dragged the island onto whatever display the user was working on
    /// (tester report 2026-07-07 — pill "jumps between monitors"). WHY:
    /// docs/decisions/2026-07-07-island-display-selection-not-nsscreen-main.md
    static func selectDescriptor(
        preferredUUID: String?,
        descriptors: [IslandScreenDescriptor],
        placement: IslandSystemIslandPlacement,
        reservedWidth: CGFloat = IslandSystemIslandPlacement.defaultReservedWidth
    ) -> IslandScreenDescriptor {
        let selected = selectDescriptor(preferredUUID: preferredUUID, descriptors: descriptors)
        return selected.placing(
            besideSystemIsland: IslandSystemIslandPolicy.placesBesideSystemIsland(
                placement: placement,
                screen: selected,
                allScreens: descriptors
            ),
            reservedWidth: reservedWidth
        )
    }

    static func selectDescriptor(
        preferredUUID: String?,
        descriptors: [IslandScreenDescriptor]
    ) -> IslandScreenDescriptor {
        let normalizedPreferred = preferredUUID?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if
            let preferred = normalizedPreferred,
            !preferred.isEmpty,
            let descriptor = descriptors.first(where: { $0.uuid == preferred })
        {
            return descriptor
        }

        if let notched = descriptors.first(where: \.hasRealNotch) {
            return notched
        }

        // A touch MacBook may report no camera housing at all; its own
        // display still holds the camera, so it wins over the primary one.
        if
            !IslandSystemIslandPolicy.touchReportIsAmbiguous(allScreens: descriptors),
            let builtInTouch = descriptors.first(where: \.isBuiltInTouchDisplay)
        {
            return builtInTouch
        }

        if let primary = descriptors.first(where: { $0.frame.contains(NSPoint.zero) }) {
            return primary
        }

        return descriptors.first ?? fallbackDescriptor
    }

    @MainActor
    static func currentDescriptor() -> IslandScreenDescriptor {
        IslandScreenCache.shared.selectedDescriptor()
    }

    /// Anchor frame for overlay panels that only need the selected screen's
    /// `visibleFrame` (orb, hint chip, history strip, toasts, modals).
    @MainActor
    static func currentVisibleFrame() -> NSRect {
        currentDescriptor().visibleFrame
    }
}

@MainActor
final class IslandScreenCache {
    static let shared = IslandScreenCache()

    private(set) var descriptors: [IslandScreenDescriptor] = []
    private(set) var descriptorsByUUID: [String: IslandScreenDescriptor] = [:]
    private var observer: Any?

    private init(notificationCenter: NotificationCenter = .default) {
        rebuild()
        observer = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuild()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func rebuild(screens: [NSScreen] = NSScreen.screens) {
        rebuild(descriptors: screens.map(IslandScreenDescriptor.init(screen:)))
    }

    /// Descriptor-level rebuild so tests can drive the cache end-to-end with
    /// synthetic screens (`rebuild(screens:)` needs real `NSScreen`s).
    func rebuild(descriptors nextDescriptors: [IslandScreenDescriptor]) {
        var nextDescriptorsByUUID: [String: IslandScreenDescriptor] = [:]
        for descriptor in nextDescriptors {
            if let uuid = descriptor.uuid {
                nextDescriptorsByUUID[uuid] = descriptor
            }
        }

        descriptors = nextDescriptors
        descriptorsByUUID = nextDescriptorsByUUID
    }

    func selectedDescriptor() -> IslandScreenDescriptor {
        selectedDescriptor(preferredUUID: IslandScreenResolver.preferredDisplayUUID())
    }

    func selectedDescriptor(preferredUUID: String?) -> IslandScreenDescriptor {
        IslandScreenResolver.selectDescriptor(
            preferredUUID: preferredUUID,
            descriptors: descriptors,
            placement: IslandSystemIslandPlacement.current(),
            reservedWidth: IslandSystemIslandPlacement.reservedWidth()
        )
    }
}
