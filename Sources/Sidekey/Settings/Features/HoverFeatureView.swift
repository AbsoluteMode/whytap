import SwiftUI

/// Settings -> Features -> Hover: the island's tools as a list. The order of
/// the list is the order in the island; a switch takes a tool out of the
/// island or puts it back. Tools are reordered in the island itself (hold a
/// tile, drag it); here the order is shown, with Move Up/Down in the context
/// menu and VoiceOver actions for keyboard use. Every change goes straight to
/// `HoverLayoutStore`, which the island observes. A tool's own shortcut stays
/// on its row.
// WHY: .project-docs/decisions/2026-11-24-hover-notify-monitor-screens.md
// WHY: .project-docs/decisions/2026-11-25-island-hover-reorder.md
@MainActor
struct HoverFeatureView: View {
    @ObservedObject var selection: SettingsWindowSelection
    @ObservedObject private var store: HoverLayoutStore
    @ObservedObject private var hotkeys: HotkeyPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let environment: FeaturesEnvironment

    init(selection: SettingsWindowSelection, environment: FeaturesEnvironment) {
        self.selection = selection
        self.environment = environment
        self.store = environment.hoverStore
        self.hotkeys = environment.hotkeys
    }

    static let about = "Small tools that open when you hover the notch. The island shows them in this order, "
        + "left to right, row by row. To change the order, hold a tool in the island and drag it; "
        + "switch off the ones you don’t need here, or drag one out of the island. "
        + "Search all tools in the island still finds a tool that is off, and its shortcut keeps working."

    var body: some View {
        let layout = HoverToolLayout(slots: store.slots)
        let info = FeatureCatalog.info(for: .hover)
        FeatureScreenScaffold {
            FeatureScreenHeader(info: info, about: Self.about) {
                selection.shownFeature = nil
            }
            FeatureVideoStrip(info: info)
            VStack(alignment: .leading, spacing: 0) {
                MacGroupTitle(title: "In the island", trailing: HoverToolLayout.countText(layout.inIsland.count))
                MacCard {
                    ForEach(Array(layout.inIsland.enumerated()), id: \.element) { index, tool in
                        if index > 0 { MacRowSeparator() }
                        row(tool, isOn: true, layout: layout)
                    }
                    if !layout.inIsland.isEmpty { MacRowSeparator() }
                    HoverPinnedSettingsRow()
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                MacGroupTitle(title: "More tools", trailing: layout.offIsland.isEmpty ? nil : "Off")
                MacCard {
                    if layout.offIsland.isEmpty {
                        Text("Every tool is in the island.")
                            .font(.system(size: 12))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 14)
                    } else {
                        ForEach(Array(layout.offIsland.enumerated()), id: \.element) { index, tool in
                            if index > 0 { MacRowSeparator() }
                            row(tool, isOn: false, layout: layout)
                        }
                    }
                }
            }
        }
    }

    private func row(_ tool: HoverTool, isOn: Bool, layout: HoverToolLayout) -> some View {
        HoverToolRow(
            tool: tool,
            isOn: isOn,
            shortcut: hotkeys.toolShortcuts[tool]?.contents ?? [],
            hotkeys: hotkeys,
            canMoveUp: layout.canMoveUp(tool),
            canMoveDown: layout.canMoveDown(tool),
            setOn: { on in withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { layout.set(tool, on: on, in: store) } },
            move: { step in withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { layout.move(tool, by: step, in: store) } },
            destination: destination(for: tool)
        )
    }

    /// Where a tool's own settings are: its feature's screen, or its pane in
    /// Toolbox. Tools that only act (Quit) have none.
    // WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
    private func destination(for tool: HoverTool) -> HoverToolRow.Destination? {
        switch tool {
        case .notifs: return .init(title: "Customize") { selection.shownFeature = .notify }
        case .monitor: return .init(title: "Customize") { selection.shownFeature = .monitor }
        case .translate, .subtitles: return .init(title: "Set up") { selection.open(.translateSubtitles) }
        case .screenshot: return .init(title: "Set up") { selection.open(.screenshots) }
        // Drop's mode, languages and words are on Drop's screen.
        case .dropMode, .vocab, .filler, .inputLang, .outputLang:
            return .init(title: "Drop settings") { selection.open(.drop) }
        case .meetingRecord, .notes: return .init(title: "Meeting Notes settings") { selection.open(.meetings) }
        case .quit, .settings: return nil
        default:
            if let feature = Self.feature(for: tool) {
                return .init(title: "\(FeatureCatalog.info(for: feature).name) settings") { selection.open(feature) }
            }
            return .init(title: "Open in Toolbox") { selection.focus(tool) }
        }
    }

    /// The feature whose own screen shows this island tool (Subtitles is
    /// Translate & Subtitles', the second of its tools).
    static func feature(for tool: HoverTool) -> AppFeature? {
        FeatureCatalog.all.first { info in
            if case .islandTools(let tools) = info.activation { return tools.contains(tool) }
            return false
        }?.feature
    }
}

