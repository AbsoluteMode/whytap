import AppKit
import ApplicationServices
import os.log

/// Inspects the AX hierarchy of a given app pid to decide whether its
/// currently-focused UI element is plausibly a text-editing surface (text
/// field, text area, search field, combo box with text entry, or a
/// web-content frame that may host contenteditable rich text). Used to
/// gate the history strip's "Paste to <App> ↵" hint — pasting into an app
/// with no editable focus is a silent no-op for the user (Cmd+V posts but
/// nothing lands), so we'd rather suppress the hint in that case.
///
/// ## Semantics (iter 21+): permissive default
///
/// Iter 17-20 ran a *strict* validator — show hint only when AX positively
/// confirmed a text-input element. That broke the entire Electron /
/// Chromium ecosystem: Claude Desktop, Slack, Discord, VS Code, Cursor,
/// Notion Desktop and friends don't enable their renderer accessibility
/// tree by default, so every AX query returns -25212 / -25205, and our
/// validator produced a false negative for them all.
///
/// The new contract is the inverse:
///
/// | AX result                                            | Hint shown? |
/// | ---------------------------------------------------- | ----------- |
/// | Focused element with text-input role / web area /    |             |
/// | settable value / settable selected text              | YES         |
/// | Focused element resolved but with a known non-text   |             |
/// | role (button, cell, image, file-browser row, …)      | NO          |
/// | AX errored on every source (Electron / uncooperative |             |
/// | app / permission revoked)                            | YES         |
/// | Bundle id in the deny-list (e.g. Finder)             | NO          |
/// | `pid <= 0`                                           | NO          |
///
/// In other words: only *positive evidence of a non-text element* (or an
/// explicit blacklist) suppresses the hint. The cost of a false positive
/// is a single wasted Enter press that pastes nothing; the cost of a
/// false negative is the entire Electron ecosystem feeling broken. The
/// former is recoverable from one keystroke, the latter isn't.
///
/// Requires Accessibility permission. If the grant was revoked between
/// launch and the validator call, every AX call returns an error and the
/// validator falls through to the permissive default — which is still
/// safer than the strict variant for the user's day-to-day flow.
///
/// ## UX trade-off (iter 22)
///
/// Electron / Chromium apps (Claude Desktop, Slack, Discord, VS Code,
/// Cursor, Notion Desktop) don't expose their renderer accessibility
/// tree by default. All AX queries return `kAXErrorNoValue` or
/// `kAXErrorAttributeUnsupported` regardless of whether the user's
/// caret is in a chat input or focused on a non-editable surface
/// (sidebar, message list, web view). We can detect WHICH app is
/// frontmost but not WHERE inside it the cursor sits.
///
/// The permissive default (iter 21) renders "Paste to <App> ↵" for
/// these apps unconditionally. The cost:
///
///   * If the user opened the strip with the caret in a chat input
///     → Enter pastes cleanly. (Common case.)
///   * If the user opened the strip with the caret NOT in an input
///     (e.g. focus was on the sidebar or hovering a message bubble)
///     → Cmd+V posts but lands in nowhere. The hint over-promised.
///
/// Same trade-off Raycast / Alfred / similar launcher tools make:
/// users learn to click into the chat input before invoking the strip.
/// The alternative (suppress the hint for Electron apps entirely)
/// would lose ~80% of paste targets — the launcher's primary use
/// case is "drop text into the chat I just had focus in", and the
/// chat is almost always Electron.
@MainActor
enum PasteTargetValidator {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "paste-target")

    /// Apps whose frontmost role isn't pasting text into anything, even
    /// when AX says nothing definitive. Currently only Finder: when the
    /// user clicks the Desktop wallpaper or a Finder window, Finder is
    /// frontmost but no editable surface exists. Without this guard, the
    /// permissive default would render "Paste to Finder ↵" which is
    /// misleading. Future entries should follow the same shape — apps
    /// that legitimately can't host a paste despite being a normal
    /// frontmost target.
    private static let blacklistedBundleIds: Set<String> = [
        "com.apple.finder",
    ]

    /// Top-level AX roles that ALWAYS represent a text-editing surface
    /// on macOS. Apps that report any of these as their focused element
    /// will receive a synthesised Cmd+V cleanly.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// AX subroles / non-standard role strings used by some apps for
    /// editable surfaces. `AXSearchField` is Spotlight-style. The
    /// `AXContentEditableElement` token is what some accessibility
    /// bridges emit for `<div contenteditable>` regions. Treat both as
    /// text-input for hint purposes.
    private static let textSubroleHints: Set<String> = [
        "AXSearchField",
        "AXContentEditableElement",
    ]

    /// Verdict from a single source's evaluation of its focused element.
    ///
    /// - `accept`: matched a text-input criterion — stop searching, hint
    ///   is allowed.
    /// - `rejectNonText`: AX resolved a focused element with a known
    ///   non-text role (button, cell, image, …). Definitive negative
    ///   evidence — hide the hint even if other sources would also fail.
    /// - `noOpinion`: source either didn't resolve a focused element at
    ///   all, or resolved one whose role we can't classify. Fall through
    ///   to the next source / permissive default.
    private enum Verdict {
        case accept
        case rejectNonText
        case noOpinion
    }

    /// Returns `true` if the app identified by `pid` is plausibly a
    /// paste target right now. See the type comment above for the full
    /// semantics table.
    ///
    /// - Parameter pid: The pid captured at strip-open time (typically
    ///   from `AutoPasteEngine.rememberTargetBeforeRecording`).
    /// - Parameter bundleIdentifier: Optional bundle id of the captured
    ///   app. When passed and matching `blacklistedBundleIds`, short-
    ///   circuits to `false` before any AX work. The callsite usually
    ///   passes `NSRunningApplication(processIdentifier: pid)?.bundleIdentifier`.
    static func appHasFocusedTextInput(
        pid: pid_t,
        bundleIdentifier: String? = nil
    ) -> Bool {
        guard pid > 0 else { return false }

        // Bundle-id blacklist takes priority over any AX result. Finder
        // is the canonical case: frontmost when the user clicks the
        // Desktop, but they have no intent to paste into anything.
        if let bundleId = bundleIdentifier, blacklistedBundleIds.contains(bundleId) {
            os_log(
                "paste_target_blacklisted pid=%{public}d bundle=%{public}@",
                log: log,
                type: .info,
                pid,
                bundleId
            )
            return false
        }

        var sawNonTextElement = false

        // Source 1: app-scoped focused element.
        let appElement = AXUIElementCreateApplication(pid)
        if let focused = copyFocusedElement(from: appElement, pid: pid, source: "app") {
            switch evaluateFocusedElement(focused, pid: pid, source: "app") {
            case .accept:
                return true
            case .rejectNonText:
                sawNonTextElement = true
            case .noOpinion:
                break
            }
        }

        // Source 2: focused window of the app, then focused element of
        // that window. Covers apps that expose focus per-window but not
        // on the application root.
        if let window = copyAttributeAsElement(appElement, kAXFocusedWindowAttribute as CFString, pid: pid, source: "window"),
           let focused = copyFocusedElement(from: window, pid: pid, source: "window")
        {
            switch evaluateFocusedElement(focused, pid: pid, source: "window") {
            case .accept:
                return true
            case .rejectNonText:
                sawNonTextElement = true
            case .noOpinion:
                break
            }
        }

        // Source 3: system-wide focused element. Pid-check the returned
        // element so we don't accept focus from a different app.
        let systemElement = AXUIElementCreateSystemWide()
        if let focused = copyFocusedElement(from: systemElement, pid: pid, source: "system") {
            let focusedPid = focusedElementPid(focused)
            if focusedPid == pid {
                switch evaluateFocusedElement(focused, pid: pid, source: "system") {
                case .accept:
                    return true
                case .rejectNonText:
                    sawNonTextElement = true
                case .noOpinion:
                    break
                }
            } else {
                os_log(
                    "paste_target_system_pid_mismatch pid=%{public}d focused_pid=%{public}d",
                    log: log,
                    type: .info,
                    pid,
                    focusedPid
                )
            }
        }

        // Definitive non-text evidence from any source — suppress the
        // hint. This is the only path where strict-reject still wins.
        if sawNonTextElement {
            os_log(
                "paste_target_rejected_non_text pid=%{public}d",
                log: log,
                type: .info,
                pid
            )
            return false
        }

        // No source produced a usable verdict (Electron / uncooperative
        // app / AX permission revoked). Default to permissive — the
        // user can recover from a no-op Cmd+V with one keystroke, but
        // the Electron false-negative was a daily papercut.
        os_log(
            "paste_target_permissive_default pid=%{public}d reason=ax_unavailable",
            log: log,
            type: .info,
            pid
        )
        return true
    }

    /// Reads `kAXFocusedUIElementAttribute` off the supplied element.
    /// Logs the AX error code with a `source` tag on failure so the
    /// per-source diagnostic is preserved.
    private static func copyFocusedElement(
        from element: AXUIElement,
        pid: pid_t,
        source: String
    ) -> AXUIElement? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &ref
        )
        guard result == .success, let raw = ref else {
            os_log(
                "paste_target_source_no_focused pid=%{public}d source=%{public}@ ax_err=%{public}d",
                log: log,
                type: .info,
                pid,
                source,
                Int(result.rawValue)
            )
            return nil
        }
        // CFTypeRef -> AXUIElement is a force-cast per the AX headers; the
        // .success status above is the only contract guarantee on shape.
        return (raw as! AXUIElement)
    }

    /// Generic attribute copy that returns an AX element value (used for
    /// `kAXFocusedWindowAttribute`).
    private static func copyAttributeAsElement(
        _ element: AXUIElement,
        _ attr: CFString,
        pid: pid_t,
        source: String
    ) -> AXUIElement? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attr, &ref)
        guard result == .success, let raw = ref else {
            os_log(
                "paste_target_source_no_window pid=%{public}d source=%{public}@ ax_err=%{public}d",
                log: log,
                type: .info,
                pid,
                source,
                Int(result.rawValue)
            )
            return nil
        }
        return (raw as! AXUIElement)
    }

    /// Pid of the app that owns `element`. Returns 0 if AX can't resolve
    /// ownership (defensive — treat as mismatch).
    private static func focusedElementPid(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// Runs the canonical acceptance checks (role / subrole / web-area /
    /// value-settable / selected-text-settable) against a focused
    /// element produced by one of the three lookup sources. Logs include
    /// the `source` tag so the matching path is identifiable in os_log.
    ///
    /// Returns:
    /// - `.accept` if any positive criterion matched.
    /// - `.rejectNonText` if the element resolved to a known non-text
    ///   role (anything our positive checks didn't accept, given a
    ///   non-empty role string). This is *definitive* — even if a later
    ///   source can't reach the app, we'll suppress the hint.
    /// - `.noOpinion` if AX returned a focused element but its role
    ///   couldn't be read (empty / nil) — leave it to other sources or
    ///   the permissive default. Rejecting on an unknown role would
    ///   reintroduce the Electron false-negative.
    private static func evaluateFocusedElement(
        _ focused: AXUIElement,
        pid: pid_t,
        source: String
    ) -> Verdict {
        let roleRaw = copyStringAttribute(focused, kAXRoleAttribute as CFString)
        let role = roleRaw ?? "(nil)"
        let subrole = copyStringAttribute(focused, kAXSubroleAttribute as CFString) ?? "(nil)"

        // FAST PATH 1: well-known text-input roles.
        if textRoles.contains(role) {
            os_log(
                "paste_target_role_match pid=%{public}d source=%{public}@ role=%{public}@",
                log: log,
                type: .info,
                pid,
                source,
                role
            )
            return .accept
        }
        if textSubroleHints.contains(subrole) {
            os_log(
                "paste_target_subrole_match pid=%{public}d source=%{public}@ subrole=%{public}@",
                log: log,
                type: .info,
                pid,
                source,
                subrole
            )
            return .accept
        }

        // FAST PATH 2: web area (Safari / Chrome). Permissive intentionally
        // — most rich-text editors leave focus at web-area level rather
        // than the contenteditable leaf, and walking the AX subtree on
        // the main thread inside a hotkey callback is too slow.
        if role == "AXWebArea" {
            os_log(
                "paste_target_web_area pid=%{public}d source=%{public}@",
                log: log,
                type: .info,
                pid,
                source
            )
            return .accept
        }

        // CANONICAL CHECK: is the element value or selected-text settable?
        // AppKit's own paste validation uses this — true for native text
        // fields, web contenteditable, Electron renderers, any control
        // that the user can type into. False for static elements,
        // file-browser cells, button labels, decorative chrome.
        if isAttributeSettable(focused, kAXValueAttribute as CFString) {
            os_log(
                "paste_target_value_settable pid=%{public}d source=%{public}@ role=%{public}@ subrole=%{public}@",
                log: log,
                type: .info,
                pid,
                source,
                role,
                subrole
            )
            return .accept
        }
        if isAttributeSettable(focused, kAXSelectedTextAttribute as CFString) {
            os_log(
                "paste_target_selected_text_settable pid=%{public}d source=%{public}@ role=%{public}@ subrole=%{public}@",
                log: log,
                type: .info,
                pid,
                source,
                role,
                subrole
            )
            return .accept
        }

        // No positive match. Distinguish "AX gave us an opaque element
        // we can't classify" (noOpinion — let other sources or the
        // permissive default decide) from "AX gave us a real element
        // with a known role that we just don't accept" (rejectNonText —
        // definitive negative evidence).
        if roleRaw == nil || roleRaw?.isEmpty == true {
            os_log(
                "paste_target_source_unknown_role pid=%{public}d source=%{public}@ subrole=%{public}@",
                log: log,
                type: .info,
                pid,
                source,
                subrole
            )
            return .noOpinion
        }

        os_log(
            "paste_target_source_rejected pid=%{public}d source=%{public}@ role=%{public}@ subrole=%{public}@",
            log: log,
            type: .info,
            pid,
            source,
            role,
            subrole
        )
        return .rejectNonText
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attr, &ref)
        guard result == .success else { return nil }
        return ref as? String
    }

    private static func isAttributeSettable(_ element: AXUIElement, _ attr: CFString) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attr, &settable)
        return result == .success && settable.boolValue
    }
}
