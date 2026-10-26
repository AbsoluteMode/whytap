import AppKit
import SwiftUI

struct TranslationView: View {
    @ObservedObject var text: TextTranslationModel
    @ObservedObject var subtitles: LiveSubtitleModel
    @ObservedObject var presentation: TranslationWindowController.Presentation
    let openSettings: (AIFeature) -> Void
    var embedded = false
    @FocusState private var inputFocused: Bool
    @State private var inputHovered = false
    @State private var copied = false
    @State private var followsLatest = true

    private var isText: Bool { presentation.mode == .text }

    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 8 : 16) {
            if !embedded && !isText {
                HStack {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 22)).foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Translate").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Picker("Mode", selection: $presentation.mode) {
                        ForEach(TranslationWindowController.Mode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
            }
            if !isText {
                audioControls
                if let issue = subtitles.issue { errorCard(issue) }
            }
            if isText { textContent } else { subtitleContent }
            if !isText { footer }
        }
        .padding(embedded || isText ? 0 : 22)
        .padding(.top, embedded || isText ? 0 : 24)
        .frame(minWidth: embedded ? 0 : (isText ? 320 : 440), maxWidth: .infinity,
               minHeight: embedded ? 0 : (isText ? 80 : 270), maxHeight: .infinity)
        .background { if !embedded { Rectangle().fill(.regularMaterial) } }
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
        .onChange(of: text.result) { _, _ in copied = false }
        .onChange(of: subtitles.lines) { _, _ in copied = false }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: embedded ? 6 : 10) {
            if embedded {
                HStack {
                    Text("Speech").frame(width: 78, alignment: .leading)
                    sourcePicker.labelsHidden().frame(maxWidth: .infinity)
                }
                HStack {
                    Text("Translate to").frame(width: 78, alignment: .leading)
                    targetPicker.labelsHidden().frame(maxWidth: .infinity)
                }
                .font(.system(size: 12))
                audioStatus
                    .font(.system(size: 11))
                HStack {
                    Toggle("Original", isOn: $subtitles.showsOriginal).toggleStyle(.checkbox)
                    Toggle("Follow", isOn: $followsLatest).toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speech").font(.system(size: 11)).foregroundStyle(.secondary)
                        sourcePicker
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Translate to").font(.system(size: 11)).foregroundStyle(.secondary)
                        targetPicker
                    }
                }.font(.system(size: 12))
                HStack {
                    audioStatus
                    Spacer()
                    Toggle("Original", isOn: $subtitles.showsOriginal).toggleStyle(.checkbox)
                    Toggle("Follow", isOn: $followsLatest).toggleStyle(.checkbox)
                }.font(.system(size: 12))
            }
        }
    }

    private var sourcePicker: some View {
        MacPopup(items: [.init(value: "auto", label: "Auto-detect")] + languageItems,
                 selection: $subtitles.sourceCode, maxWidth: 170, appearance: .adaptive)
            .accessibilityLabel("Speech")
            .disabled(subtitles.phase.isActive)
    }

    private var targetPicker: some View {
        MacPopup(items: languageItems, selection: $subtitles.targetCode, maxWidth: 170, appearance: .adaptive)
            .accessibilityLabel("Translate to")
            .disabled(subtitles.phase.isActive)
    }

    private var audioStatus: some View {
        Label(status, systemImage: subtitles.phase.isActive ? "waveform" : "speaker.wave.2")
            .foregroundStyle(subtitles.phase.isActive ? Color.blue : Color.secondary)
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

    private var subtitleContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if subtitles.lines.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "captions.bubble").font(.system(size: 32, weight: .light)).foregroundStyle(.blue)
                            Text(subtitles.phase.isActive ? "Waiting for speech…" : "Understand what you hear")
                                .font(.system(size: 20, weight: .medium))
                            Text(subtitles.phase.isActive
                                 ? "Play audio on your Mac. If nothing arrives, check System Audio Recording in macOS Privacy & Security."
                                 : "Translate videos and calls into live subtitles. Only your Mac’s system audio is captured.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).frame(maxWidth: embedded ? 260 : 360)
                            if subtitles.phase.isActive, !subtitles.hasAudio {
                                Button("Open audio permissions") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }.font(.caption)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, embedded ? 12 : 40)
                    }
                    ForEach(subtitles.lines) { line in
                        VStack(alignment: .leading, spacing: 6) {
                            if subtitles.showsOriginal {
                                Text(line.source).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text(line.translation ?? (subtitles.phase.isActive ? "Translating…" : "Translation unavailable"))
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(line.translation == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }.fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                    }
                    if !subtitles.partial.isEmpty {
                        Text(subtitles.partial).font(.system(size: 13)).foregroundStyle(.tertiary)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(18)
            }
            .defaultScrollAnchor(subtitles.lines.isEmpty ? .top : .bottom)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: subtitles.lines) { _, _ in if followsLatest { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: subtitles.partial) { _, _ in if followsLatest { proxy.scrollTo("latest", anchor: .bottom) } }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                let value = subtitles.lines.compactMap(\.translation).joined(separator: "\n\n")
                guard !value.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
            }.disabled(!subtitles.lines.contains { $0.translation != nil })
            if !subtitles.phase.isActive, !subtitles.lines.isEmpty {
                Button("Clear") { subtitles.clear(); copied = false }
            }
            Spacer()
            if subtitles.phase == .finishing {
                ProgressView().controlSize(.small)
                Button("Cancel") { subtitles.cancel() }
            } else if subtitles.phase.isActive {
                Button(subtitles.phase == .connecting ? "Cancel" : "Stop") { subtitles.stop() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Start subtitles", systemImage: "play.fill") { subtitles.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var status: String {
        switch subtitles.phase {
        case .idle: return "System audio only"
        case .connecting: return "Connecting…"
        case .listening: return "Listening to system audio"
        case .finishing: return "Finishing…"
        case .failed: return "Stopped"
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
