import AppKit

/// A text editor inside Whytap that owned the keyboard when a Drop take
/// began: the floating Translate input, a Settings field, a text view.
///
/// Drop normally writes the dictation to the clipboard, posts Cmd+V and
/// restores the clipboard on the main thread without yielding it. A paste
/// addressed to Whytap itself is handled on that same thread, so it ran only
/// after the restore and inserted the user's previous clipboard (a copied
/// file's name) instead of the speech. An editor in this process needs no
/// clipboard or key event: the final text goes straight into its selection.
/// WHY: .project-docs/decisions/2026-11-18-drop-into-whytap-editors.md
@MainActor
struct DropLocalEditor {
    private weak var window: NSWindow?
    private weak var editor: NSTextView?
    /// The control a window's shared field editor was editing for. The same
    /// field editor later serves other fields of that window.
    private weak var field: AnyObject?
    private let editsField: Bool
    private let isPresented: @MainActor (NSWindow) -> Bool

    /// The window of this app that receives keyboard input. A nonactivating
    /// panel is key while another app stays active.
    static var keyWindow: NSWindow? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isKeyWindow),
              window.isKeyWindow, NSApp.isActive || window.styleMask.contains(.nonactivatingPanel)
        else { return nil }
        return window
    }

    /// Nil unless `window` is shown and its first responder is an editable
    /// native text editor.
    init?(focusedIn window: NSWindow?, isPresented: @escaping @MainActor (NSWindow) -> Bool = { $0.isVisible && $0 === Self.keyWindow }) {
        guard let window, isPresented(window),
              let editor = window.firstResponder as? NSTextView, editor.isEditable else { return nil }
        self.window = window
        self.editor = editor
        self.isPresented = isPresented
        editsField = editor.isFieldEditor
        field = editor.isFieldEditor ? editor.delegate : nil
        // A field editor that edits for nothing cannot be recognised later.
        if editsField && field == nil { return nil }
    }

    /// Replaces the editor's current selection (or marked text) the way typing
    /// does, so delegates, bindings and undo see an ordinary edit. False when
    /// the remembered editor no longer has its window's keyboard focus or its
    /// window is closed; nothing is inserted anywhere else.
    func insert(_ text: String) -> Bool {
        guard let window, let editor, isPresented(window),
              window.firstResponder === editor, editor.isEditable else { return false }
        if editsField {
            guard let field, editor.delegate === field else { return false }
        }
        // A native field can reject an edit (for example, a numeric field).
        // Its change notification acknowledges insertion without inspecting
        // the contents, including those of secure fields.
        var changed = false
        let center = NotificationCenter.default
        let observation = center.addObserver(forName: NSText.didChangeNotification, object: editor, queue: nil) { _ in
            MainActor.assumeIsolated { changed = true }
        }
        defer { center.removeObserver(observation) }
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        // The onboarding's try field says "it worked" only on this signal: a
        // finished take landed in that editor, not text the user typed. The
        // notification carries the editor, never the text.
        // WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
        if changed { NotificationCenter.default.post(name: .sidekeyDropInsertedIntoLocalEditor, object: editor) }
        return changed
    }
}

extension Notification.Name {
    /// Posted with the receiving `NSTextView` after Drop inserted a take into
    /// one of Whytap's own editors.
    static let sidekeyDropInsertedIntoLocalEditor = Notification.Name("sidekey.drop.insertedIntoLocalEditor")
}