/// The island's tools split the way the screen shows them: the ones in the
/// island in their order (Settings, always last, is drawn on its own), and
/// the others in the catalog order.
struct HoverToolLayout: Equatable {
    let inIsland: [HoverTool]
    let offIsland: [HoverTool]

    init(slots: [HoverTool]) {
        inIsland = slots.filter { $0 != .settings }
        offIsland = HoverLayoutStore.unpinnedTools(from: slots)
    }

    static func countText(_ count: Int) -> String {
        count == 1 ? "1 tool" : "\(count) tools"
    }

    func canMoveUp(_ tool: HoverTool) -> Bool {
        guard let index = inIsland.firstIndex(of: tool) else { return false }
        return index > 0
    }

    func canMoveDown(_ tool: HoverTool) -> Bool {
        guard let index = inIsland.firstIndex(of: tool) else { return false }
        return index < inIsland.count - 1
    }

    /// A switched-on tool joins the end of the island, before Settings.
    @MainActor
    func set(_ tool: HoverTool, on: Bool, in store: HoverLayoutStore) {
        if on { store.pin(tool) } else { store.unpin(tool) }
    }

    /// One place up (-1), down (+1), or to the top (`Int.min`).
    @MainActor
    func move(_ tool: HoverTool, by step: Int, in store: HoverLayoutStore) {
        guard let index = store.slots.firstIndex(of: tool), tool != .settings else { return }
        let target = step == .min ? 0 : index + step
        guard target >= 0, target < store.lockSlotIndex else { return }
        store.placeTool(tool, at: target)
    }
}

/// One tool: its mark, name and what it does, its shortcut, and the switch
/// that shows it in the island. The chevron opens
/// the shortcut editor and the way to the tool's own settings.
@MainActor
struct HoverToolRow: View {
    struct Destination {
        let title: String
        let open: () -> Void
    }

    let tool: HoverTool
    let isOn: Bool
    let shortcut: [KeycapContent]
    let hotkeys: HotkeyPreferences
    let canMoveUp: Bool
    let canMoveDown: Bool
    let setOn: (Bool) -> Void
    let move: (Int) -> Void
    let destination: Destination?
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var chevronFocused: Bool

    private var info: HoverToolInfo { HoverToolRegistry.info(for: tool) }

    private var description: String {
        tool.isComingSoon ? "\(info.description). \(CalendarAvailability.message)" : info.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                summary
                Spacer(minLength: 10)
                if !shortcut.isEmpty {
                    FeatureShortcutKeys(contents: shortcut)
                }
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MacButtonInteractionStyle(focused: chevronFocused))
                .focused($chevronFocused)
                .help(expanded ? "Hide shortcut and options" : "Shortcut and options")
                .accessibilityLabel(expanded ? "Hide \(info.title) shortcut and options" : "\(info.title) shortcut and options")
                MacSwitch(isOn: Binding(get: { isOn }, set: setOn), label: "Show \(info.title) in the island")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 50)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ToolboxHotkeyBlock(tool: tool, preferences: hotkeys)
                    if let destination {
                        MacButton(title: destination.title, style: .ghost, action: destination.open)
                            .fixedSize()
                            .accessibilityLabel("\(destination.title): \(info.title)")
                    }
                }
                .padding(.leading, 53)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
        .background(hovering ? MacSettingsTheme.hover.opacity(0.35) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(info.title)
        .accessibilityValue(isOn ? "In the island" : "Off")
        .accessibilityActions {
            if canMoveUp {
                Button("Move up") { move(-1) }
                Button("Move to top") { move(.min) }
            }
            if canMoveDown {
                Button("Move down") { move(1) }
            }
        }
    }

    /// Mark and words.
    private var summary: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(MacSettingsTheme.hover).frame(width: 28, height: 28)
                Image(systemName: info.sfSymbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isOn ? MacSettingsTheme.text : MacSettingsTheme.text2)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text)
                    if let badge = tool.comingSoonBadge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(MacSettingsTheme.text2)
                    }
                }
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if isOn {
            Button("Move Up") { move(-1) }.disabled(!canMoveUp)
            Button("Move Down") { move(1) }.disabled(!canMoveDown)
            Button("Move to Top") { move(.min) }.disabled(!canMoveUp)
            Divider()
            Button("Remove from the Island") { setOn(false) }
        } else {
            Button("Add to the Island") { setOn(true) }
        }
    }
}

/// Settings closes the island's tools and cannot be moved or switched off.
struct HoverPinnedSettingsRow: View {
    var body: some View {
        let info = HoverToolRegistry.info(for: .settings)
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(MacSettingsTheme.hover).frame(width: 28, height: 28)
                Image(systemName: info.sfSymbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                Text("Always last in the island, so Settings is one hover away.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            Spacer(minLength: 10)
            Label("Always on", systemImage: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}
