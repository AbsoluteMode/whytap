import AppKit
import Carbon.HIToolbox
import Foundation
import os.log

/// Global hotkey monitor that fires `onHotkey` when Option + `/` is pressed.
///
/// Built on Carbon `RegisterEventHotKey`. The kernel routes the keystroke to
/// the registering application before the focused app sees it, so the `/` (or
/// Option-`/` = `÷`) keystroke is suppressed automatically without any
/// "consume" hook — this is the canonical macOS API used by Spectacle,
/// Rectangle, Alfred and friends.
///
/// Carbon registration itself needs no keyboard-observation grant. Drop keeps
/// tap shortcuts registered when Accessibility is missing so invocation can
/// explain the grant required for automatic paste. Hold gestures use an active
/// CGEventTap instead and have their own permission/recovery path.
///
/// `optionKey` is the Carbon modifier mask — it matches both Left and Right
/// Option. The left/right Option distinction is intentionally dropped (the
/// Carbon API exposes only side-agnostic modifier bits).
final class CarbonHotkeyMonitor {
    typealias Callback = () -> Void
    /// Stage 4: optional gate evaluated on every hotkey fire BEFORE the
    /// callback dispatches. Returning `true` silently drops the hotkey;
    /// returning `false` lets it through. Production wiring (drop
    /// hotkey only) plugs this to `AppState.shared.isMeetingRecording`
    /// so Option+/ cannot start dictation while the meeting recorder
    /// owns the mic. Default `nil` = always dispatch (no guard).
    typealias SuppressionGate = () -> Bool
    typealias RegisterHotKey = (
        _ inHotKeyCode: UInt32,
        _ inHotKeyModifiers: UInt32,
        _ inHotKeyID: EventHotKeyID,
        _ inTarget: EventTargetRef?,
        _ inOptions: OptionBits,
        _ outRef: UnsafeMutablePointer<EventHotKeyRef?>?
    ) -> OSStatus
    typealias UnregisterHotKey = (_ inHotKey: EventHotKeyRef) -> OSStatus
    typealias InstallHandler = (
        _ inTarget: EventTargetRef?,
        _ inHandler: EventHandlerUPP?,
        _ inNumTypes: Int,
        _ inList: UnsafePointer<EventTypeSpec>?,
        _ inUserData: UnsafeMutableRawPointer?,
        _ outRef: UnsafeMutablePointer<EventHandlerRef?>?
    ) -> OSStatus
    typealias RemoveHandler = (_ inHandlerRef: EventHandlerRef) -> OSStatus
    typealias DispatchFn = (@escaping () -> Void) -> Void

    /// kVK_ANSI_Slash from Carbon HIToolbox/Events.h. Drop-hotkey key code.
    static let slashKeyCode: UInt32 = 44
    /// kVK_ANSI_H. Help-hotkey key code.
    static let hKeyCode: UInt32 = 4
    /// kVK_ANSI_Q. Response-panel close hotkey key code.
    static let qKeyCode: UInt32 = 12
    /// kVK_LeftArrow / kVK_RightArrow / kVK_UpArrow / kVK_DownArrow from
    /// Carbon HIToolbox/Events.h. Used by the useful_links rolling-hint
    /// chip for ⌥ ←/→/↑/↓ selection nav while a useful_links block is
    /// visible in the response panel.
    static let leftArrowKeyCode: UInt32 = 0x7B
    static let rightArrowKeyCode: UInt32 = 0x7C
    static let downArrowKeyCode: UInt32 = 0x7D
    static let upArrowKeyCode: UInt32 = 0x7E
    /// Side-agnostic Option modifier — both left and right Option match.
    static let optionModifier: UInt32 = UInt32(optionKey)

