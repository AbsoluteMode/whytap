import AppKit
import Darwin

/// Backlight levels are 0...1. Extra brightness scales the display's transfer table
/// into the EDR headroom on top of the current backlight level.
enum ScreenBrightnessScale {
    /// Vivid's table factor on the same XDR panel at its SDR maximum (measured 2026-10-19).
    static let maximumExtraGamma = 1.45
    /// A hardware level at or above this counts as the Mac's own maximum.
    static let hardwareMaximum = 0.99

    static func clampedLevel(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), 1)
    }

    /// The table scales encoded values and sRGB's curve turns them into light, so the
    /// factor stops where the boosted white reaches the current headroom.
    static func extraGammaFactor(currentHeadroom: Double) -> Double {
        guard currentHeadroom.isFinite, currentHeadroom > 1 else { return 1 }
        return min(maximumExtraGamma, 1.055 * pow(currentHeadroom, 1 / 2.4) - 0.055)
    }
}

struct ScreenBrightnessDisplay: Equatable {
    let id: CGDirectDisplayID
    /// `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue`.
    let potentialHeadroom: Double
    var supportsExtra: Bool { potentialHeadroom > 1.01 }
}

enum BrightnessBoostEnd: Equatable {
    case unavailable
    /// Another app wrote the display's table.
    case otherApp
}

@MainActor
protocol BrightnessBoost: AnyObject {
    /// Follows the display after a configuration change.
    func refresh()
    /// Gives the display its own table back.
    func close()
}

@MainActor
protocol ScreenBrightnessDevice {
    func displays() -> [ScreenBrightnessDisplay]
    func read(_ id: CGDirectDisplayID) -> Double?
    func write(_ level: Double, to id: CGDirectDisplayID) -> Bool
    func makeBoost(for id: CGDirectDisplayID, onEnd: @escaping (BrightnessBoostEnd) -> Void) -> BrightnessBoost?
}

