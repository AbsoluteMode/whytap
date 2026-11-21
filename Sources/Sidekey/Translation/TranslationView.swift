import AppKit
import SwiftUI

struct TranslationView: View {
    @ObservedObject var text: TextTranslationModel
    @ObservedObject var subtitles: LiveSubtitleModel
    @ObservedObject var presentation: TranslationWindowController.Presentation
    let openSettings: (AIFeature) -> Void
    var embedded = false
    /// Closes the floating window; the embedded Toolbox pane has no close control.
    var close: () -> Void = {}
    @FocusState private var inputFocused: Bool
    @State private var inputHovered = false
    @State private var overlayHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isText: Bool { presentation.mode == .text }

    var body: some View {
        Group {
            if isText { textContent } else { subtitleContent }
        }
        .frame(minWidth: embedded ? 0 : (isText ? 320 : 420), maxWidth: .infinity,
               minHeight: embedded ? 0 : (isText ? 80 : 120), maxHeight: .infinity)
        .background { if !embedded && isText { Rectangle().fill(.regularMaterial) } }
        .onAppear { if isText && embedded { inputFocused = true } }
        .onChange(of: presentation.mode) { _, mode in if mode == .text && embedded { inputFocused = true } }
        .onChange(of: presentation.isTextPresented) { _, visible in
            if !embedded && !visible { inputFocused = false }
        }
        .task(id: presentation.inputFocusRequest) {
            guard !embedded, isText, presentation.isTextPresented else { return }
            let request = presentation.inputFocusRequest
            inputFocused = false
            // Reapply after the key window and native text field have settled,
            // including reopen after selecting the previous translation.
            await Task.yield()
            guard !Task.isCancelled, presentation.isTextPresented,
                  presentation.inputFocusRequest == request, isText else { return }
            inputFocused = true
        }
    }

    private var sourcePicker: some View {
        MacPopup(items: [.init(value: "auto", label: "Auto-detect")] + languageItems,
                 selection: $subtitles.sourceCode, maxWidth: embedded ? 130 : 150, appearance: .adaptive)
            .accessibilityLabel("Speech")
            .disabled(subtitles.phase.isActive)
    }

    private var targetPicker: some View {
        MacPopup(items: languageItems, selection: $subtitles.targetCode, maxWidth: embedded ? 130 : 150, appearance: .adaptive)
            .accessibilityLabel("Translate to")
            .disabled(subtitles.phase.isActive)
    }

    private var languageItems: [MacPopup<String>.Item] {
        AppLanguage.all.sorted { $0.englishName < $1.englishName }.map {
            .init(value: $0.code, label: $0.displayName)
        }
    }