    /// Four-char-code signature so handlers can tell our registration apart
    /// from other Carbon hot-key registrations in the same process.
    static let signature: OSType = OSType(0x53444B59) // 'SDKY'
    /// Distinct id-values per registered hotkey instance — Carbon uses
    /// `(signature, id)` to route HotKey events to the right handler.
    static let dropHotKeyID: UInt32 = 1
    static let helpHotKeyID: UInt32 = 2
    static let responseCloseHotKeyID: UInt32 = 3
    /// Useful Links selection hotkeys. Reserved as a contiguous block so a
    /// future reshuffling of (signature, id) pairs keeps the family clear.
    /// Insert and Open are always registered together; Down/Up are
    /// registered only when the visible useful_links block has at least
    /// 2 links (single-link blocks don't need vertical nav).
    static let usefulLinksInsertHotKeyID: UInt32 = 4
    static let usefulLinksOpenHotKeyID: UInt32 = 5
    static let usefulLinksDownHotKeyID: UInt32 = 6
    static let usefulLinksUpHotKeyID: UInt32 = 7
    // ID 8 retired with the fixed History shortcut.
    // ID 9 retired twice: first with the ROO-208 trio, then as the bare-Escape
    // close hotkey — the answer uses a scoped `EscapeCloseEventMonitor`
    // session tap instead of a Carbon bare-Escape registration.
    // ID 10 retired with the ROO-208 trio.
    // WHY: docs/decisions/2026-10-23-agent-answer-escape-consumption.md
    static let agentTextHotKeyID: UInt32 = 11
    static let agentVoiceHotKeyID: UInt32 = 12
    /// Feature monitors use a separate ID range; legacy slot IDs 13...17 are retired.
    static let toolHotKeyIDBase: UInt32 = 100

    static let meetingRecordHotKeyID: UInt32 = 18
    /// Google search's text and voice shortcuts when they are key combos.
    static let googleTextHotKeyID: UInt32 = 19
    static let googleVoiceHotKeyID: UInt32 = 20

    /// kVK_Escape from Carbon HIToolbox/Events.h. Consumed by
    /// `EscapeCloseEventMonitor`'s bare-Escape predicate.
    static let escapeKeyCode: UInt32 = 53

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey")

    let onHotkey: Callback
    let onHotkeyReleased: Callback?

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let hotKeyIDValue: UInt32
    private let registerHotKey: RegisterHotKey
    private let unregisterHotKey: UnregisterHotKey
    private let installHandler: InstallHandler
    private let removeHandler: RemoveHandler
    private let dispatchOnMain: DispatchFn
    private let shouldSuppress: SuppressionGate?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    convenience init(
        onHotkey: @escaping Callback,
        onHotkeyReleased: Callback? = nil,
        shouldSuppress: SuppressionGate? = nil
    ) {
        self.init(
            keyCode: Self.slashKeyCode,
            modifiers: UInt32(optionKey),
            hotKeyIDValue: Self.dropHotKeyID,
            onHotkey: onHotkey,
            onHotkeyReleased: onHotkeyReleased,
            shouldSuppress: shouldSuppress
        )
    }

    convenience init(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyIDValue: UInt32,
        onHotkey: @escaping Callback,
        onHotkeyReleased: Callback? = nil,
        shouldSuppress: SuppressionGate? = nil
    ) {
        self.init(
            keyCode: keyCode,
            modifiers: modifiers,
            hotKeyIDValue: hotKeyIDValue,
            onHotkey: onHotkey,
            onHotkeyReleased: onHotkeyReleased,
            registerHotKey: RegisterEventHotKey,
            unregisterHotKey: UnregisterEventHotKey,
            installHandler: InstallEventHandler,
            removeHandler: RemoveEventHandler,
            dispatchOnMain: { work in DispatchQueue.main.async(execute: work) },
            shouldSuppress: shouldSuppress
        )
    }

