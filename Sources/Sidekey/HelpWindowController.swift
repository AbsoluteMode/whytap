import AppKit
import SwiftUI

struct HelpHotkeyRowSpec: Equatable, Identifiable {
    var id: String { title }

    let title: String
    let detail: String
    let iconName: String
    let prefix: String?
    let contents: [KeycapContent]
}

enum HelpWindowContent {
    static let windowSize = CGSize(width: 520, height: 800)
    static let learningCenterURL = BuildConfig.landingURL.appendingPathComponent("blob/main/README.md")

    @MainActor
    static var hotkeyRows: [HelpHotkeyRowSpec] {
        hotkeyRows(for: .defaults)
    }

    /// Every assigned feature shortcut appears under its stable tool title.
    @MainActor
    static func hotkeyRows(
        for configuration: HotkeyConfiguration,
        includeAgent: Bool = true
    ) -> [HelpHotkeyRowSpec] {
        let rows = [
            HelpHotkeyRowSpec(
                title: "Drop — voice",
                detail: "\(configuration.normalizedDropGesture.voiceTitle) voice dictation. Transcript is pasted into the active app.",
                iconName: "mic",
                prefix: nil,
                contents: configuration.dropVoiceShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Agent — text",
                detail: "\(configuration.agentTextShortcut.title) — tap to open the input panel and type.",
                iconName: "sparkles",
                prefix: nil,
                contents: configuration.agentTextShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Agent — voice",
                detail: "\(configuration.agentVoiceShortcut.title) — \(configuration.agentVoiceGesture.voiceTitle.lowercased()) voice command.",
                iconName: "waveform",
                prefix: nil,
                contents: configuration.agentVoiceShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Google — text",
                detail: "\(configuration.googleSearchTextShortcut.title) — tap to open the search field and type.",
                iconName: "magnifyingglass",
                prefix: nil,
                contents: configuration.googleSearchTextShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Google — voice",
                detail: "\(configuration.googleSearchVoiceShortcut.title) — \(configuration.googleSearchVoiceGesture.voiceTitle.lowercased()) voice search.",
                iconName: "magnifyingglass",
                prefix: nil,
                contents: configuration.googleSearchVoiceShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Meeting record",
                detail: "Start a meeting recording anytime — even mid-call; press again to stop.",
                iconName: "record.circle",
                prefix: nil,
                contents: configuration.meetingRecordShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Agent close",
                detail: "Close the Agent response window.",
                iconName: "xmark.circle",
                prefix: nil,
                contents: configuration.agentCloseShortcut.contents
            ),
            // Bare Escape is a fixed (non-configurable) close for the agent
            // answer window. While the window is up, Whytap registers a
            // scoped Escape interceptor, so the first press closes the answer
            // instead of reaching the app underneath.
            HelpHotkeyRowSpec(
                title: "Close",
                detail: "The first Escape closes the visible Agent answer. The next reaches your app.",
                iconName: "escape",
                prefix: nil,
                contents: [.text("Esc")]
            ),
            // Case Approve prompt: fixed physical keys (any layout), taken only
            // while a prompt is on screen, after 300 ms without key presses. One row
            // per answer so the caps never read as a chord.
            HelpHotkeyRowSpec(
                title: "Case — allow",
                detail: "While a Case request is on screen, allow the command once. Works on any keyboard layout.",
                iconName: "checkmark.circle",
                prefix: nil,
                contents: [.text(CaseApprovalKey.yes.keycap)]
            ),
            HelpHotkeyRowSpec(
                title: "Case — deny",
                detail: "While a Case request is on screen, deny it. Escape denies too. Answer keys pause while editing minutes.",
                iconName: "xmark.octagon",
                prefix: nil,
                contents: [.text(CaseApprovalKey.no.keycap)]
            ),
            HelpHotkeyRowSpec(
                title: "Case — allow for minutes",
                detail: "While a Case request is on screen, let this app use this project without asking for the set minutes.",
                iconName: "timer",
                prefix: nil,
                contents: [.text(CaseApprovalKey.timed.keycap)]
            ),
            // ROO-208: the three per-mode rows (`⌥1` Agent / `⌥2` Drop /
            // `⌥3` Clipboard) collapse into a single unified-strip row.
            // Filter selection lives inside the strip's left sidebar.
            HelpHotkeyRowSpec(
                title: "History",
                detail: "Open the bottom strip with clipboard, voice drops, and agent history.",
                iconName: "clock",
                prefix: nil,
                contents: [.text(HotkeyGlyph.option), .text("V")]
            ),
            // ROO-208 iter 15: Raycast-style hover+Enter paste from the
            // bottom strip into the previously focused app.
            HelpHotkeyRowSpec(
                title: "History — paste",
                detail: "Hover a card in the bottom strip and press Return to paste it into the previously focused app.",
                iconName: "return",
                prefix: nil,
                contents: [.text("\u{21A9}")]
            ),
            HelpHotkeyRowSpec(
                title: "Help",
                detail: "Open this window.",
                iconName: "questionmark.circle",
                prefix: nil,
                contents: [.text(HotkeyGlyph.option), .text("H")]
            ),
            HelpHotkeyRowSpec(
                title: "Useful Links — insert",
                detail: "Paste the selected link's URL into the previously focused app.",
                iconName: "square.and.arrow.down.on.square",
                prefix: nil,
                contents: configuration.usefulLinksInsertShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Useful Links — open",
                detail: "Open the selected link in the default browser.",
                iconName: "arrow.up.right.square",
                prefix: nil,
                contents: configuration.usefulLinksOpenShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Useful Links — down",
                detail: "Move the selection marker to the next link in the list.",
                iconName: "arrow.down",
                prefix: nil,
                contents: configuration.usefulLinksNextShortcut.contents
            ),
            HelpHotkeyRowSpec(
                title: "Useful Links — up",
                detail: "Move the selection marker to the previous link in the list.",
                iconName: "arrow.up",
                prefix: nil,
                contents: configuration.usefulLinksPreviousShortcut.contents
            )
        ] + toolHotkeyRows(for: configuration) + screenshotEditorRows(for: configuration)
        guard !includeAgent else { return rows }
        return rows.filter { !$0.title.hasPrefix("Agent") }
    }