    private var textContent: some View {
        // WHY: docs/DESIGN.md — Quick Translate: two text rows.
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $text.input)
                .textFieldStyle(.plain)
                .font(.system(size: embedded ? 17 : 22))
                .focused($inputFocused)
                .onSubmit { text.translate() }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    text.translate()
                    return .handled
                }
                .frame(minHeight: embedded ? 24 : 28)
                .padding(.horizontal, embedded ? 12 : 26)
                .padding(.vertical, embedded ? 12 : 18)
                .contentShape(Rectangle())
                .onTapGesture { inputFocused = true }
                .background(Color.white.opacity(inputHovered ? 0.10 : 0.065))
                .onHover { inputHovered = $0 }
                .accessibilityLabel("Text to translate")
                .accessibilityHint("Press Return to translate. Right-click for language and copy options.")
            ScrollView {
                Group {
                    if let issue = text.issue, let feature = issue.feature {
                        Button { openSettings(feature) } label: {
                            Text(issue.message + " Open API & Models →")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(MacButtonInteractionStyle(highlight: .primary, focused: settingsFocused))
                        .focused($settingsFocused)
                    } else {
                        Text(textOutput)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: text.issue != nil || inputTooLong ? (embedded ? 12 : 13) : (embedded ? 18 : 24),
                              weight: .medium))
                .foregroundStyle(text.result.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, embedded ? 12 : 26)
                .padding(.vertical, embedded ? 12 : 14)
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black.opacity(0.08))
            .accessibilityLabel("Translation")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy translation") { copyTranslation() }.disabled(text.result.isEmpty)
            Button("Clear") { text.input = ""; inputFocused = true }.disabled(text.input.isEmpty)
            if text.isTranslating { Button("Cancel translation") { text.cancel() } }
            Menu("Translate to") {
                Button(text.target == .automatic ? "✓ Auto · RU ↔ EN" : "Auto · RU ↔ EN") { text.target = .automatic }
                ForEach(AppLanguage.all.sorted { $0.englishName < $1.englishName }, id: \.code) { language in
                    Button((text.target == .language(language.code) ? "✓ " : "") + language.displayName) {
                        text.target = .language(language.code)
                    }
                }
            }
            if !embedded {
                Button(subtitles.phase.isActive ? "Show active subtitles" : "Subtitles") { presentation.mode = .subtitles }
            }
        }
    }

    @FocusState private var settingsFocused: Bool

    private var inputTooLong: Bool {
        text.input.trimmingCharacters(in: .whitespacesAndNewlines).count > TextTranslationModel.inputLimit
    }

    private var textOutput: String {
        if inputTooLong {
            return "Keep each translation under 12,000 characters."
        }
        if let issue = text.issue { return issue.message }
        if text.isTranslating { return "Translating…" }
        return text.result.isEmpty ? "Translation" : text.result
    }

    private func copyTranslation() {
        guard !text.result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.result, forType: .string)
    }

    // WHY: .project-docs/decisions/2026-11-21-compact-subtitle-overlay.md
    // The original RealtimeTranslator overlay: a bottom-anchored dark caption
    // box of at most five lines. Only the language pair and Start/Stop were added.
    @ViewBuilder private var subtitleContent: some View {
        if embedded {
            VStack(alignment: .leading, spacing: 8) {
                subtitleControls
                if let issue = subtitles.issue {
                    errorCard(issue)
                } else if let caption = SubtitleCaption.text(lines: subtitles.lines, phase: subtitles.phase, issue: nil) {
                    captionText(caption)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        .contextMenu { subtitleMenu }
                }
                if waitingWithoutAudio { audioPermissionsButton }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    if showsOverlayControls { subtitleControls }
                    if let caption = SubtitleCaption.text(lines: subtitles.lines, phase: subtitles.phase,
                                                          issue: subtitles.issue) {
                        captionText(caption)
                    }
                    if let feature = subtitles.issue?.feature {
                        Button("Open API & Models") { openSettings(feature) }.controlSize(.small)
                    }
                    if waitingWithoutAudio { audioPermissionsButton }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 5)
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onHover { overlayHovered = $0 }
                .contextMenu { subtitleMenu }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsOverlayControls)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(10)
        }
    }

    /// While subtitles run, the overlay shows only the caption; the controls
    /// return on hover and whenever capture is not running.
    private var showsOverlayControls: Bool { !subtitles.phase.isActive || overlayHovered }

    private var waitingWithoutAudio: Bool {
        subtitles.phase == .listening && !subtitles.hasAudio && subtitles.lines.isEmpty
    }

    private func captionText(_ value: String) -> some View {
        // At most five lines; the box hugs shorter text and older words leave
        // at the top, so the newest line never moves.
        Text(value)
            .font(.system(size: embedded ? 15 : 20, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineSpacing(3)
            .lineLimit(5)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Subtitles")
            .accessibilityValue(value)
    }

    private var subtitleControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                languagePair
                Spacer(minLength: 6)
                sessionButton
                if !embedded { closeButton }
            }
            VStack(alignment: .leading, spacing: 6) {
                languagePair
                HStack {
                    Spacer(minLength: 0)
                    sessionButton
                    if !embedded { closeButton }
                }
            }
        }
        .font(.system(size: 12))
        .environment(\.colorScheme, embedded ? colorScheme : .dark)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var languagePair: some View {
        HStack(spacing: 6) {
            sourcePicker
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            targetPicker
        }
    }

    @ViewBuilder private var sessionButton: some View {
        switch subtitles.phase {
        case .finishing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Button("Cancel") { subtitles.cancel() }
            }
        case .connecting:
            Button("Cancel") { subtitles.stop() }
        case .listening:
            Button("Stop", systemImage: "stop.fill") { subtitles.stop() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Stop subtitles")
        case .idle, .failed:
            Button("Start", systemImage: "play.fill") { subtitles.start() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Start subtitles")
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close")
        .accessibilityLabel("Close subtitles")
    }

    private var audioPermissionsButton: some View {
        Button("Open audio permissions") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    @ViewBuilder private var subtitleMenu: some View {
        Button("Copy translation") {
            let value = subtitles.lines.compactMap(\.translation).joined(separator: "\n\n")
            guard !value.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        .disabled(!subtitles.lines.contains { $0.translation != nil })
        Button("Clear") { subtitles.clear() }
            .disabled(subtitles.phase.isActive || subtitles.lines.isEmpty)
        if !embedded {
            Button("Translate text") { presentation.mode = .text }
        }
    }

    private func errorCard(_ issue: TranslationIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(issue.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let feature = issue.feature {
                Button("API & Models") { openSettings(feature) }.controlSize(.small)
            }
        }.padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