    /// DI convenience that defaults to the drop hot-key combo (Option + `/`).
    /// Keeps existing tests that were written before the hot-key
    /// parameterization compiling without touching every test file.
    convenience init(
        onHotkey: @escaping Callback,
        onHotkeyReleased: Callback? = nil,
        registerHotKey: @escaping RegisterHotKey,
        unregisterHotKey: @escaping UnregisterHotKey,
        installHandler: @escaping InstallHandler,
        removeHandler: @escaping RemoveHandler,
        dispatchOnMain: @escaping DispatchFn,
        shouldSuppress: SuppressionGate? = nil
    ) {
        self.init(
            keyCode: Self.slashKeyCode,
            modifiers: UInt32(optionKey),
            hotKeyIDValue: Self.dropHotKeyID,
            onHotkey: onHotkey,
            onHotkeyReleased: onHotkeyReleased,
            registerHotKey: registerHotKey,
            unregisterHotKey: unregisterHotKey,
            installHandler: installHandler,
            removeHandler: removeHandler,
            dispatchOnMain: dispatchOnMain,
            shouldSuppress: shouldSuppress
        )
    }

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyIDValue: UInt32,
        onHotkey: @escaping Callback,
        onHotkeyReleased: Callback? = nil,
        registerHotKey: @escaping RegisterHotKey,
        unregisterHotKey: @escaping UnregisterHotKey,
        installHandler: @escaping InstallHandler,
        removeHandler: @escaping RemoveHandler,
        dispatchOnMain: @escaping DispatchFn,
        shouldSuppress: SuppressionGate? = nil
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hotKeyIDValue = hotKeyIDValue
        self.onHotkey = onHotkey
        self.onHotkeyReleased = onHotkeyReleased
        self.registerHotKey = registerHotKey
        self.unregisterHotKey = unregisterHotKey
        self.installHandler = installHandler
        self.removeHandler = removeHandler
        self.dispatchOnMain = dispatchOnMain
        self.shouldSuppress = shouldSuppress
    }

    deinit {
        stop()
    }

    func start() throws {
        stop()

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
        ]
        if onHotkeyReleased != nil {
            eventTypes.append(EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ))
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        var newHandler: EventHandlerRef?
        let installStatus = installHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            eventTypes.count,
            &eventTypes,
            userInfo,
            &newHandler
        )
        guard installStatus == noErr else {
            os_log(
                "register_failed install=%{public}d",
                log: Self.log, type: .error,
                Int(installStatus)
            )
            throw HotkeyRegistrationError.carbonHandler(installStatus)
        }
        self.handlerRef = newHandler

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: self.hotKeyIDValue)
        var newHotKey: EventHotKeyRef?
        let registerStatus = registerHotKey(
            self.keyCode,
            self.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKey
        )
        guard registerStatus == noErr else {
            os_log(
                "register_failed register=%{public}d",
                log: Self.log, type: .error,
                Int(registerStatus)
            )
            if let handlerRef = self.handlerRef {
                _ = removeHandler(handlerRef)
                self.handlerRef = nil
            }
            throw HotkeyRegistrationError.carbonRegistration(registerStatus)
        }
        self.hotKeyRef = newHotKey

        os_log("tap_registered", log: Self.log, type: .info)
    }

    func stop() {
        if let hotKeyRef = self.hotKeyRef {
            _ = unregisterHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef = self.handlerRef {
            _ = removeHandler(handlerRef)
            self.handlerRef = nil
        }
        os_log("tap_unregistered", log: Self.log, type: .info)
    }

    /// Called by the Carbon event handler when our hot key fires. Internal
    /// so unit tests can exercise the dispatch path without standing up a
    /// real Carbon event loop.
    ///
    /// Stage 4: a `shouldSuppress` gate evaluated here silently drops the
    /// hotkey before dispatch. Wired by `AppDelegate` to the meetings
    /// coordinator's `isMeetingRecording` flag so Option+/ cannot start
    /// dictation while a meeting recorder owns the mic.
    func handleHotKeyEvent() {
        // The key arrived, so the Secure Input indicator must not blame
        // anyone for this press, even when the gate drops it.
        // WHY: .project-docs/decisions/2026-11-26-secure-input-holder.md
        HotkeyFireRecorder.noteFired()
        if shouldSuppress?() == true {
            os_log("hotkey suppressed", log: Self.log, type: .info)
            return
        }
        let callback = self.onHotkey
        dispatchOnMain {
            callback()
        }
    }

    func handleHotKeyReleaseEvent() {
        guard let callback = onHotkeyReleased else { return }
        dispatchOnMain {
            callback()
        }
    }

    /// C-compatible event handler. Cannot capture state, so the monitor
    /// reference is smuggled in via `inUserData` and unmanaged.
    ///
    /// Carbon delivers every registered hot-key event to every installed
    /// handler on the same EventTarget — so without filtering by
    /// `EventHotKeyID` here the drop-hotkey monitor would also fire for
    /// `⌥H` (and vice versa). We pull the `EventHotKeyID` out of the
    /// event and only forward when it matches *this* monitor's
    /// `(signature, id)` pair.
    private static let eventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let userData, let eventRef else { return noErr }
        let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        // Return `eventNotHandledErr` for events that don't match this
        // monitor's hot-key ID — Carbon installs handlers in a chain on
        // the same EventTarget, and returning `noErr` consumes the event
        // before the next handler sees it. Without this, two monitors
        // sharing one target only deliver to the first registered one.
        guard status == noErr,
              hotKeyID.signature == CarbonHotkeyMonitor.signature,
              hotKeyID.id == monitor.hotKeyIDValue else {
            return OSStatus(eventNotHandledErr)
        }

        switch GetEventKind(eventRef) {
        case UInt32(kEventHotKeyReleased):
            monitor.handleHotKeyReleaseEvent()
        default:
            monitor.handleHotKeyEvent()
        }
        return noErr
    }
}
