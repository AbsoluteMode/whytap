import SwiftUI
import UniformTypeIdentifiers

/// Settings -> Features -> Hover: the island's tools as a list. The order of
/// the list is the order in the island; a tool is held and dragged to a new
/// place, and a switch takes it out of the island or puts it back. Every
/// change goes straight to `HoverLayoutStore`, which the island observes, so
/// the island shows it at once. A tool's own shortcut stays on its row.
// WHY: .project-docs/decisions/2026-11-24-hover-notify-monitor-screens.md
@MainActor
struct HoverFeatureView: View {
    @ObservedObject var selection: SettingsWindowSelection
    @ObservedObject private var store: HoverLayoutStore
    @ObservedObject private var hotkeys: HotkeyPreferences
    @StateObject private var drag: HoverToolDragModel
    private let environment: FeaturesEnvironment

    init(selection: SettingsWindowSelection, environment: FeaturesEnvironment) {
        self.selection = selection
        self.environment = environment
        self.store = environment.hoverStore
        self.hotkeys = environment.hotkeys
        _drag = StateObject(wrappedValue: HoverToolDragModel(store: environment.hoverStore))
    }

    static let about = "Small tools that open when you hover the notch. The island shows them in this order, "
        + "left to right, row by row. Hold a tool and drag it to a new place; switch off the ones you don’t need. "
        + "Search all tools in the island still finds a tool that is off, and its shortcut keeps working."

    var body: some View {
        let layout = HoverToolLayout(slots: store.slots)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IslandFeatureHeader(info: FeatureCatalog.info(for: .hover), about: Self.about) {
                    selection.shownFeature = nil
                }
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "In the island", trailing: HoverToolLayout.countText(layout.inIsland.count))
                    MacCard {
                        ForEach(Array(layout.inIsland.enumerated()), id: \.element) { index, tool in
                            if index > 0 { MacRowSeparator() }
                            row(tool, isOn: true, layout: layout)
                                .onDrop(of: [.text], delegate: HoverToolDropDelegate(target: .tool(tool), model: drag))
                        }
                        if !layout.inIsland.isEmpty { MacRowSeparator() }
                        HoverPinnedSettingsRow()
                            .onDrop(of: [.text], delegate: HoverToolDropDelegate(target: .end, model: drag))
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
                    // Dropping a tool here takes it out of the island.
                    .onDrop(of: [.text], delegate: HoverToolDropDelegate(target: .off, model: drag))
                }
            }
            .frame(maxWidth: SettingsFeaturesView.contentWidth, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onDisappear { drag.end() }
    }

    private func row(_ tool: HoverTool, isOn: Bool, layout: HoverToolLayout) -> some View {
        HoverToolRow(
            tool: tool,
            isOn: isOn,
            shortcut: hotkeys.toolShortcuts[tool]?.contents ?? [],
            hotkeys: hotkeys,
            canMoveUp: layout.canMoveUp(tool),
            canMoveDown: layout.canMoveDown(tool),
            setOn: { on in withAnimation(.easeInOut(duration: 0.18)) { layout.set(tool, on: on, in: store) } },
            move: { step in withAnimation(.easeInOut(duration: 0.18)) { layout.move(tool, by: step, in: store) } },
            beginDrag: { drag.begin(tool) },
            destination: destination(for: tool)
        )
    }

    /// Where a tool's own settings are: its feature's screen, or its pane in
    /// Toolbox. Tools that only act (Quit) have none.
    private func destination(for tool: HoverTool) -> HoverToolRow.Destination? {
        switch tool {
        case .notifs: return .init(title: "Customize") { selection.shownFeature = .notify }
        case .monitor: return .init(title: "Customize") { selection.shownFeature = .monitor }
        case .translate, .subtitles: return .init(title: "Set up") { selection.open(.translateSubtitles) }
        case .screenshot: return .init(title: "Set up") { selection.open(.screenshots) }
        case .dropMode: return .init(title: "Drop settings") { selection.open(.drop) }
        case .quit, .settings: return nil
        default: return .init(title: "Open in Toolbox") { selection.focus(tool) }
        }
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
        offIsland = HoverTool.allCases.filter { $0 != .settings && !slots.contains($0) }
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
        if on { store.placeTool(tool, at: store.lockSlotIndex) } else { store.removeTool(tool) }
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

/// A drag of one tool: begun on a row, it moves the tool live while it passes
/// over the rows in the island, and ends on a drop. A tool that is off joins
/// the island where it is dropped; a tool dropped on More tools leaves it.
@MainActor
final class HoverToolDragModel: ObservableObject {
    enum Target: Equatable {
        case tool(HoverTool)
        /// The pinned Settings row: the last place before Settings.
        case end
        /// More tools: out of the island.
        case off
    }

    @Published private(set) var dragging: HoverTool?
    let store: HoverLayoutStore
    /// The row the drag last moved over. A row that slides under the pointer
    /// after a live move is not a new target, so the tool does not flip back.
    private var lastEntered: Target?

    init(store: HoverLayoutStore) {
        self.store = store
    }

    func begin(_ tool: HoverTool) {
        guard tool != .settings else { return }
        dragging = tool
        lastEntered = nil
    }

    /// Over a row of the island: a tool already there takes that row's place
    /// at once, so the person sees where it lands before letting go.
    func enter(_ target: Target) {
        guard let tool = dragging, target != lastEntered, target != .tool(tool) else { return }
        lastEntered = target
        guard store.slots.contains(tool), let index = index(of: target) else { return }
        store.placeTool(tool, at: index)
    }

    @discardableResult
    func drop(on target: Target) -> Bool {
        defer { end() }
        guard let tool = dragging else { return false }
        if target == .off {
            guard store.slots.contains(tool) else { return false }
            store.removeTool(tool)
            return true
        }
        // A tool from the island already moved while it was dragged.
        if store.slots.contains(tool) { return true }
        guard let index = index(of: target) else { return false }
        store.placeTool(tool, at: index)
        return true
    }

    func end() {
        dragging = nil
        lastEntered = nil
    }

    private func index(of target: Target) -> Int? {
        switch target {
        case .tool(let tool): return store.slots.firstIndex(of: tool)
        case .end: return store.lockSlotIndex
        case .off: return nil
        }
    }
}

struct HoverToolDropDelegate: DropDelegate {
    let target: HoverToolDragModel.Target
    let model: HoverToolDragModel

    @MainActor func validateDrop(info: DropInfo) -> Bool {
        model.dragging != nil && info.hasItemsConforming(to: [.text])
    }

    @MainActor func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.16)) { model.enter(target) }
    }

    @MainActor func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    @MainActor func performDrop(info: DropInfo) -> Bool {
        withAnimation(.easeInOut(duration: 0.18)) { model.drop(on: target) }
    }
}

