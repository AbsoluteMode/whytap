// Sources/Sidekey/Settings/HoverLayoutStore.swift
import Foundation

/// Stores the user's ordered tools, with Settings always pinned at the end.
/// The empty add target belongs to the editor, never to the persisted layout.
///
/// Shared singleton: `HoverLayoutStore.shared`. Both `IslandView` and
/// `ToolboxSettingsView` observe this object so changes propagate
/// immediately to both surfaces.
@MainActor
final class HoverLayoutStore: ObservableObject {

    static let shared = HoverLayoutStore()

    static let defaultsKey = "sidekey.b2b.hover.layout"
    nonisolated static let columns = 3

    static let defaultSlots: [HoverTool] = [
        .inputLang, .notes, .meetingRecord, .hotkeys, .monitor, .settings
    ]

    @Published private(set) var slots: [HoverTool]

    var lockSlotIndex: Int { slots.count - 1 }

    private let defaults: UserDefaults

    /// Production uses `UserDefaults.standard`. Tests pass an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.slots = Self.loadSlots(from: defaults)
    }

    /// Settings sync wrote another Mac's layout: show it.
    func reloadFromDefaults() {
        let loaded = Self.loadSlots(from: defaults)
        if loaded != slots { slots = loaded }
    }

    // MARK: - Mutation

    /// Replace the tool at `index` with `tool`.
    /// Silently ignores: the locked index, duplicate tools, out-of-bounds.
    func setSlot(_ index: Int, to tool: HoverTool) {
        guard slots.indices.contains(index) else { return }
        guard index != lockSlotIndex, tool != .settings else { return }
        guard !slots.contains(tool) else { return }
        var updated = slots
        updated[index] = tool
        slots = updated
        persist()
    }

    /// Insert a new tool, or move an existing tool to the target position.
    /// Dragging onto the empty editor target uses `lockSlotIndex` to append.
    @discardableResult
    func placeTool(_ tool: HoverTool, at index: Int) -> Bool {
        guard tool != .settings, index >= 0, index <= lockSlotIndex else { return false }
        var updated = slots
        if let previous = updated.firstIndex(of: tool) {
            updated.remove(at: previous)
        }
        updated.insert(tool, at: min(index, updated.count - 1))
        guard updated != slots else { return false }
        slots = updated
        persist()
        return true
    }

    func removeTool(_ tool: HoverTool) {
        guard tool != .settings, slots.contains(tool) else { return }
        slots.removeAll { $0 == tool }
        persist()
    }

    /// Applies exactly the selected helpers, without
    /// padding with tools the user did not choose or truncating their choice.
    func replaceEditableSlots(with tools: [HoverTool]) {
        slots = Self.normalized(tools)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(slots.map(\.rawValue), forKey: Self.defaultsKey)
    }

    // MARK: - Loading & normalization

    private static func loadSlots(from defaults: UserDefaults) -> [HoverTool] {
        guard let raw = defaults.stringArray(forKey: defaultsKey) else {
            return defaultSlots
        }
        return normalized(raw.compactMap { HoverTool(rawValue: $0) })
    }

    private static func normalized(_ tools: [HoverTool]) -> [HoverTool] {
        var seen = Set<HoverTool>()
        return tools.filter { $0 != .settings && seen.insert($0).inserted } + [.settings]
    }
}
