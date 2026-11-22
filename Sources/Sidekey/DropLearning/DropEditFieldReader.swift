import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The field a take is pasted into, captured at the paste boundary, right
/// before Cmd+V.
struct DropEditFieldHandle {
    let pid: pid_t
    let element: AXUIElement
}

/// Captures, watches and reads the field a take went into. Every check runs
/// on the field's identity and security metadata before its text is touched;
/// each read is a range bounded by the length the field reports, only from the
/// element that still has keyboard focus. Reads stay in memory; nothing is
/// logged.
@MainActor
protocol DropEditFieldAccess: AnyObject {
    /// The focused field of the frontmost target app, if the gate allows it.
    /// Reads no text.
    func capture(pid: pid_t) -> DropEditFieldHandle?
    /// Why the last capture returned nil, as a fixed name.
    var lastRefusal: String? { get }
    /// The same element still has keyboard focus and is still allowed.
    func isStillFocused(_ handle: DropEditFieldHandle) -> Bool
    /// The field's text; `.focusLeft` when keyboard focus verifiably moved
    /// away (another element or app, the app quit); `.unreadable` when the
    /// same field is still focused but cannot be read now (an AX failure,
    /// changed security metadata, a field over the transfer bound).
    func read(_ handle: DropEditFieldHandle) -> DropEditFieldRead
    /// Tells when the field's value changes, when focus leaves it and when it
    /// goes away. Carries no text. nil when the app offers no notifications:
    /// the observation then polls.
    func watch(_ handle: DropEditFieldHandle,
               onChange: @escaping @MainActor (DropEditFieldChange) -> Void) -> DropEditFieldWatch?
    /// Electron and Chromium apps build their accessibility tree only on
    /// request. When the target app's focused element is not a readable field,
    /// asks that app (only it) to expose its fields; the lease undoes it.
    func exposeFields(pid: pid_t) -> DropEditAccessibilityLease?
}

extension DropEditFieldAccess {
    var lastRefusal: String? { nil }
}

enum DropEditFieldRead: Equatable {
    /// The field's text and, when the field reports it, the end of its
    /// selection (the caret, UTF-16 offset): right after a paste it sits at
    /// the end of the pasted text.
    case text(String, caret: Int? = nil)
    case focusLeft
    case unreadable
}

/// The system-wide focus lookup, with a confirmed absence told apart from a
/// failed query (timeout, IPC error).
enum DropEditFocus {
    case element(AXUIElement)
    case none
    case failed
}

enum DropEditFieldChange: Equatable {
    case value
    case focusLeft
    case removed
}

@MainActor
protocol DropEditFieldWatch: AnyObject {
    func cancel()
}

/// Undoes what `exposeFields` turned on. Releasing twice does nothing.
@MainActor
final class DropEditAccessibilityLease {
    let pid: pid_t
    private var undo: (() -> Void)?

    init(pid: pid_t, undo: @escaping () -> Void) {
        self.pid = pid
        self.undo = undo
    }

    func release() {
        undo?()
        undo = nil
    }
}

/// Upper bound on a field's text the learning step reads (UTF-16 units).
enum DropEditFieldLimits {
    static let maxFieldLength = 20_000
}

@MainActor
final class AXDropEditFieldAccess: DropEditFieldAccess {
    nonisolated static let messagingTimeout: Float = 0.25

    /// The Accessibility and workspace calls the access makes; tests replace
    /// them. Each returns nil on any failure.
    struct System {
        var frontmostPID: () -> pid_t?
        /// The system-wide focused element (keyboard focus).
        var focusedElement: () -> AXUIElement?
        var elementPID: (AXUIElement) -> pid_t?
        var isRunning: (pid_t) -> Bool
        /// Identity and security metadata only: never the field's text.
        var facts: (AXUIElement, pid_t) -> DropEditFieldFacts
        /// `AXNumberOfCharacters`; nil when the field does not report it.
        var characterCount: (AXUIElement) -> Int?
        /// `AXStringForRange`: transfers only the requested range.
        var string: (AXUIElement, CFRange) -> String?
        /// `AXSelectedTextRange`; nil when the field does not report it.
        var selection: ((AXUIElement) -> CFRange?)? = nil
        /// A Boolean attribute of the app element; nil when it cannot be read.
        var appFlag: (pid_t, String) -> Bool?
        /// Sets a Boolean attribute of the app element; true on success.
        var setAppFlag: (pid_t, String, Bool) -> Bool
        /// The running process behind a pid (bundle and launch time); nil
        /// when none runs. A reused pid gives a different identity.
        var processIdentity: (pid_t) -> String?
        /// AX notifications on the field (value, removal) and on its app (focus).
        var watch: @MainActor (DropEditFieldHandle, @escaping @MainActor (DropEditFieldChange) -> Void) -> DropEditFieldWatch?
        /// The focus lookup with a failed query told apart from no focused
        /// element. Without it, `focusedElement` nil counts as none.
        var focus: (() -> DropEditFocus)? = nil
        /// Secure event input right now, without an AX call (it cannot
        /// block). Without it, the app element's metadata is asked.
        var secureInput: (() -> Bool)? = nil
    }

