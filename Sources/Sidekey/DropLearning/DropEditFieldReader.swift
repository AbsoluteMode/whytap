import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The field a take is pasted into, captured before Cmd+V.
struct DropEditFieldHandle {
    let pid: pid_t
    let element: AXUIElement
}

/// Captures and reads the field a take went into. Every check runs on the
/// field's identity and security metadata before its text is touched; the text
/// is read once, bounded, only from the same still-focused element. Reads stay
/// in memory; nothing is logged.
@MainActor
protocol DropEditFieldAccess: AnyObject {
    /// The target app's focused field, if the gate allows it. Reads no text.
    func capture(pid: pid_t) -> DropEditFieldHandle?
    /// The same element is still the app's focused field and still allowed.
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

    func capture(pid: pid_t) -> DropEditFieldHandle? {
        guard let element = focusedElement(pid: pid), allowed(element, pid: pid) else { return nil }
        return DropEditFieldHandle(pid: pid, element: element)
    }

    func isStillFocused(_ handle: DropEditFieldHandle) -> Bool {
        guard NSRunningApplication(processIdentifier: handle.pid)?.isTerminated == false,
              let current = focusedElement(pid: handle.pid), CFEqual(current, handle.element) else { return false }
        return allowed(current, pid: handle.pid)
    }

    // WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
    func read(_ handle: DropEditFieldHandle) -> String? {
        guard isStillFocused(handle) else { return nil }
        // Bound the read before it happens when the field reports its length.
        var count: CFTypeRef?
        let countResult = AXUIElementCopyAttributeValue(
            handle.element, kAXNumberOfCharactersAttribute as CFString, &count
        )
        switch countResult {
        case .success:
            guard let length = count as? Int, length <= DropEditFieldLimits.maxFieldLength else { return nil }
        case .attributeUnsupported, .noValue:
            break
        default:
            return nil
        }
        // The one read of the text.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(handle.element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              (text as NSString).length <= DropEditFieldLimits.maxFieldLength else { return nil }
        return text
    }

    /// The app's own focused element (not the system-wide one): it does not
    /// move when another app is frontmost, so it names the field Cmd+V goes to.
    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // A busy app must not stall the main thread for AX's default 6 s.
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        return element
    }

    private func allowed(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard let facts = facts(for: element, pid: pid) else { return false }
        return DropEditFieldGate.allowsRead(facts)
    }

    /// Identity and security metadata only: never the field's text.
    private func facts(for element: AXUIElement, pid: pid_t) -> DropEditFieldFacts? {
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
    }

    /// A string attribute; an attribute the element does not have is nil,
    /// any other AX failure (IPC, timeout) is an error and fails the gate.
    private func metadata(_ element: AXUIElement, _ name: CFString) -> (value: String?, failed: Bool) {
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name, &ref) {
        case .success: return (ref as? String, false)
        case .noValue, .attributeUnsupported: return (nil, false)
        default: return (nil, true)
        }
    }
}
