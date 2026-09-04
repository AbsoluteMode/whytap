// Sources/Sidekey/Settings/HoverLayoutStore.swift
import Foundation

/// Stores and persists the 5-slot hover layout. `slots` is always exactly
/// 5 elements; the element at `lockSlotIndex` is always `.settings` and
/// cannot be changed via `setSlot`.
///
/// Shared singleton: `HoverLayoutStore.shared`. Both `IslandView` and
/// `ToolboxSettingsView` observe this object so changes propagate
/// immediately to both surfaces.
@MainActor
final class HoverLayoutStore: ObservableObject {

    static let shared = HoverLayoutStore()

    static let defaultsKey = "sidekey.b2b.hover.layout"
    static let slotCount = 5
    static let lockSlotIndex = 4  // last slot is always .settings

    static let defaultSlots: [HoverTool] = [
        .inputLang, .notes, .meetingRecord, .hotkeys, .settings
    ]

    @Published private(set) var slots: [HoverTool]

    private let defaults: UserDefaults

    /// Production uses `UserDefaults.standard`. Tests pass an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.slots = Self.loadSlots(from: defaults)
    }

    // MARK: - Mutation

    /// Replace the tool at `index` with `tool`.
    /// Silently ignores: the locked index, duplicate tools, out-of-bounds.
    func setSlot(_ index: Int, to tool: HoverTool) {
        guard index >= 0, index < Self.slotCount else { return }
        guard index != Self.lockSlotIndex else { return }
        guard !slots.contains(tool) else { return }
        var updated = slots
        updated[index] = tool
        slots = updated
        persist()
    }

    /// Replace the editable portion of the panel (every slot except the
    /// locked Settings tile) with `tools`, preserving their order.
    ///
    /// Drops `.settings` (it is always pinned), de-duplicates, truncates to
    /// the editable capacity, and pads any remaining editable slots from the
    /// defaults so the panel never ends up with fewer than `slotCount` tiles.
    /// Used by the onboarding super-assistant picker to apply the user's
    /// chosen helpers in one shot.
    func replaceEditableSlots(with tools: [HoverTool]) {
        let capacity = Self.slotCount - 1
        var editable: [HoverTool] = []
        var seen = Set<HoverTool>()
        for tool in tools where tool != .settings {
            guard seen.insert(tool).inserted else { continue }
            editable.append(tool)
            if editable.count == capacity { break }
        }
        if editable.count < capacity {
            let fillers = Self.defaultSlots.filter { $0 != .settings && !editable.contains($0) }
            editable.append(contentsOf: fillers.prefix(capacity - editable.count))
        }
        editable.append(.settings)
        slots = editable
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(slots.map(\.rawValue), forKey: Self.defaultsKey)
    }

    // MARK: - Loading & normalization

    private static func loadSlots(from defaults: UserDefaults) -> [HoverTool] {
        guard let raw = defaults.stringArray(forKey: defaultsKey), !raw.isEmpty else {
            return defaultSlots
        }

        // Parse rawValues → known tools, drop unknowns
        var tools = raw.compactMap { HoverTool(rawValue: $0) }

        // Drop duplicates (first occurrence wins)
        var seen = Set<HoverTool>()
        tools = tools.filter { seen.insert($0).inserted }

        // Ensure lock slot is .settings (remove it from wherever it is, pin at end)
        tools.removeAll { $0 == .settings }

        // Pad to (slotCount - 1) with defaults if too short
        let needed = slotCount - 1
        if tools.count < needed {
            let candidates = defaultSlots.filter { $0 != .settings && !tools.contains($0) }
            tools.append(contentsOf: candidates.prefix(needed - tools.count))
        }

        // Truncate to (slotCount - 1) if too long
        tools = Array(tools.prefix(needed))

        // Lock slot
        tools.append(.settings)
        return tools
    }
}