    /// Electron answers `AXManualAccessibility`; Chromium browsers and other
    /// web views `AXEnhancedUserInterface`. Tried in this order.
    static let exposeAttributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]

    private let system: System

    init(system: System = .live) { self.system = system }

    private(set) var lastRefusal: String?

    func capture(pid: pid_t) -> DropEditFieldHandle? {
        lastRefusal = nil
        guard system.frontmostPID() == pid else { lastRefusal = "notFrontmost"; return nil }
        let element: AXUIElement
        switch lookupFocus() {
        case .failed: lastRefusal = "axError"; return nil
        case .none: lastRefusal = "noFocusedElement"; return nil
        case .element(let focused):
            guard system.elementPID(focused) == pid, system.frontmostPID() == pid else {
                lastRefusal = "focusInOtherApp"
                return nil
            }
            element = focused
        }
        if let refusal = DropEditFieldGate.refusal(system.facts(element, pid)) {
            lastRefusal = refusal
            return nil
        }
        return DropEditFieldHandle(pid: pid, element: element)
    }

    /// The same element still has keyboard focus: its app is frontmost, the
    /// system-wide focused element is that element, and the gate still allows
    /// it. An app keeps its own focused element while another app is in
    /// front, so that alone is not focus.
    func isStillFocused(_ handle: DropEditFieldHandle) -> Bool {
        stop(handle) == nil
    }

    /// Why the field may not be read now, or nil when it may. The gate's
    /// metadata calls can block; focus is confirmed both before and after
    /// them, so the last thing checked is keyboard focus.
    private func stop(_ handle: DropEditFieldHandle) -> DropEditFieldRead? {
        if let lost = focusLoss(handle) { return lost }
        let gate = allowed(handle.element, pid: handle.pid)
        if let lost = focusLoss(handle) { return lost }
        return gate ? nil : .unreadable
    }

    /// nil while the field has keyboard focus. Focus left only when that is
    /// verified: the process is gone, another app is in front, or another
    /// element has focus. A lookup that fails or reports no focused element
    /// proves nothing, so it is unreadable and the kept text is dropped.
    private func focusLoss(_ handle: DropEditFieldHandle) -> DropEditFieldRead? {
        guard system.isRunning(handle.pid) else { return .focusLeft }
        guard let front = system.frontmostPID() else { return .unreadable }
        guard front == handle.pid else { return .focusLeft }
        switch lookupFocus() {
        case .element(let current): return CFEqual(current, handle.element) ? nil : .focusLeft
        case .none, .failed: return .unreadable
        }
    }

    private func lookupFocus() -> DropEditFocus {
        if let focus = system.focus { return focus() }
        return system.focusedElement().map { .element($0) } ?? .none
    }

    // WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
    func read(_ handle: DropEditFieldHandle) -> DropEditFieldRead {
        if let stop = stop(handle) { return stop }
        // The transfer is bounded before it happens: the field must report
        // its length, and only that range is requested. A field that does
        // not report it, or cannot return a range, is not read at all.
        guard let length = system.characterCount(handle.element),
              length >= 0, length <= DropEditFieldLimits.maxFieldLength else { return stop(handle) ?? .unreadable }
        // The length query can block; focus may move meanwhile. Confirm
        // keyboard focus and the gate again right before the transfer.
        if let stop = stop(handle) { return stop }
        if length == 0 { return .text("") }
        guard let text = system.string(handle.element, CFRange(location: 0, length: length)),
              (text as NSString).length <= DropEditFieldLimits.maxFieldLength
        else { return stop(handle) ?? .unreadable }
        // Where the caret is tells a new paste from an identical older draft.
        // Only a collapsed selection (a caret, no selected text) inside the
        // text counts.
        let caret = system.selection?(handle.element).flatMap { range -> Int? in
            range.length == 0 && range.location >= 0 && range.location <= (text as NSString).length
                ? range.location : nil
        }
        // A field that lost focus during the transfer is not used.
        if let stop = stop(handle) { return stop }
        return .text(text, caret: caret)
    }

    func watch(_ handle: DropEditFieldHandle,
               onChange: @escaping @MainActor (DropEditFieldChange) -> Void) -> DropEditFieldWatch? {
        system.watch(handle, onChange)
    }

    // WHY: .project-docs/decisions/2026-11-22-drop-edit-observation.md
    func exposeFields(pid: pid_t) -> DropEditAccessibilityLease? {
        guard let approved = exposureTarget(pid) else { return nil }
        for attribute in Self.exposeAttributes {
            // Only an attribute known to be off. One already on (VoiceOver,
            // the user, another tool) stays theirs; one that cannot be read
            // is never changed, so there is no guessed value to restore.
            guard system.appFlag(pid, attribute) == false else { continue }
            // The flag read can block: the approval is taken again from
            // scratch (process, focus, gate, front) and must be the same.
            // That pass blocks too, so the flag must still read off (another
            // client may have turned it on: then it is theirs) and the same
            // focus, process and front app are confirmed once more, last.
            guard let now = exposureTarget(pid), now.same(as: approved),
                  system.appFlag(pid, attribute) == false,
                  stillHolds(approved, pid: pid) else { return nil }
            guard system.setAppFlag(pid, attribute, true) else { continue }
            // Electron accepts the request and turns its tree on a moment
            // later; until then the attribute still reads off.
            let seenOn = system.appFlag(pid, attribute) == true
            let identity = approved.identity
            return DropEditAccessibilityLease(pid: pid) { [system] in
                // Undone only for the same process, checked again after the
                // blocking read, and only while the value is still Whytap's:
                // on, or an accepted enable that was never seen applied
                // (writing off cancels it). Off after it was on means someone
                // else turned it off; unreadable means unknown. Both stay.
                guard system.processIdentity(pid) == identity else { return }
                let value = system.appFlag(pid, attribute)
                guard system.processIdentity(pid) == identity else { return }
                guard value == true || (value == false && !seenOn) else { return }
                _ = system.setAppFlag(pid, attribute, false)
            }
        }
        return nil
    }

    /// What the exposure approval rests on: the frontmost process and its
    /// focused element, or a confirmed absence of one (nil).
    private struct ExposureTarget {
        let identity: String
        let focused: AXUIElement?

        func same(as other: ExposureTarget) -> Bool {
            guard identity == other.identity else { return false }
            switch (focused, other.focused) {
            case (nil, nil): return true
            case let (a?, b?): return CFEqual(a, b)
            default: return false
            }
        }
    }

    /// The focus of `pid` for exposure: `.some(element)`, `.some(nil)` for a
    /// confirmed absence (Electron before its tree is on reports none), or
    /// nil when the lookup failed or focus is in another process. A failed
    /// lookup is never taken as "no field".
    private func exposureFocus(_ pid: pid_t) -> AXUIElement?? {
        switch lookupFocus() {
        case .failed: return nil
        case .none: return .some(nil)
        case .element(let element): return system.elementPID(element) == pid ? .some(element) : nil
        }
    }

    /// Focus (element or confirmed absence), process, front app and no
    /// secure input, checked in that order: the focus lookup is the last
    /// blocking AX call, and the checks after it cannot block.
    private func stillHolds(_ target: ExposureTarget, pid: pid_t) -> Bool {
        guard let focused = exposureFocus(pid),
              ExposureTarget(identity: target.identity, focused: focused).same(as: target) else { return false }
        return system.processIdentity(pid) == target.identity && system.frontmostPID() == pid
            && !secureInputActive(pid)
    }

    private func secureInputActive(_ pid: pid_t) -> Bool {
        if let secureInput = system.secureInput { return secureInput() }
        return system.facts(AXUIElementCreateApplication(pid), pid).secureEventInput
    }

    /// nil unless every check passes. The metadata query blocks, so focus,
    /// process and the front app are confirmed again after it.
    private func exposureTarget(_ pid: pid_t) -> ExposureTarget? {
        guard system.frontmostPID() == pid, let identity = system.processIdentity(pid),
              let focused = exposureFocus(pid) else { return nil }
        let facts = system.facts(focused ?? AXUIElementCreateApplication(pid), pid)
        // A readable field needs nothing; a field the gate refuses for its
        // app, a password, secure input or an error never gets the app's
        // tree turned on.
        if DropEditFieldGate.allowsRead(facts) { return nil }
        guard DropEditFieldGate.mayExpose(facts) else { return nil }
        let target = ExposureTarget(identity: identity, focused: focused)
        return stillHolds(target, pid: pid) ? target : nil
    }

    /// The system-wide focused element, only when it belongs to `pid` and
    /// that app is frontmost: the element that has keyboard focus now.
    private func focusedElement(ofFrontmost pid: pid_t) -> AXUIElement? {
        guard system.frontmostPID() == pid, case .element(let element) = lookupFocus(),
              system.elementPID(element) == pid else { return nil }
        return element
    }

    private func allowed(_ element: AXUIElement, pid: pid_t) -> Bool {
        DropEditFieldGate.allowsRead(system.facts(element, pid))
    }
}

