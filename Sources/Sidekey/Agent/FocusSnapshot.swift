import AppKit
import ApplicationServices
import Foundation

struct FocusSnapshot: Equatable {
    let targetPID: pid_t
    let bundleID: String?
    let appName: String?
    let selectionText: String?
    let isEditable: Bool
    let capturedAt: Date

    static var applicationProvider: FocusSnapshotApplicationProviding = WorkspaceFocusSnapshotApplicationProvider()
    static var axReader: FocusSnapshotAXReading = SystemFocusSnapshotAXReader()
    static var dateProvider: () -> Date = Date.init

    static func capture() -> FocusSnapshot? {
        guard let app = applicationProvider.frontmostApplication() else {
            return nil
        }

        let focusedElement = axReader.focusedElement()
        return FocusSnapshot(
            targetPID: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName,
            selectionText: focusedElement.selectionText,
            isEditable: focusedElement.isEditable,
            capturedAt: dateProvider()
        )
    }

    func restoreFocus() -> Bool {
        Self.applicationProvider.activate(processIdentifier: targetPID)
    }

    /// Returns a copy with `selectionText` replaced. Used by the Cmd+C
    /// fallback (`SelectionFallback.captureAsync`) when the original
    /// AX-only capture returned nil / empty and the deferred Cmd+C
    /// dance has supplied a usable selection.
    func withSelectionText(_ newSelection: String?) -> FocusSnapshot {
        FocusSnapshot(
            targetPID: targetPID,
            bundleID: bundleID,
            appName: appName,
            selectionText: newSelection,
            isEditable: isEditable,
            capturedAt: capturedAt
        )
    }

    static func resetDependencies() {
        applicationProvider = WorkspaceFocusSnapshotApplicationProvider()
        axReader = SystemFocusSnapshotAXReader()
        dateProvider = Date.init
    }
}

struct FocusSnapshotApplication: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
}

protocol FocusSnapshotApplicationProviding {
    func frontmostApplication() -> FocusSnapshotApplication?
    func activate(processIdentifier: pid_t) -> Bool
}

protocol FocusSnapshotAXReading {
    func focusedElement() -> FocusSnapshotAXElement
}

struct FocusSnapshotAXElement: Equatable {
    let selectionText: String?
    let role: String?

    var isEditable: Bool {
        role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
    }

    init(selectionText: String? = nil, role: String? = nil) {
        self.selectionText = selectionText
        self.role = role
    }
}

private struct WorkspaceFocusSnapshotApplicationProvider: FocusSnapshotApplicationProviding {
    func frontmostApplication() -> FocusSnapshotApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return FocusSnapshotApplication(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }

    func activate(processIdentifier: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }
        return app.activate(options: [])
    }
}

private struct SystemFocusSnapshotAXReader: FocusSnapshotAXReading {
    func focusedElement() -> FocusSnapshotAXElement {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard
            focusedResult == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return FocusSnapshotAXElement()
        }

        let focusedElement = focusedValue as! AXUIElement
        return FocusSnapshotAXElement(
            selectionText: stringAttribute(kAXSelectedTextAttribute, from: focusedElement),
            role: stringAttribute(kAXRoleAttribute, from: focusedElement)
        )
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }
}