    private static func toolHotkeyRows(for configuration: HotkeyConfiguration) -> [HelpHotkeyRowSpec] {
        HoverTool.allCases.compactMap { tool in
            guard let shortcut = configuration.toolShortcuts[tool] else { return nil }
            let info = HoverToolRegistry.info(for: tool)
            return HelpHotkeyRowSpec(title: "Tool — \(info.title)", detail: info.description,
                                     iconName: info.sfSymbol, prefix: nil, contents: shortcut.contents)
        }
    }

    private static func screenshotEditorRows(for configuration: HotkeyConfiguration) -> [HelpHotkeyRowSpec] {
        ScreenshotArrow.allCases.map { arrow in
            let action = configuration.screenshotArrowBindings[arrow]
            return HelpHotkeyRowSpec(title: "Screenshot — \(arrow.glyph)", detail: "\(action.title). Screenshot takes priority over Agent; text fields keep cursor navigation.",
                                     iconName: action.symbol, prefix: nil, contents: [.text(arrow.glyph)])
        } + ScreenshotEditorKeys.tools.map { entry in
            HelpHotkeyRowSpec(title: "Screenshot — \(entry.title)", detail: entry.tool == .text ? "Click inside the selection to type. Click a label to edit; drag its hover handle to move." : "While the screenshot editor is open.",
                              iconName: "viewfinder", prefix: nil, contents: [.text(entry.key.uppercased())])
        } + [
            HelpHotkeyRowSpec(title: "Screenshot — copy", detail: "Copy the edited image and finish capture.", iconName: "doc.on.doc", prefix: nil, contents: [.text(HotkeyGlyph.command), .text("C")]),
            HelpHotkeyRowSpec(title: "Screenshot — download", detail: "Download PNG to Downloads and show its filename.", iconName: "arrow.down.to.line", prefix: nil, contents: [.text(HotkeyGlyph.command), .text("S")]),
            HelpHotkeyRowSpec(title: "Screenshot — copy and close", detail: "After selecting an area, copy the edited image and close the editor. Waits for pending Blur or Download.", iconName: "return", prefix: nil, contents: [.text("Return")]),
            HelpHotkeyRowSpec(title: "Screenshot — new text line", detail: "Insert a line break while editing a label directly on the screenshot.", iconName: "textformat", prefix: nil, contents: [.text(HotkeyGlyph.shift), .text("Return")]),
            HelpHotkeyRowSpec(title: "Screenshot — move text", detail: "Tab to the visible label handle, then use arrows (Shift: 10 points). Return edits the label.", iconName: "arrow.up.and.down.and.arrow.left.and.right", prefix: nil, contents: [.text("←"), .text("↑"), .text("↓"), .text("→")]),
            HelpHotkeyRowSpec(title: "Screenshot — undo", detail: "Undo a crop or annotation.", iconName: "arrow.uturn.backward", prefix: nil, contents: [.text(HotkeyGlyph.command), .text("Z")]),
            HelpHotkeyRowSpec(title: "Screenshot — redo", detail: "Redo the last undone change.", iconName: "arrow.uturn.forward", prefix: nil, contents: [.text(HotkeyGlyph.command), .text(HotkeyGlyph.shift), .text("Z")]),
            HelpHotkeyRowSpec(title: "Screenshot — next control", detail: "Move focus to the next enabled toolbar or tool-settings control.", iconName: "arrow.right", prefix: nil, contents: [.text("Tab")]),
            HelpHotkeyRowSpec(title: "Screenshot — previous control", detail: "Move focus to the previous enabled toolbar or tool-settings control.", iconName: "arrow.left", prefix: nil, contents: [.text(HotkeyGlyph.shift), .text("Tab")]),
            HelpHotkeyRowSpec(title: "Screenshot — move crop", detail: "Shift-arrows move the crop 10 points; Option-arrows resize. Assign Move crop by clicking a shortcut pair in the screenshot toolbar.", iconName: "arrow.up.left.and.arrow.down.right", prefix: nil, contents: [.text(HotkeyGlyph.shift), .text("←"), .text("↑"), .text("↓"), .text("→")]),
            HelpHotkeyRowSpec(title: "Screenshot — cancel", detail: "Cancel the current text edit or drawing, then cancel capture.", iconName: "escape", prefix: nil, contents: [.text("Esc")]),
            HelpHotkeyRowSpec(title: "Screenshot — delete annotation", detail: "Remove the selected annotation.", iconName: "delete.left", prefix: nil, contents: [.text("Delete")])
        ]
    }
}