extension AXDropEditFieldAccess.System {
    static var live: Self {
        Self(
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            focusedElement: {
                if case .element(let element) = liveFocus() { return element }
                return nil
            },
            elementPID: { element in
                var owner: pid_t = 0
                return AXUIElementGetPid(element, &owner) == .success ? owner : nil
            },
            isRunning: { NSRunningApplication(processIdentifier: $0)?.isTerminated == false },
            facts: { element, pid in
                let role = metadata(element, kAXRoleAttribute as CFString)
                let subrole = metadata(element, kAXSubroleAttribute as CFString)
                return DropEditFieldFacts(
                    bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                    isOwnProcess: pid == ProcessInfo.processInfo.processIdentifier,
                    role: role.value,
                    subrole: subrole.value,
                    secureEventInput: IsSecureEventInputEnabled(),
                    accessibilityError: role.failed || subrole.failed
                )
            },
            characterCount: { element in
                var count: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success
                else { return nil }
                return count as? Int
            },
            string: { element, range in
                var range = range
                guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
                ) == .success else { return nil }
                return value as? String
            },
            selection: { element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
                var range = CFRange()
                guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
                return range
            },
            appFlag: { pid, attribute in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement(pid), attribute as CFString, &value) == .success
                else { return nil }
                return (value as? NSNumber)?.boolValue
            },
            setAppFlag: { pid, attribute, flag in
                AXUIElementSetAttributeValue(appElement(pid), attribute as CFString,
                                             (flag ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
            },
            processIdentity: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
                return "\(app.bundleIdentifier ?? "-")@\(app.launchDate?.timeIntervalSince1970 ?? 0)"
            },
            watch: { handle, onChange in AXDropEditFieldWatch(handle: handle, onChange: onChange) },
            focus: liveFocus,
            secureInput: { IsSecureEventInputEnabled() }
        )
    }

    private static func liveFocus() -> DropEditFocus {
        let systemWide = AXUIElementCreateSystemWide()
        // A busy app must not stall the main thread for AX's default 6 s.
        AXUIElementSetMessagingTimeout(systemWide, AXDropEditFieldAccess.messagingTimeout)
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) {
        case .success:
            guard let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .failed }
            let element = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(element, AXDropEditFieldAccess.messagingTimeout)
            return .element(element)
        case .noValue: return .none
        default: return .failed
        }
    }

    private static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXDropEditFieldAccess.messagingTimeout)
        return app
    }

    /// A string attribute; an attribute the element does not have is nil,
    /// any other AX failure (IPC, timeout) is an error and fails the gate.
    private static func metadata(_ element: AXUIElement, _ name: CFString) -> (value: String?, failed: Bool) {
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name, &ref) {
        case .success: return (ref as? String, false)
        case .noValue, .attributeUnsupported: return (nil, false)
        default: return (nil, true)
        }
    }
}

