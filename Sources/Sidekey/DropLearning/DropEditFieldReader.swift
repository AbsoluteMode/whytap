import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The field a take was pasted into, captured right after Cmd+V.
struct DropEditFieldHandle {
    let pid: pid_t
    let element: AXUIElement
}

/// Reads the field the take went into, only if it is still the same focused
/// element and the gate allows it. Reads stay in memory; nothing is logged.
@MainActor
protocol DropEditFieldAccess: AnyObject {
    func capture(pid: pid_t) -> DropEditFieldHandle?
    /// The field's text, or nil when it changed, closed, lost focus, became
    /// secure or cannot be read.
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
        guard let element = focusedElement(pid: pid), facts(for: element, pid: pid).map(DropEditFieldGate.allowsRead) == true
        else { return nil }
        return DropEditFieldHandle(pid: pid, element: element)
    }

    func read(_ handle: DropEditFieldHandle) -> String? {
        guard NSRunningApplication(processIdentifier: handle.pid)?.isTerminated == false,
              let current = focusedElement(pid: handle.pid), CFEqual(current, handle.element),
              let facts = facts(for: current, pid: handle.pid), DropEditFieldGate.allowsRead(facts),
              let value = stringAttribute(current, kAXValueAttribute as CFString),
              (value as NSString).length <= DropEditFieldLimits.maxFieldLength
        else { return nil }
        return value
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        // A busy app must not stall the main thread for AX's default 6 s.
        AXUIElementSetMessagingTimeout(system, Self.messagingTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        return element
    }

    private func facts(for element: AXUIElement, pid: pid_t) -> DropEditFieldFacts? {
        guard let role = stringAttribute(element, kAXRoleAttribute as CFString) else { return nil }
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        return DropEditFieldFacts(
            bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            isOwnProcess: pid == ProcessInfo.processInfo.processIdentifier,
            role: role,
            subrole: stringAttribute(element, kAXSubroleAttribute as CFString),
            secureEventInput: IsSecureEventInputEnabled(),
            hasStringValue: valueResult == .success && valueRef is String,
            accessibilityError: valueResult != .success && valueResult != .noValue
        )
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &ref) == .success else { return nil }
        return ref as? String
    }
}
