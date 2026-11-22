import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The field a take is pasted into, captured at the paste boundary, right
/// before Cmd+V.
struct DropEditFieldHandle {
    let pid: pid_t
    let element: AXUIElement
}

/// Captures and reads the field a take went into. Every check runs on the
/// field's identity and security metadata before its text is touched; the text
/// is read once, as a range bounded by the length the field reports, only from
/// the element that still has keyboard focus. Reads stay in memory; nothing is
/// logged.
@MainActor
protocol DropEditFieldAccess: AnyObject {
    /// The focused field of the frontmost target app, if the gate allows it.
    /// Reads no text.
    func capture(pid: pid_t) -> DropEditFieldHandle?
    /// The same element still has keyboard focus and is still allowed.
    func isStillFocused(_ handle: DropEditFieldHandle) -> Bool
    /// The field's text, or nil when it changed, closed, lost focus, became
    /// secure, is too long or cannot be read.
    func read(_ handle: DropEditFieldHandle) -> String?
}

/// Upper bound on a field's text the learning step reads (UTF-16 units).
enum DropEditFieldLimits {
    static let maxFieldLength = 20_000
}

@MainActor
final class AXDropEditFieldAccess: DropEditFieldAccess {
    static let messagingTimeout: Float = 0.25

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
    }

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
        guard system.isRunning(handle.pid),
              let current = focusedElement(ofFrontmost: handle.pid),
              CFEqual(current, handle.element) else { return false }
        return allowed(current, pid: handle.pid)
    }

    // WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
    func read(_ handle: DropEditFieldHandle) -> String? {
        guard isStillFocused(handle) else { return nil }
        // The transfer is bounded before it happens: the field must report
        // its length, and only that range is requested. A field that does
        // not report it, or cannot return a range, is not read at all.
        guard let length = system.characterCount(handle.element),
              length >= 0, length <= DropEditFieldLimits.maxFieldLength else { return nil }
        if length == 0 { return "" }
        guard let text = system.string(handle.element, CFRange(location: 0, length: length)),
              (text as NSString).length <= DropEditFieldLimits.maxFieldLength else { return nil }
        return text
    }

    /// The system-wide focused element, only when it belongs to `pid` and
    /// that app is frontmost: the element that has keyboard focus now.
    private func focusedElement(ofFrontmost pid: pid_t) -> AXUIElement? {
        guard system.frontmostPID() == pid, let element = system.focusedElement(),
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
            }
        )
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
