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
    /// The floating panel's click dispatch. The Toolbox pane watches
    /// the copy target through a local event monitor.
    @ObservedObject var hitTargets = SubtitleOverlayHitTargets()
    /// Copies the text translation and says "Copied ✓" for a moment; the
    /// controller owns it, so the floating window and the Toolbox pane keep it.
    @ObservedObject var copier = TranslationView.makeCopier()
    /// The overlay caption's scroll position; the controller owns it, so the
    /// panel can hand it scroll events.
    @ObservedObject var scroll = SubtitleCaptionScroll()
    @State private var closeHovered = false
    @State private var latestHovered = false
    @FocusState private var inputFocused: Bool
    @FocusState private var resultFocused: Bool
    @State private var inputHovered = false
    @State private var resultHovered = false
    /// The running overlay's controls: shown on hover and kept for
    /// `controlsLinger` after the pointer leaves, so a press that briefly
    /// loses hover (the panel turning key, a tooltip) still lands on Stop or ×.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    @State private var controlsShown = false
    @State private var hideControls: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isText: Bool { presentation.mode == .text }

    var body: some View {
        Group {
            if isText { textContent } else { subtitleContent }
        }
        // Subtitles fit the panel's own minimum (360 pt); no wider floor here.
        .frame(minWidth: embedded || !isText ? 0 : 320, maxWidth: .infinity,
               minHeight: embedded ? 0 : (isText ? 80 : 120), maxHeight: .infinity)
        .background { if !embedded && isText { Rectangle().fill(.regularMaterial) } }
        .onAppear { if isText && embedded { inputFocused = true } }
        .onChange(of: presentation.mode) { _, mode in if mode == .text && embedded { inputFocused = true } }
        .onChange(of: presentation.isTextPresented) { _, visible in
            if !embedded && !visible { inputFocused = false }
        }
        // The Toolbox pane's window is Settings: its clicks on the text
        // translation reach the copy target through a local monitor.
        .onAppear { if embedded { hitTargets.startLocalCopyDispatch() } }
        .onDisappear { if embedded { hitTargets.stopLocalCopyDispatch() } }
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
            .disabled(subtitles.phase.isRunning)
    }

    private var targetPicker: some View {
        MacPopup(items: languageItems, selection: $subtitles.targetCode, maxWidth: embedded ? 130 : 150, appearance: .adaptive)
            .accessibilityLabel("Translate to")
            .disabled(subtitles.phase.isRunning)
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
                .accessibilityHint("Press Return to translate. Click the translation to copy it. Right-click for language options.")
            ScrollView {
                Group {
                    if let issue = text.issue, let feature = issue.feature {
                        Button { openSettings(feature) } label: {
                            Text(issue.message + " Open Keys & models →")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(MacButtonInteractionStyle(highlight: .primary, focused: settingsFocused))
                        .focused($settingsFocused)
                    } else if canCopyTranslation {
                        // A click anywhere in the result block copies the whole
                        // translation; a drag still selects part of it (the
                        // click is only watched). Tint and target: the block below.
                        // WHY: .project-docs/decisions/2026-11-24-click-to-copy-translation.md
                        Text(textOutput)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusable(interactions: .activate)
                            .focused($resultFocused)
                            .onKeyPress(.return) {
                                copyTranslation()
                                return .handled
                            }
                            .accessibilityAction(named: "Copy translation", copyTranslation)
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
            // The whole result block is the copy target and lights up, not
            // just the text's lines (Maxim, 2026-11-25).
            // WHY: .project-docs/decisions/2026-11-24-click-to-copy-translation.md
            .contentShape(Rectangle())
            .background {
                let opacity = !canCopyTranslation ? 0 : (hitTargets.pressed == .copy ? 0.14 : (resultHovered ? 0.08 : 0))
                Rectangle().fill(.primary.opacity(opacity))
            }
            .background(Color.black.opacity(0.08))
            .background {
                if canCopyTranslation {
                    SubtitleOverlayHitReporter(control: .copy, targets: hitTargets, action: "copy",
                                               activate: copyTranslation)
                }
            }
            .onHover { resultHovered = $0 }
            .onDisappear { resultHovered = false }
            .overlay {
                if resultFocused && canCopyTranslation {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .help(canCopyTranslation ? "Click the translation or focus it and press Return to copy" : "")
            .overlay(alignment: .bottomTrailing) { if copier.copied { copiedBadge.padding(8) } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: copier.copied)
            .accessibilityLabel("Translation")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy translation") { copyTranslation() }.disabled(!canCopyTranslation)
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

    private var canCopyTranslation: Bool {
        !text.result.isEmpty && !inputTooLong && !text.isTranslating && text.issue == nil
    }

    private func copyTranslation() {
        guard canCopyTranslation else { return }
        copier.copy(text.result)
    }

    /// How long "Copied ✓" shows after a translation is copied.
    static let copiedShownFor: Duration = .seconds(1)

    /// Writes to `pasteboard` and tells VoiceOver, which does not see the badge.
    static func makeCopier(pasteboard: NSPasteboard = .general) -> PromptCopier {
        PromptCopier(copy: { value in
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: "Copied",
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }, shownFor: copiedShownFor)
    }

    private var copiedBadge: some View {
        HStack(spacing: 4) {
            Text("Copied")
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // WHY: .project-docs/decisions/2026-11-21-compact-subtitle-overlay.md
    // The original RealtimeTranslator overlay: a bottom-anchored dark caption
    // box of at most five lines. Only the language pair and Start/Stop were added.
    // Its content is phrase pairs, original beside translation.
    // WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
    @ViewBuilder private var subtitleContent: some View {
        let rows = SubtitleCaption.rows(lines: subtitles.lines, live: subtitles.live,
                                        liveTranslation: subtitles.liveTranslation, liveID: subtitles.liveID,
                                        limit: embedded ? SubtitleCaption.maxPairs
                                            : scroll.isFollowing
                                                ? SubtitleCaptionScroll.followedLimit(height: scroll.viewportHeight,
                                                                                      minimum: Self.followedPairs)
                                                : SubtitleCaption.historyPairs)
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
            // The box fills the panel the user moved and sized
            // (`SubtitleOverlayFrame`), so its size depends only on the panel,
            // never on what it shows: controls never move and no text reflows.
            // WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
            // WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
            VStack(alignment: .leading, spacing: 10) {
                if !subtitles.phase.isRunning { subtitleControls }
                overlayCaption(rows)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .layoutPriority(-1)
                if let feature = subtitles.issue?.feature {
                    // The panel is never key: the window dispatches the
                    // first click (`SubtitleOverlayHitTargets`), as for Stop.
                    Button("Open Keys & models") { openSettings(feature) }.controlSize(.small)
                        .background(SubtitleOverlayHitReporter(control: .fix, targets: hitTargets,
                                                               action: "fix-\(feature.rawValue)",
                                                               activate: { openSettings(feature) }))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The video under the box is blurred, then darkened enough for
            // white text on any picture.
            .background {
                ZStack {
                    IslandVisualEffectBackground(material: .hudWindow)
                    Color.black.opacity(Self.overlayTint)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            // While running, the controls cover the top of the caption on
            // hover instead of pushing it: Stop and × stay in one place.
            .overlay(alignment: .top) {
                if subtitles.phase.isRunning && controlsShown {
                    subtitleControls
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.black.opacity(0.88),
                                    in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                        .transition(.opacity)
                }
            }
            .shadow(radius: 5)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onHover(perform: overlayHover)
            .contextMenu { subtitleMenu }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: controlsShown)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: subtitles.phase)
            .padding(SubtitleOverlayFrame.margin)
            // The margin around the box is the edge a press resizes; fully
            // clear pixels would let that press through to the app below.
            .background(Color.black.opacity(Self.marginOpacity))
            .onChange(of: subtitles.phase) { _, phase in if phase == .connecting { scroll.reset() } }
            .onChange(of: subtitles.lines.isEmpty) { _, empty in if empty { scroll.reset() } }
        }
    }

    /// Barely there: enough for the window server to give the margin's
    /// presses to the panel, invisible over any picture.
    static let marginOpacity = 0.012

    /// The overlay's caption area: a status, the hint before the first
    /// session, or the pairs with their scroll position.
    @ViewBuilder private func overlayCaption(_ rows: [SubtitleCaption.Row]) -> some View {
        if let status = SubtitleCaption.status(hasRows: !rows.isEmpty, phase: subtitles.phase, issue: subtitles.issue) {
            captionText(status, compact: subtitles.issue != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: subtitles.issue == nil ? .bottomLeading : .topLeading)
                // Inside the caption, so the box keeps its size when audio starts.
                .overlay(alignment: .bottomTrailing) {
                    if waitingWithoutAudio {
                        audioPermissionsButton
                            .background(SubtitleOverlayHitReporter(control: .audio, targets: hitTargets, action: "audio",
                                                                   activate: { Self.openAudioPermissions() }))
                    }
                }
                .clipped()
        } else if rows.isEmpty {
            Text(Self.idleHint)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(Self.idleHintOpacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            caption(rows)
                .overlay(alignment: .bottomTrailing) { if !scroll.isFollowing { latestButton } }
                // The size a scroll works with is the caption's on screen,
                // not a measurement pass's (`SubtitleCaptionGeometry`).
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [scroll] size in scroll.setViewport(size) }
        }
    }

    /// Before the first session the box explains its one action.
    static let idleHint = "Start translates what this Mac plays."
    /// Dim, but at least 4.5:1 against the box over a bright picture.
    static let idleHintOpacity = 0.68

    /// Back to the newest pairs after scrolling back.
    private var latestButton: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
            Text("Latest")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(latestFill))
        .overlay(Capsule().strokeBorder(.white.opacity(latestHovered ? 0.45 : 0.18)))
        .onHover { latestHovered = $0 }
        .background(SubtitleOverlayHitReporter(control: .latest, targets: hitTargets, action: "latest",
                                               activate: { [scroll] in scroll.follow() }))
        .padding(4)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Show latest subtitles")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { scroll.follow() }
    }

    /// How long the running overlay keeps its controls after hover ends.
    static let controlsLinger: Duration = .seconds(1)

    private func overlayHover(_ hovering: Bool) {
        hideControls?.cancel()
        guard !hovering else { controlsShown = true; return }
        hideControls = Task { @MainActor in
            try? await Task.sleep(for: Self.controlsLinger)
            guard !Task.isCancelled else { return }
            controlsShown = false
        }
    }

    /// Darkening over the blurred background (the box was a flat 60 % black
    /// before the blur).
    static let overlayTint = 0.45

    /// The running caption of the default 190 pt panel: five lines of the
    /// 18 pt translation, as many as the original overlay showed. A resized
    /// panel's caption takes the box's whole inner area instead.
    static let captionHeight: CGFloat = 146
    /// The original's share of the width: Russian runs about a fifth longer
    /// than English and is the line being read.
    static let sourceFraction: CGFloat = 0.38

    /// The default overlay panel is 760 pt wide: 10 pt outside and 16 pt inside the box.
    static let overlayContentWidth: CGFloat = 760 - 2 * 10 - 2 * 16

    /// Pairs laid out while following: more than a tall box shows, so a
    /// scroll back starts with something above. Scrolled back, the whole
    /// history (`SubtitleCaption.historyPairs`).
    static let followedPairs = 24

    /// "Open audio permissions" only when the silence may be macOS
    /// withholding system audio, never while a granted Mac is just quiet.
    // WHY: .project-docs/decisions/2026-11-25-system-audio-heard-means-allowed.md
    private var waitingWithoutAudio: Bool {
        subtitles.phase == .listening && subtitles.silenceMayMeanNoAccess
            && subtitles.lines.isEmpty && subtitles.live.isEmpty
    }

    /// Pairs when there are phrases, otherwise one status line. In the
    /// overlay the caption has a fixed size: pairs are bottom-anchored with a
    /// fixed column split, the live pair settles in place, and older lines
    /// leave at the top as new ones push them up. Toolbox keeps whole pairs.
    @ViewBuilder private func caption(_ rows: [SubtitleCaption.Row]) -> some View {
        if let status = SubtitleCaption.status(hasRows: !rows.isEmpty, phase: subtitles.phase, issue: subtitles.issue) {
            captionText(status, compact: subtitles.issue != nil)
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
            // Bottom-anchored, clipped at the top with a short fade: new text
            // pushes older lines up smoothly, a line at a time.
            let layout = SteadyPairsLayout(rowSpacing: 8, columnSpacing: 18, sourceFraction: Self.sourceFraction,
                                           size: CGSize(width: Self.overlayContentWidth, height: Self.captionHeight),
                                           inset: Self.bandInset, fills: true, anchor: scroll.anchor,
                                           geometry: scroll.geometry)
            layout {
                ForEach(rows) { row in
                    Group {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.white.opacity(row.ordinal.isMultiple(of: 2) ? Self.bandOpacity : 0))
                            .layoutValue(key: SubtitleRowID.self, value: row.id)
                        sourceText(row).modifier(NewestLinesColumn())
                        translationText(row).modifier(NewestLinesColumn())
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
            .mask {
                // Scrolled back, the bottom fades too: newer pairs wait below.
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: SteadyPairsLayout.topFade)]
                                   + (scroll.isFollowing ? [] : [.init(color: .black, location: 0.9),
                                                                 .init(color: .clear, location: 1)]),
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: rows)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Subtitles")
        }
    }

    /// Every other pair sits on a faint band, so where one chunk ends and the
    /// next begins is visible at a glance (chosen by the user from dots, an
    /// accent first letter and bands). The band follows the pair's position
    /// in the session, so it never jumps when an old pair leaves.
    // WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
    static let bandOpacity = 0.07
    static let bandInset = CGSize(width: 8, height: 3)

    private func sourceText(_ row: SubtitleCaption.Row) -> some View {
        Text(row.source)
            .font(.system(size: embedded ? 12 : 15, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(row.isLive ? 0.42 : 0.6))
            .lineSpacing(2)
    }

    /// Toolbox pairs: the pane is too narrow for two columns, so the original
    /// sits above its translation.
    @ViewBuilder private func pairRow(_ row: SubtitleCaption.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !row.source.isEmpty { sourceText(row).frame(maxWidth: .infinity, alignment: .leading) }
            translationText(row).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.bandInset.width)
        .padding(.vertical, Self.bandInset.height)
        .background {
            if row.ordinal.isMultiple(of: 2) {
                RoundedRectangle(cornerRadius: 7).fill(.white.opacity(Self.bandOpacity))
            }
        }
    }

    @ViewBuilder private func translationText(_ row: SubtitleCaption.Row) -> some View {
        switch row.translation {
        case .text(let value):
            Text(value)
                .font(.system(size: embedded ? 14 : 18, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineSpacing(2)
        case .live(let value):
            // Still being spoken by the speech translator.
            Text(value)
                .font(.system(size: embedded ? 14 : 18, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineSpacing(2)
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

    /// `compact`: a problem's message, smaller, so it and its fix fit the panel.
    private func captionText(_ value: String, compact: Bool = false) -> some View {
        // At most five lines; the box height hugs shorter text (its width spans
        // the panel, as in the original) and older words leave
        // at the top, so the newest line never moves.
        Text(value)
            .font(.system(size: embedded || compact ? 15 : 20, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineSpacing(3)
            .lineLimit(compact ? 3 : 5)
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
        // A press on the menus is theirs; the rest of the row moves the overlay.
        .background { if !embedded { SubtitleOverlayHitReporter(control: .controls, targets: hitTargets,
                                                                 action: "languages", activate: {}) } }
    }

    /// The session button's click goes through the window (`hitTargets`)
    /// bound to the action drawn now (Start, Cancel or Stop, with its
    /// session), never to the phase at mouse-up: the model runs it only while
    /// it is still the action shown. A press whose action changes is dropped.
    private var sessionButton: some View {
        let action = subtitles.sessionAction
        let model = subtitles
        return sessionButtonBody(action)
            // The window takes the click, so the button shows the press itself.
            .opacity(hitTargets.pressed == .session ? 0.6 : 1)
            .background(SubtitleOverlayHitReporter(
                control: .session, targets: hitTargets,
                action: String(describing: action),
                activate: { model.perform(action) }))
    }

    @ViewBuilder private func sessionButtonBody(_ action: SubtitleSessionAction) -> some View {
        switch action {
        case .cancel:
            Button("Cancel") { subtitles.perform(action) }
        case .stop:
            Button("Stop", systemImage: "stop.fill") { subtitles.perform(action) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Stop subtitles")
        case .start:
            // After Stop the session shows as stopped at once; the last
            // translation still settles in the background.
            Button("Start", systemImage: "play.fill") { subtitles.perform(action) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Start subtitles")
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            // A 28 pt target, Stop's height. No tooltip: its window could
            // take hover from the running overlay's controls mid-press.
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                // Hover and press show the whole 28 pt target.
                .background(Circle().fill(.white.opacity(hitTargets.pressed == .close ? 0.22 : closeHovered ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(closeHovered ? .primary : .secondary)
        .onHover { closeHovered = $0 }
        .background(SubtitleOverlayHitReporter(control: .close, targets: hitTargets, action: "close", activate: close))
        .accessibilityLabel("Close subtitles")
    }

    /// Latest lightens under the pointer and darkens while pressed.
    private var latestFill: Color {
        if hitTargets.pressed == .latest { return Color.black.opacity(0.55) }
        return latestHovered ? Color(white: 0.24).opacity(0.92) : Color.black.opacity(0.78)
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    static func openAudioPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            openURL(url)
        }
    }

    /// Opens a System Settings pane (tests record instead).
    nonisolated(unsafe) static var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var audioPermissionsButton: some View {
        Button("Open audio permissions") { Self.openAudioPermissions() }
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
                Button("Keys & models") { openSettings(feature) }.controlSize(.small)
            }
        }.padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
