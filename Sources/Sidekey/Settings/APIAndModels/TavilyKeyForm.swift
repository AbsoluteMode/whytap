import AppKit
import SwiftUI

/// Search credentials use the same API keys surface without becoming a model route.
@MainActor
struct TavilyKeyForm: View {
    @ObservedObject var settings: TavilySettings
    var onSaveResult: (Bool) -> Void = { _ in }
    var onRemoveFailure: () -> Void = {}
    let onClose: () -> Void
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var keyFocused: Bool
    @State private var keyHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField(settings.configured ? "New API key" : "API key", text: $settings.draftKey)
                .lilBroControl("API key")
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(keyHovered && !settings.saving ? MacSettingsTheme.accent.opacity(0.6) : .clear, lineWidth: 1).allowsHitTesting(false) }
                .onHover { keyHovered = $0 }
                .accessibilityLabel("Tavily API key")
                .onSubmit(save)
            HStack(spacing: 10) {
                APIModelAction(title: "Remove", style: .danger, isEnabled: settings.configured) {
                    settings.remove()
                    if settings.messageIsError { onRemoveFailure() }
                    else { onClose() }
                }
                Spacer(minLength: 0)
                if settings.saving { ProgressView().controlSize(.small).accessibilityLabel("Saving key") }
                APIModelAction(title: "Save", style: .primary,
                               isEnabled: !settings.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               action: save)
            }
        }
        .foregroundStyle(MacSettingsTheme.text)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 12))
        .disabled(settings.saving)
        .background(TavilyKeyWindowClose(onClose: clearDraft).frame(width: 0, height: 0))
        .onAppear { keyFocused = true }
        .onDisappear(perform: clearDraft)
    }

    private func save() {
        guard !settings.saving, !settings.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saveTask = Task {
            await settings.save()
            guard !Task.isCancelled else { return }
            onSaveResult(!settings.messageIsError)
        }
    }

    private func clearDraft() { saveTask?.cancel(); settings.clearDraft() }
}

/// A retained Settings window can close without its content disappearing.
private struct TavilyKeyWindowClose: NSViewRepresentable {
    let onClose: () -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.onClose = onClose }

    final class Observer: NSView {
        var onClose: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)),
                    name: NSWindow.willCloseNotification, object: window)
            }
        }
        @objc private func windowClosing(_ notification: Notification) { onClose?() }
    }
}