/// AX notifications for one field: its value changed, it was removed, or the
/// app's focused element changed. Runs on the main run loop; no text travels
/// with a notification.
@MainActor
final class AXDropEditFieldWatch: DropEditFieldWatch {
    private final class Sink {
        let onChange: @MainActor (DropEditFieldChange) -> Void
        init(_ onChange: @escaping @MainActor (DropEditFieldChange) -> Void) { self.onChange = onChange }
    }

    private var observer: AXObserver?
    private let sink: Sink
    private let field: AXUIElement
    private let app: AXUIElement

    init?(handle: DropEditFieldHandle, onChange: @escaping @MainActor (DropEditFieldChange) -> Void) {
        sink = Sink(onChange)
        field = handle.element
        app = AXUIElementCreateApplication(handle.pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let sink = Unmanaged<Sink>.fromOpaque(refcon).takeUnretainedValue()
            let change: DropEditFieldChange
            switch notification as String {
            case kAXValueChangedNotification: change = .value
            case kAXUIElementDestroyedNotification: change = .removed
            default: change = .focusLeft
            }
            MainActor.assumeIsolated { sink.onChange(change) }
        }
        guard AXObserverCreate(handle.pid, callback, &created) == .success, let created else { return nil }
        let refcon = Unmanaged.passUnretained(sink).toOpaque()
        let added = [
            AXObserverAddNotification(created, field, kAXValueChangedNotification as CFString, refcon),
            AXObserverAddNotification(created, field, kAXUIElementDestroyedNotification as CFString, refcon),
            AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, refcon),
        ]
        // Without value notifications the observation only polls.
        guard added[0] == .success else {
            Self.remove(created, field: field, app: app)
            return nil
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    func cancel() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        Self.remove(observer, field: field, app: app)
        self.observer = nil
    }

    private static func remove(_ observer: AXObserver, field: AXUIElement, app: AXUIElement) {
        AXObserverRemoveNotification(observer, field, kAXValueChangedNotification as CFString)
        AXObserverRemoveNotification(observer, field, kAXUIElementDestroyedNotification as CFString)
        AXObserverRemoveNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString)
    }
}
