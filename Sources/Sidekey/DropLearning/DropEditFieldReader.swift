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

enum DropEditFieldRead: Equatable {
    case text(String)
    case focusLeft
    case unreadable
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
        /// A Boolean attribute of the app element; nil when it cannot be read.
        var appFlag: (pid_t, String) -> Bool?
        /// Sets a Boolean attribute of the app element; true on success.
        var setAppFlag: (pid_t, String, Bool) -> Bool
        /// The running process behind a pid (bundle and launch time); nil
        /// when none runs. A reused pid gives a different identity.
        var processIdentity: (pid_t) -> String?
        /// AX notifications on the field (value, removal) and on its app (focus).
        var watch: @MainActor (DropEditFieldHandle, @escaping @MainActor (DropEditFieldChange) -> Void) -> DropEditFieldWatch?
    }

    /// Electron answers `AXManualAccessibility`; Chromium browsers and other
    /// web views `AXEnhancedUserInterface`. Tried in this order.
    static let exposeAttributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]

    private let system: System

    init(system: System = .live) { self.system = system }

    func capture(pid: pid_t) -> DropEditFieldHandle? {
        guard let element = focusedElement(ofFrontmost: pid), allowed(element, pid: pid) else { return nil }
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
        guard system.isRunning(handle.pid), hasFocus(handle) else { return .focusLeft }
        let gate = allowed(handle.element, pid: handle.pid)
        guard hasFocus(handle) else { return .focusLeft }
        return gate ? nil : .unreadable
    }

    private func hasFocus(_ handle: DropEditFieldHandle) -> Bool {
        guard let current = focusedElement(ofFrontmost: handle.pid) else { return false }
        return CFEqual(current, handle.element)
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
        // A field that lost focus during the transfer is not used.
        if let stop = stop(handle) { return stop }
        return .text(text)
    }

    func watch(_ handle: DropEditFieldHandle,
               onChange: @escaping @MainActor (DropEditFieldChange) -> Void) -> DropEditFieldWatch? {
        system.watch(handle, onChange)
    }

    // WHY: .project-docs/decisions/2026-11-22-drop-edit-observation.md
    func exposeFields(pid: pid_t) -> DropEditAccessibilityLease? {
        guard system.frontmostPID() == pid, let identity = system.processIdentity(pid) else { return nil }
        // Before its tree is on, an Electron app may report no focused
        // element at all; the app itself is checked instead.
        let focused = focusedElement(ofFrontmost: pid)
        let element = focused ?? AXUIElementCreateApplication(pid)
        let facts = system.facts(element, pid)
        // A readable field needs nothing; a field the gate refuses for its
        // app, a password or an error never gets the app's tree turned on.
        if DropEditFieldGate.allowsRead(facts) { return nil }
        guard DropEditFieldGate.mayExpose(facts) else { return nil }
        for attribute in Self.exposeAttributes {
            // Only an attribute known to be off. One already on (VoiceOver,
            // the user, another tool) stays theirs; one that cannot be read
            // is never changed, so there is no guessed value to restore.
            guard system.appFlag(pid, attribute) == false else { continue }
            // The metadata and flag calls can block: the same process must
            // still be in front right before the write, and focus must not
            // have moved: the gate judged that element.
            guard system.frontmostPID() == pid, system.processIdentity(pid) == identity,
                  Self.same(focusedElement(ofFrontmost: pid), focused) else { return nil }
            guard system.setAppFlag(pid, attribute, true) else { continue }
            return DropEditAccessibilityLease(pid: pid) { [system] in
                // Undone only for the same process and only while it still
                // holds exactly the value set here.
                guard system.processIdentity(pid) == identity, system.appFlag(pid, attribute) == true else { return }
                _ = system.setAppFlag(pid, attribute, false)
            }
        }
        return nil
    }

    /// The system-wide focused element, only when it belongs to `pid` and
    /// that app is frontmost: the element that has keyboard focus now.
    private func focusedElement(ofFrontmost pid: pid_t) -> AXUIElement? {
        guard system.frontmostPID() == pid, let element = system.focusedElement(),
              system.elementPID(element) == pid else { return nil }
        return element
    }

    private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
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
                let systemWide = AXUIElementCreateSystemWide()
                // A busy app must not stall the main thread for AX's default 6 s.
                AXUIElementSetMessagingTimeout(systemWide, AXDropEditFieldAccess.messagingTimeout)
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
                      let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                let element = raw as! AXUIElement
                AXUIElementSetMessagingTimeout(element, AXDropEditFieldAccess.messagingTimeout)
                return element
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
            watch: { handle, onChange in AXDropEditFieldWatch(handle: handle, onChange: onChange) }
        )
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