/// One tool: a handle to drag it by, its mark, name and what it does, its
/// shortcut, and the switch that shows it in the island. The chevron opens
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
    let beginDrag: () -> Void
    let destination: Destination?
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var chevronFocused: Bool

    private var info: HoverToolInfo { HoverToolRegistry.info(for: tool) }

    private var description: String {
        tool.isComingSoon ? "\(info.description). \(CalendarAvailability.message)" : info.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                dragArea
                Spacer(minLength: 10)
                if !shortcut.isEmpty {
                    FeatureShortcutKeys(contents: shortcut)
                }
                Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
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
                .padding(.leading, 62)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
        .background(hovering && isOn ? MacSettingsTheme.hover.opacity(0.35) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(info.title)
        .accessibilityValue(isOn ? "In the island" : "Off")
        .accessibilityAction(named: "Move up") { if canMoveUp { move(-1) } }
        .accessibilityAction(named: "Move down") { if canMoveDown { move(1) } }
    }

    /// The part a person holds to drag: handle, mark and words.
    private var dragArea: some View {
        HStack(spacing: 11) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? MacSettingsTheme.text3 : MacSettingsTheme.text3.opacity(0.4))
                .frame(width: 14)
                .accessibilityHidden(true)
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
        .contentShape(Rectangle())
        .onDrag {
            beginDrag()
            return NSItemProvider(object: tool.rawValue as NSString)
        } preview: {
            HStack(spacing: 8) {
                Image(systemName: info.sfSymbol).font(.system(size: 12.5))
                Text(info.title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(MacSettingsTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(MacSettingsTheme.bgCard, in: Capsule())
        }
        .help(isOn ? "Hold and drag to change its place in the island" : "Drag into the island, or switch it on")
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
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(MacSettingsTheme.text3)
                .frame(width: 14)
                .accessibilityHidden(true)
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
            Text("Always on")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}
