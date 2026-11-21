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
    // Its content is phrase pairs, original beside translation.
    // WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
    @ViewBuilder private var subtitleContent: some View {
        let rows = SubtitleCaption.rows(lines: subtitles.lines, live: subtitles.live)
        if embedded {
            VStack(alignment: .leading, spacing: 8) {
                subtitleControls
                if let issue = subtitles.issue {
                    errorCard(issue)
                } else if !rows.isEmpty || SubtitleCaption.status(hasRows: false, phase: subtitles.phase, issue: nil) != nil {
                    caption(rows)
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
                // The box hugs its widest pair (up to the panel's inner width)
                // and stays centred, so no empty strip runs beside the text.
                HuggingColumnLayout(spacing: 10, maxWidth: Self.overlayContentWidth) {
                    if showsOverlayControls { subtitleControls }
                    if subtitles.issue != nil || !rows.isEmpty
                        || SubtitleCaption.status(hasRows: false, phase: subtitles.phase, issue: nil) != nil {
                        caption(rows)
                    }
                    if let feature = subtitles.issue?.feature {
                        Button("Open API & Models") { openSettings(feature) }.controlSize(.small)
                    }
                    if waitingWithoutAudio { audioPermissionsButton }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 5)
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onHover { overlayHovered = $0 }
                .contextMenu { subtitleMenu }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsOverlayControls)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rows)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(10)
        }
    }

    /// The overlay panel is 760 pt wide: 10 pt outside and 16 pt inside the box.
    static let overlayContentWidth: CGFloat = 760 - 2 * 10 - 2 * 16

    /// While subtitles run, the overlay shows only the caption; the controls
    /// return on hover and whenever capture is not running.
    private var showsOverlayControls: Bool { !subtitles.phase.isActive || overlayHovered }

    private var waitingWithoutAudio: Bool {
        subtitles.phase == .listening && !subtitles.hasAudio && subtitles.lines.isEmpty && subtitles.live.isEmpty
    }

    /// Pairs when there are phrases, otherwise one status line. The box keeps
    /// the overlay panel's height: pairs are bottom-anchored and only whole
    /// pairs show, so the newest pair never moves and the oldest leaves at the
    /// top in one piece; a new pair fades and slides in from the bottom. The
    /// controls row, shown on hover, takes its height from the pairs.
    @ViewBuilder private func caption(_ rows: [SubtitleCaption.Row]) -> some View {
        if let status = SubtitleCaption.status(hasRows: !rows.isEmpty, phase: subtitles.phase, issue: subtitles.issue) {
            captionText(status)
        } else if embedded {
            NewestRowsLayout(spacing: 6, maxHeight: 150) {
                ForEach(rows) { row in
                    pairRow(row)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rows)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Subtitles")
        } else {
            // Russian runs about a fifth longer than English and is the line
            // being read: the grid gives the original only what it needs.
            let isBand = pairMarker == .band
            PairGridLayout(rowSpacing: 8, columnSpacing: 18, maxWidth: Self.overlayContentWidth,
                           maxHeight: showsOverlayControls ? 108 : 146,
                           inset: isBand ? CGSize(width: 8, height: 3) : .zero) {
                ForEach(rows) { row in
                    Group {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.white.opacity(isBand && row.ordinal.isMultiple(of: 2) ? 0.07 : 0))
                        sourceText(row)
                        translationText(row)
                    }
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rows)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Subtitles")
        }
    }

    @Environment(\.subtitlePairMarker) private var pairMarker

    /// The phrase's text with the chosen pair mark: an accent first letter or
    /// a leading accent dot.
    private func marked(_ value: String, font: Font, color: Color) -> some View {
        var body = Text(value)
        if pairMarker == .initial, let first = value.first {
            body = Text(String(first)).foregroundColor(SubtitlePairMarker.accent).fontWeight(.semibold)
                + Text(value.dropFirst())
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if pairMarker == .dot {
                Text("•").foregroundStyle(SubtitlePairMarker.accent).accessibilityHidden(true)
            }
            body.foregroundStyle(color).lineSpacing(2)
        }
        .font(font)
    }

    private func sourceText(_ row: SubtitleCaption.Row) -> some View {
        marked(row.source, font: .system(size: embedded ? 12 : 15, weight: .regular, design: .rounded),
               color: .white.opacity(row.isLive ? 0.42 : 0.6))
    }

    /// Toolbox pairs: the pane is too narrow for two columns, so the original
    /// sits above its translation.
    @ViewBuilder private func pairRow(_ row: SubtitleCaption.Row) -> some View {
        let isBand = pairMarker == .band
        VStack(alignment: .leading, spacing: 2) {
            sourceText(row).frame(maxWidth: .infinity, alignment: .leading)
            translationText(row).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isBand ? 8 : 0)
        .padding(.vertical, isBand ? 3 : 0)
        .background {
            if isBand, row.ordinal.isMultiple(of: 2) {
                RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07))
            }
        }
    }

    @ViewBuilder private func translationText(_ row: SubtitleCaption.Row) -> some View {
        switch row.translation {
        case .text(let value):
            marked(value, font: .system(size: embedded ? 14 : 18, weight: .medium, design: .rounded), color: .white)
        case .pending:
            Image(systemName: "ellipsis")
                .font(.system(size: embedded ? 12 : 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && !row.isLive)
                .accessibilityLabel(row.isLive ? "Listening" : "Translating")
        case .failed:
            Text("Not translated")
                .font(.system(size: embedded ? 11 : 13, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func captionText(_ value: String) -> some View {
        // At most five lines; the box height hugs shorter text (its width spans
        // the panel, as in the original) and older words leave
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