@MainActor
final class HelpWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let hosting = NSHostingController(rootView: HelpView())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: HelpWindowContent.windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whytap Hotkeys"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        SidekeyWindowChrome.configureHoverOverlayPolicy(window)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("HelpWindowController only supports programmatic init.")
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            SidekeyWindowChrome.centerOnMainScreen(window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            SidekeyWindowChrome.centerOnMainScreen(window)
        }
    }
}

private struct HelpView: View {
    @ObservedObject private var hotkeys: HotkeyPreferences
    @ObservedObject private var agentProviders: AgentProviderStore

    @MainActor
    init(
        hotkeys: HotkeyPreferences? = nil,
        agentProviders: AgentProviderStore? = nil
    ) {
        self.hotkeys = hotkeys ?? .shared
        self.agentProviders = agentProviders ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Help")
                    .font(.system(size: 28, weight: .semibold))
                Text("Shortcuts, guides, and answers for Whytap.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                NSWorkspace.shared.open(HelpWindowContent.learningCenterURL)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "book.pages")
                    Text("Open Learning Center & FAQ")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(
                        HelpWindowContent.hotkeyRows(
                        for: hotkeys.configuration,
                        includeAgent: agentProviders.activeProvider != nil
                    )
                    ) { row in
                        HotkeyRow(row: row)
                    }
                }
            }

            Spacer()

            HStack {
                Label("Press Esc or click the close button to dismiss.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
        .padding(28)
        .frame(width: HelpWindowContent.windowSize.width, height: HelpWindowContent.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HotkeyRow: View {
    let title: String
    let detail: String
    let iconName: String
    /// Optional gesture verb that sits IN the hotkey hint cluster
    /// ("Tap", "Hold"). The row's `title` already carries the
    /// human-readable name on the left — `prefix` only shows when the
    /// hotkey itself needs disambiguation between tap vs. hold of the
    /// same modifier key.
    let prefix: String?
    /// Heterogeneous list of caps shown in the hint chip. Most rows pass
    /// plain text caps (e.g. ⌥ + Q); the Useful Links rows mix a text
    /// modifier cap with an SF Symbol chevron arrow cap to match the
    /// macOS-native keycap aesthetic.
    let contents: [KeycapContent]

    init(row: HelpHotkeyRowSpec) {
        self.title = row.title
        self.detail = row.detail
        self.iconName = row.iconName
        self.prefix = row.prefix
        self.contents = row.contents
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Shared `HotkeyHintView` so every row in this window
            // renders the keycaps with the same chip style, spacing,
            // and VoiceOver pronunciation as the response panel close
            // row and the floating Keybindings hint.
            HotkeyHintView(label: prefix, contents: contents)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