/// Hover Display: the island display's backlight plus an Extra switch.
/// Extra is a fixed EDR boost of the display's transfer table on top of whatever the
/// backlight is, and it never writes the backlight itself. The first manual decrease only
/// ends Extra; the next adjustment lowers the backlight. External changes keep Extra,
/// including automatic brightness and battery dimming while the strip is closed. Increasing the backlight
/// does not enable Extra. The switch, heat, a display change or lost EDR support, another
/// app adjusting the display's table, a boost failure and quit also end it.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class ScreenBrightnessController: ObservableObject {
    static let shared = ScreenBrightnessController()

    /// Each notice fits one status line of the narrowest (310 pt) island.
    static let writeFailedNotice = "Couldn't change this display's brightness."
    static let extraUnavailableNotice = "Extra brightness isn't available right now."
    static let coolingNotice = "Extra is paused while your Mac cools down."
    static let otherAppNotice = "Another app is adjusting this display."
    /// A read right after a write can still report the previous backlight level.
    static let writeSettleInterval: TimeInterval = 0.75
    /// DisplayServices reads Float values; their round-off is not a brightness decrease.
    static let levelReadbackTolerance = 0.000001

    @Published private(set) var level = 0.0
    @Published private(set) var isExtraOn = false
    @Published private(set) var display: ScreenBrightnessDisplay?
    @Published private(set) var isAvailable = false
    @Published private(set) var notice: String?
    /// Extra is offered next to a working slider only, so an unadjustable display has neither.
    var supportsExtra: Bool { isAvailable && display?.supportsExtra == true }

    private let device: ScreenBrightnessDevice
    private let selectedDisplayID: @MainActor () -> CGDirectDisplayID?
    private let extraAllowed: () -> Bool
    private let now: () -> Date
    private var boost: BrightnessBoost?
    private var boostGeneration = 0
    /// A write settles only on its own display; another display's reading is current.
    private var lastWrite: (display: CGDirectDisplayID, date: Date)?
    private var timer: Timer?
    private var viewers = 0
    private var isDraggingLevel = false
    private var ignoresLevelDrag = false
    /// True while a visible strip or active Extra follows outside changes.
    var isPolling: Bool { timer != nil }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(device: ScreenBrightnessDevice? = nil,
         selectedDisplayID: @escaping @MainActor () -> CGDirectDisplayID? = {
             guard let uuid = IslandScreenResolver.currentDescriptor().uuid else { return nil }
             return NSScreen.screens.first { $0.sidekeyDisplayUUID == uuid }?.brightnessDisplayID
         },
         observeSystem: Bool = true,
         center: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         extraAllowed: @escaping () -> Bool = {
             let state = ProcessInfo.processInfo.thermalState
             return state != .serious && state != .critical
         },
         now: @escaping () -> Date = Date.init) {
        self.device = device ?? NativeScreenBrightnessDevice()
        self.selectedDisplayID = selectedDisplayID
        self.extraAllowed = extraAllowed
        self.now = now
        guard observeSystem else { return }
        let workspace = workspaceCenter
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.refresh() }
        observe(center, IslandScreenResolver.selectionDidChangeNotification) { $0.refresh() }
        // Wake reconciles the backlight too, without treating macOS dimming as a manual action.
        observe(workspace, NSWorkspace.didWakeNotification) { $0.refresh() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.refresh() }
        observe(center, ProcessInfo.thermalStateDidChangeNotification) { $0.thermalStateDidChange() }
    }

    /// The strip is visible: read the current level and follow outside changes.
    func beginInteraction() {
        viewers += 1
        refresh()
    }

    func endInteraction() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { endLevelDrag() }
        updatePolling()
    }

    func beginLevelDrag() {
        isDraggingLevel = true
        ignoresLevelDrag = false
    }

    func endLevelDrag() {
        isDraggingLevel = false
        ignoresLevelDrag = false
    }

    /// Assigns only changed values: `@Published` announces every assignment and
    /// the strip refreshes twice a second.
    func refresh() {
        let displays = device.displays()
        let selectedID = selectedDisplayID()
        let target = displays.first { $0.id == selectedID } ?? displays.first
        if display?.id != target?.id {
            endExtra()
            notice = nil
        }
        if display != target { display = target }
        guard let target, let hardware = device.read(target.id), hardware.isFinite else {
            endExtra()
            if isAvailable { isAvailable = false }
            if level != 0 { level = 0 }
            updatePolling()
            return
        }
        if !isAvailable { isAvailable = true }
        let current = ScreenBrightnessScale.clampedLevel(hardware)
        let settling = isSettling(target.id)
        if isExtraOn {
            // Readback has no intent: automatic dimming and native manual controls look
            // identical. Only our explicit slider/key actions consume Extra.
            if target.supportsExtra {
                boost?.refresh()
            } else {
                endExtra()
            }
        }
        if !settling, level != current { level = current }
        updatePolling()
    }

    /// The first manual decrease consumes Extra without writing the backlight. Keep the
    /// rest of that drag at the same level; another drag or accessibility action can lower it.
    func setLevel(_ requested: Double) {
        guard isAvailable, let display, !ignoresLevelDrag else { return }
        let next = ScreenBrightnessScale.clampedLevel(requested)
        if isExtraOn, requested.isFinite, requested < level - Self.levelReadbackTolerance {
            endExtra()
            notice = nil
            ignoresLevelDrag = isDraggingLevel
            return
        }
        guard write(next, to: display.id) else {
            refresh()
            notice = Self.writeFailedNotice
            return
        }
        notice = nil
        level = next
    }

    func setExtra(_ enabled: Bool) {
        if enabled { startExtra() } else { stopExtra() }
    }

    /// Ends Extra; the backlight stays where it is.
    func stopExtra(notice newNotice: String? = nil) {
        endExtra()
        if let newNotice { notice = newNotice }
        refresh()
    }

    /// Thermal pressure pauses an active Extra; with Extra off there is nothing to report.
    func thermalStateDidChange() {
        guard isExtraOn, !extraAllowed() else { return }
        stopExtra(notice: Self.coolingNotice)
    }

    func shutdown() {
        endExtra()
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func startExtra() {
        guard !isExtraOn else { return }
        // A closed strip may have an old reading. Start from the actual backlight so the
        // first poll does not mistake a decrease made before enabling Extra for a new one.
        refresh()
        guard isAvailable, let display, display.supportsExtra else { return }
        guard extraAllowed() else {
            notice = Self.coolingNotice
            return
        }
        let generation = boostGeneration
        guard let created = device.makeBoost(for: display.id, onEnd: { [weak self] end in
            // A late end from a closed boost must not end a newer Extra.
            guard let self, self.boostGeneration == generation else { return }
            self.stopExtra(notice: end == .otherApp ? Self.otherAppNotice : Self.extraUnavailableNotice)
        }) else {
            notice = Self.extraUnavailableNotice
            return
        }
        boost = created
        isExtraOn = true
        notice = nil
        updatePolling()
    }

    private func endExtra() {
        boostGeneration += 1
        boost?.close()
        boost = nil
        guard isExtraOn else { return }
        isExtraOn = false
        updatePolling()
    }

    private func write(_ value: Double, to id: CGDirectDisplayID) -> Bool {
        guard device.write(value, to: id) else { return false }
        lastWrite = (id, now())
        return true
    }

    private func isSettling(_ id: CGDirectDisplayID) -> Bool {
        lastWrite.map { $0.display == id && now().timeIntervalSince($0.date) < Self.writeSettleInterval } ?? false
    }

    /// Extra follows backlight and display support even with the strip closed.
    /// Stop polling once neither Extra nor a strip needs it.
    private func updatePolling() {
        guard viewers > 0 || isExtraOn else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (ScreenBrightnessController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
}

extension NSScreen {
    var brightnessDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// macOS has no public backlight API for Apple displays. Resolve DisplayServices
/// optionally; displays it cannot read get a disabled control.
@MainActor
final class NativeScreenBrightnessDevice: ScreenBrightnessDevice {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        self.library = library
        getBrightness = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightness.self) }
        setBrightness = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightness.self) }
    }

    func displays() -> [ScreenBrightnessDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.brightnessDisplayID else { return nil }
            return ScreenBrightnessDisplay(
                id: id,
                potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        }
    }

    func read(_ id: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let getBrightness, setBrightness != nil, getBrightness(id, &value) == 0 else { return nil }
        return Double(value)
    }

    func write(_ level: Double, to id: CGDirectDisplayID) -> Bool {
        setBrightness?(id, Float(level)) == 0
    }

    func makeBoost(for id: CGDirectDisplayID, onEnd: @escaping (BrightnessBoostEnd) -> Void) -> BrightnessBoost? {
        NativeBrightnessBoost(display: id, onEnd: onEnd)
    }

    deinit { if let library { dlclose(library) } }
}
