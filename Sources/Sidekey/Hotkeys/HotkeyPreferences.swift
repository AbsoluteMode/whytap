import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation

enum HotkeyModifierKey: String, CaseIterable, Codable, Hashable, Identifiable {
    case rightCommand
    case rightOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightCommand:
            return "Right Command"
        case .rightOption:
            return "Right Option"
        }
    }

    var shortToken: String {
        switch self {
        case .rightCommand:
            return "r cmd"
        case .rightOption:
            return "r opt"
        }
    }

    var shortcutChipTitle: String {
        switch self {
        case .rightCommand:
            return "R⌘"
        case .rightOption:
            return "R⌥"
        }
    }

    var keycapContent: KeycapContent {
        switch self {
        case .rightCommand:
            return .prefixedGlyph(
                prefix: "right",
                glyph: HotkeyGlyph.command,
                accessibilityLabel: "Right Command key"
            )
        case .rightOption:
            return .prefixedGlyph(
                prefix: "right",
                glyph: HotkeyGlyph.option,
                accessibilityLabel: "Right Option key"
            )
        }
    }
}

enum HotkeyShortcut: Hashable, Codable, RawRepresentable {
    case modifier(HotkeyModifierKey)
    case combo(HotkeyTapCombo)
    /// Hold the space bar to trigger Drop. Carries no key code — the
    /// gesture is a press-and-hold on Space, detected by a CGEventTap
    /// monitor (not a Carbon registration). Rendered as a single "Space"
    /// keycap across hint surfaces.
    case holdSpace

    /// Sentinel raw string for `.holdSpace`. Must not collide with any
    /// `HotkeyModifierKey.rawValue` or `HotkeyTapCombo` raw value (legacy
    /// preset names or JSON-encoded combos) so RawRepresentable / Codable
    /// round-trips stay unambiguous.
    private static let holdSpaceRawValue = "holdSpace"

    static func == (lhs: HotkeyShortcut, rhs: HotkeyShortcut) -> Bool {
        switch (lhs, rhs) {
        case (.modifier(let lhsKey), .modifier(let rhsKey)):
            return lhsKey == rhsKey
        case (.combo(let lhsCombo), .combo(let rhsCombo)):
            return lhsCombo == rhsCombo
        case (.holdSpace, .holdSpace):
            return true
        default:
            return false
        }
    }

    init?(rawValue: String) {
        if rawValue == Self.holdSpaceRawValue {
            self = .holdSpace
            return
        }
        if let key = HotkeyModifierKey(rawValue: rawValue) {
            self = .modifier(key)
            return
        }
        if let combo = HotkeyTapCombo(rawValue: rawValue) {
            self = .combo(combo)
            return
        }
        return nil
    }

    var rawValue: String {
        switch self {
        case .modifier(let key):
            return key.rawValue
        case .combo(let combo):
            return combo.rawValue
        case .holdSpace:
            return Self.holdSpaceRawValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid hotkey shortcut: \(rawValue)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .modifier(let key):
            return key.title
        case .combo(let combo):
            return combo.title
        case .holdSpace:
            return "Space"
        }
    }

    var contents: [KeycapContent] {
        switch self {
        case .modifier(let key):
            return [key.keycapContent]
        case .combo(let combo):
            return combo.contents
        case .holdSpace:
            return [.text("Space")]
        }
    }

    var shortcutChipTitles: [String] {
        switch self {
        case .modifier(let key):
            return [key.shortcutChipTitle]
        case .combo(let combo):
            return combo.shortcutChipTitles
        case .holdSpace:
            return ["Space"]
        }
    }

    var compactToken: String {
        switch self {
        case .modifier(let key):
            return key.shortToken
        case .combo(let combo):
            return combo.compactToken
        case .holdSpace:
            return "Space"
        }
    }

    var modifierKey: HotkeyModifierKey? {
        if case .modifier(let key) = self {
            return key
        }
        return nil
    }

    var combo: HotkeyTapCombo? {
        if case .combo(let combo) = self {
            return combo
        }
        return nil
    }

    var bindingKey: HotkeyBinding.Key {
        switch self {
        case .modifier(let key):
            return .modifier(key)
        case .combo(let combo):
            return .combo(combo)
        case .holdSpace:
            return .holdSpace
        }
    }
}

struct HotkeyTapCombo: Codable, Hashable, Identifiable, RawRepresentable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyTitle: String

    var id: String { "\(modifiers)-\(keyCode)" }

    init(keyCode: UInt32, modifiers: UInt32, keyTitle: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyTitle = keyTitle
    }

    static func == (lhs: HotkeyTapCombo, rhs: HotkeyTapCombo) -> Bool {
        lhs.keyCode == rhs.keyCode &&
            lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        keyTitle = try container.decode(String.self, forKey: .keyTitle)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(keyTitle, forKey: .keyTitle)
    }

    init?(rawValue: String) {
        if let preset = Self.legacyPreset(rawValue: rawValue) {
            self = preset
            return
        }
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = decoded
    }

    var rawValue: String {
        if let legacy = Self.legacyRawValue(for: self) {
            return legacy
        }
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else {
            return "optionSlash"
        }
        return value
    }

    var title: String {
        shortcutChipTitles.joined(separator: " ")
    }

    var contents: [KeycapContent] {
        modifierContents + [keyContent]
    }

    var shortcutChipTitles: [String] {
        modifierTitles + [keyTitle]
    }

    var compactToken: String {
        (modifierTokens + [keyToken]).joined(separator: " ")
    }

    var hasRequiredModifier: Bool {
        modifiers != 0
    }

    /// The combo's Carbon modifier mask (`modifiers`) expressed as `CGEventFlags`.
    ///
    /// A hold-combo Drop is registered through the generalized `SpaceHoldMonitor`
    /// CGEventTap, whose modifier gate compares the live keyDown's `CGEventFlags`
    /// against `requiredModifiers`. `modifiers` is a Carbon mask (`cmdKey` /
    /// `optionKey` / `shiftKey` / `controlKey`), so this bridges each functional
    /// bit to its CoreGraphics peer. The inverse of `carbonModifiers(from:)`; a
    /// modifier-less combo maps to an empty set.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(controlKey) != 0 {
            flags.insert(.maskControl)
        }
        if modifiers & UInt32(optionKey) != 0 {
            flags.insert(.maskAlternate)
        }
        if modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.maskShift)
        }
        if modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.maskCommand)
        }
        return flags
    }

    static let optionSlash = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.slashKeyCode,
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "/"
    )
    static let optionPeriod = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_Period),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "."
    )
    static let optionSpace = HotkeyTapCombo(
        keyCode: UInt32(kVK_Space),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "Space"
    )
    static let optionD = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "D"
    )
    static let optionQ = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.qKeyCode,
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "Q"
    )
    /// ⌥M — default Meeting-record toggle ("M" as in meeting). Tap starts a
    /// manual recording, tap again stops it.
    static let optionM = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "M"
    )
    /// ⌥1..⌥5 — the default positional Hover-slot shortcuts (ROO-210). ⌥N
    /// activates whatever tool currently sits in `HoverLayoutStore.slots[N-1]`.
    /// `kVK_ANSI_1..5` are non-contiguous in Carbon (5 = 23, not 22), so the
    /// key codes come from the named constants, not arithmetic on the first.
    static let optionOne = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_1),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "1"
    )
    static let optionTwo = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "2"
    )
    static let optionThree = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_3),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "3"
    )
    static let optionFour = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_4),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "4"
    )
    static let optionFive = HotkeyTapCombo(
        keyCode: UInt32(kVK_ANSI_5),
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "5"
    )
    static let optionLeftArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.leftArrowKeyCode,
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "←"
    )
    static let optionRightArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.rightArrowKeyCode,
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "→"
    )
    static let optionUpArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.upArrowKeyCode,
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "↑"
    )
    static let optionDownArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.downArrowKeyCode,
        modifiers: CarbonHotkeyMonitor.optionModifier,
        keyTitle: "↓"
    )

    /// Bare arrows (no modifier) — the default Useful Links bindings (Insert ←,
    /// Open →, Next ↓, Previous ↑). `RegisterEventHotKey` accepts a zero
    /// modifier mask; the family is only registered while the answer panel
    /// shows a useful-links block, so the global grab of the arrow keys is
    /// scoped to that transient window. The Settings recorder also accepts
    /// bare keys now (B1), so these defaults are no longer special — any
    /// single titled key records as a modifierless combo.
    static let leftArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.leftArrowKeyCode,
        modifiers: 0,
        keyTitle: "←"
    )
    static let rightArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.rightArrowKeyCode,
        modifiers: 0,
        keyTitle: "→"
    )
    static let upArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.upArrowKeyCode,
        modifiers: 0,
        keyTitle: "↑"
    )
    static let downArrow = HotkeyTapCombo(
        keyCode: CarbonHotkeyMonitor.downArrowKeyCode,
        modifiers: 0,
        keyTitle: "↓"
    )

    static func recorded(from event: NSEvent) -> HotkeyTapCombo? {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else { return nil }
        let keyCode = UInt32(event.keyCode)
        guard let keyTitle = keyTitle(for: keyCode, event: event) else { return nil }
        return HotkeyTapCombo(keyCode: keyCode, modifiers: modifiers, keyTitle: keyTitle)
    }

    private var modifierContents: [KeycapContent] {
        modifierSpecs.map(\.content)
    }

    private var modifierTitles: [String] {
        modifierSpecs.map(\.title)
    }

    private var modifierTokens: [String] {
        modifierSpecs.map(\.token)
    }

    private var keyContent: KeycapContent {
        switch keyCode {
        case CarbonHotkeyMonitor.leftArrowKeyCode:
            return HotkeyGlyph.chevronLeft
        case CarbonHotkeyMonitor.rightArrowKeyCode:
            return HotkeyGlyph.chevronRight
        case CarbonHotkeyMonitor.upArrowKeyCode:
            return HotkeyGlyph.chevronUp
        case CarbonHotkeyMonitor.downArrowKeyCode:
            return HotkeyGlyph.chevronDown
        default:
            return .text(keyTitle)
        }
    }

    private var keyToken: String {
        switch keyCode {
        case CarbonHotkeyMonitor.leftArrowKeyCode:
            return "left"
        case CarbonHotkeyMonitor.rightArrowKeyCode:
            return "right"
        case CarbonHotkeyMonitor.upArrowKeyCode:
            return "up"
        case CarbonHotkeyMonitor.downArrowKeyCode:
            return "down"
        default:
            return keyTitle.lowercased()
        }
    }

    private var modifierSpecs: [ModifierSpec] {
        Self.modifierSpecOrder.filter { modifiers & $0.mask != 0 }
    }

    private static let modifierSpecOrder: [ModifierSpec] = [
        ModifierSpec(mask: UInt32(controlKey), title: HotkeyGlyph.control, token: "ctrl", content: .text(HotkeyGlyph.control)),
        ModifierSpec(mask: UInt32(optionKey), title: HotkeyGlyph.option, token: "opt", content: .text(HotkeyGlyph.option)),
        ModifierSpec(mask: UInt32(shiftKey), title: HotkeyGlyph.shift, token: "shift", content: .text(HotkeyGlyph.shift)),
        ModifierSpec(mask: UInt32(cmdKey), title: HotkeyGlyph.command, token: "cmd", content: .text(HotkeyGlyph.command))
    ]

    private static func legacyPreset(rawValue: String) -> HotkeyTapCombo? {
        switch rawValue {
        case "optionSlash":
            return .optionSlash
        case "optionPeriod":
            return .optionPeriod
        case "optionSpace":
            return .optionSpace
        case "optionD":
            return .optionD
        case "optionQ":
            return .optionQ
        case "optionOne":
            return .optionOne
        case "optionTwo":
            return .optionTwo
        case "optionThree":
            return .optionThree
        case "optionFour":
            return .optionFour
        case "optionFive":
            return .optionFive
        case "optionLeftArrow":
            return .optionLeftArrow
        case "optionRightArrow":
            return .optionRightArrow
        case "optionUpArrow":
            return .optionUpArrow
        case "optionDownArrow":
            return .optionDownArrow
        case "leftArrow":
            return .leftArrow
        case "rightArrow":
            return .rightArrow
        case "upArrow":
            return .upArrow
        case "downArrow":
            return .downArrow
        default:
            return nil
        }
    }

    private static func legacyRawValue(for combo: HotkeyTapCombo) -> String? {
        switch combo {
        case .optionSlash:
            return "optionSlash"
        case .optionPeriod:
            return "optionPeriod"
        case .optionSpace:
            return "optionSpace"
        case .optionD:
            return "optionD"
        case .optionQ:
            return "optionQ"
        case .optionOne:
            return "optionOne"
        case .optionTwo:
            return "optionTwo"
        case .optionThree:
            return "optionThree"
        case .optionFour:
            return "optionFour"
        case .optionFive:
            return "optionFive"
        case .optionLeftArrow:
            return "optionLeftArrow"
        case .optionRightArrow:
            return "optionRightArrow"
        case .optionUpArrow:
            return "optionUpArrow"
        case .optionDownArrow:
            return "optionDownArrow"
        case .leftArrow:
            return "leftArrow"
        case .rightArrow:
            return "rightArrow"
        case .upArrow:
            return "upArrow"
        case .downArrow:
            return "downArrow"
        default:
            return nil
        }
    }

    fileprivate static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) {
            result |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            result |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        if flags.contains(.command) {
            result |= UInt32(cmdKey)
        }
        return result
    }

    fileprivate static func keyTitle(for keyCode: UInt32, event: NSEvent) -> String? {
        switch keyCode {
        case CarbonHotkeyMonitor.leftArrowKeyCode:
            return "←"
        case CarbonHotkeyMonitor.rightArrowKeyCode:
            return "→"
        case CarbonHotkeyMonitor.upArrowKeyCode:
            return "↑"
        case CarbonHotkeyMonitor.downArrowKeyCode:
            return "↓"
        case UInt32(kVK_Space):
            return "Space"
        case UInt32(kVK_Tab):
            return "Tab"
        case UInt32(kVK_Delete):
            // macOS labels this key "Delete" (erase-left / Backspace). Titled
            // here so the bare-key recorder can produce a legible modifierless
            // combo instead of falling through to the `nil` guard.
            return "Delete"
        case UInt32(kVK_ForwardDelete):
            return "Forward Delete"
        // Home/End/PageUp/PageDown events carry Unicode PUA scalars in
        // `charactersIgnoringModifiers` (NSHomeFunctionKey & co) that survive
        // the whitespace trim below and would render as tofu keycaps — same
        // problem as the F-keys, same explicit-title fix.
        case UInt32(kVK_Home):
            return "Home"
        case UInt32(kVK_End):
            return "End"
        case UInt32(kVK_PageUp):
            return "Page Up"
        case UInt32(kVK_PageDown):
            return "Page Down"
        case CarbonHotkeyMonitor.slashKeyCode:
            return "/"
        case UInt32(kVK_ANSI_Period):
            return "."
        default:
            if let functionKeyTitle = functionKeyTitles[keyCode] {
                return functionKeyTitle
            }
            guard let character = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !character.isEmpty else {
                return nil
            }
            return character.uppercased()
        }
    }

    /// F1–F20 titles. Function-key events carry Unicode PUA scalars in
    /// `charactersIgnoringModifiers` (`NSF5FunctionKey` & co), which survive
    /// the whitespace trim above and would render as tofu keycaps. The Carbon
    /// key codes are non-contiguous, hence an explicit table.
    private static let functionKeyTitles: [UInt32: String] = [
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20"
    ]

    private struct ModifierSpec {
        let mask: UInt32
        let title: String
        let token: String
        let content: KeycapContent
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case keyTitle
    }
}

struct HotkeyComboRecorder {
    private var modifier: RecorderModifier?
    private var key: RecorderKey?

    init(combo: HotkeyTapCombo? = nil) {
        if let combo {
            self.modifier = RecorderModifier.first(in: combo.modifiers)
            self.key = RecorderKey(
                keyCode: combo.keyCode,
                keyTitle: combo.keyTitle,
                content: combo.contents.last ?? .text(combo.keyTitle)
            )
        } else {
            self.modifier = nil
            self.key = nil
        }
    }

    var contents: [KeycapContent] {
        [modifier?.content, key?.content].compactMap { $0 }
    }

    mutating func reset() {
        modifier = nil
        key = nil
    }

    mutating func record(_ event: NSEvent) -> HotkeyTapCombo? {
        switch event.type {
        case .flagsChanged:
            if let nextModifier = RecorderModifier.first(in: event.modifierFlags) {
                modifier = nextModifier
                return comboIfComplete()
            }
            return nil
        case .keyDown:
            let keyCode = UInt32(event.keyCode)
            guard let keyTitle = HotkeyTapCombo.keyTitle(for: keyCode, event: event) else {
                return nil
            }
            key = RecorderKey(
                keyCode: keyCode,
                keyTitle: keyTitle,
                content: HotkeyTapCombo(keyCode: keyCode, modifiers: 0, keyTitle: keyTitle).contents.last ?? .text(keyTitle)
            )
            if modifier == nil {
                modifier = RecorderModifier.first(in: event.modifierFlags)
            }
            return comboIfComplete()
        default:
            return nil
        }
    }

    private func comboIfComplete() -> HotkeyTapCombo? {
        guard let modifier, let key else {
            return nil
        }
        return HotkeyTapCombo(
            keyCode: key.keyCode,
            modifiers: modifier.mask,
            keyTitle: key.keyTitle
        )
    }

    private struct RecorderKey {
        let keyCode: UInt32
        let keyTitle: String
        let content: KeycapContent
    }

    private struct RecorderModifier {
        let mask: UInt32
        let content: KeycapContent

        static func first(in modifiers: UInt32) -> RecorderModifier? {
            Self.specs
                .first { modifiers & $0.mask != 0 }
                .map { RecorderModifier(mask: $0.mask, content: $0.content) }
        }

        static func first(in flags: NSEvent.ModifierFlags) -> RecorderModifier? {
            Self.specs
                .first { flags.contains($0.flag) }
                .map { RecorderModifier(mask: $0.mask, content: $0.content) }
        }

        private static let specs: [(mask: UInt32, flag: NSEvent.ModifierFlags, content: KeycapContent)] = [
            (UInt32(controlKey), .control, .text(HotkeyGlyph.control)),
            (UInt32(optionKey), .option, .text(HotkeyGlyph.option)),
            (UInt32(shiftKey), .shift, .text(HotkeyGlyph.shift)),
            (UInt32(cmdKey), .command, .text(HotkeyGlyph.command))
        ]
    }
}

struct HotkeyShortcutRecorder {
    // High-water snapshot of the combination built since the field was last
    // empty. Survives key release — release is the COMMIT signal, never a
    // clear (the B1/B8 regression was clearing the modifier on release).
    private var capturedModifierMask: UInt32 = 0
    private var capturedKey: RecorderKey?
    /// A lone RIGHT modifier (R⌘/R⌥/R⇧) captured as a modifier-only binding.
    /// Only right modifiers are detectable/safe standalone (left ⌘ fires on
    /// every ⌘C); set from `modifierOnlyKey(from:)`, cleared when a key or a
    /// non-right modifier joins.
    private var capturedRightModifier: HotkeyModifierKey?
    // Currently physically held.
    private var heldModifierMask: UInt32 = 0
    private var heldKeyCodes: Set<UInt32> = []
    /// True while a fresh combination is being held. A press while not building
    /// resets the captured snapshot (start over / re-record); commit fires only
    /// when `building` and everything has been released.
    private var building = false

    init(shortcut: HotkeyShortcut? = nil) {
        switch shortcut {
        case .combo(let combo):
            capturedModifierMask = combo.modifiers
            capturedKey = RecorderKey(
                keyCode: combo.keyCode,
                keyTitle: combo.keyTitle,
                content: combo.contents.last ?? .text(combo.keyTitle)
            )
        case .modifier(let key):
            capturedRightModifier = key
        case .holdSpace:
            capturedKey = RecorderKey(
                keyCode: UInt32(kVK_Space),
                keyTitle: "Space",
                content: HotkeyTapCombo(keyCode: UInt32(kVK_Space), modifiers: 0, keyTitle: "Space").contents.last ?? .text("Space")
            )
        case nil:
            break
        }
    }

    var contents: [KeycapContent] {
        // `capturedRightModifier` is only ever set for a LONE right modifier
        // (cleared the moment a key or any other modifier joins), so whenever
        // it is set with no key it is the whole binding — prefer its prefixed
        // "Right Option/Command" keycap. Not gated on `capturedModifierMask`:
        // a live R⌥ press also sets the general option bit in the mask, so a
        // mask==0 guard would only ever fire for the seeded path and show a
        // plain ⌥ glyph for live input (display/value mismatch).
        if capturedKey == nil, let rm = capturedRightModifier {
            return [rm.keycapContent]
        }
        var result = Self.modifierContents(for: capturedModifierMask)
        if let capturedKey {
            result.append(capturedKey.content)
        }
        return result
    }

    mutating func reset() {
        capturedModifierMask = 0
        capturedKey = nil
        capturedRightModifier = nil
        heldModifierMask = 0
        heldKeyCodes = []
        building = false
    }

    /// Feed a recording event. Returns the committed `HotkeyShortcut` once the
    /// whole combination is released; nil while building or on a non-committing
    /// event. Escape is intercepted by the caller (cancel) before `record`.
    mutating func record(_ event: NSEvent) -> HotkeyShortcut? {
        switch event.type {
        case .keyDown:
            let keyCode = UInt32(event.keyCode)
            guard let keyTitle = HotkeyTapCombo.keyTitle(for: keyCode, event: event) else {
                return nil
            }
            if !building {
                resetCaptured()
                building = true
            }
            heldKeyCodes.insert(keyCode)
            capturedKey = RecorderKey(
                keyCode: keyCode,
                keyTitle: keyTitle,
                content: HotkeyTapCombo(keyCode: keyCode, modifiers: 0, keyTitle: keyTitle).contents.last ?? .text(keyTitle)
            )
            capturedRightModifier = nil
            capturedModifierMask |= HotkeyTapCombo.carbonModifiers(from: event.modifierFlags)
            return nil

        case .keyUp:
            heldKeyCodes.remove(UInt32(event.keyCode))
            return commitIfReleased()

        case .flagsChanged:
            let newMask = HotkeyTapCombo.carbonModifiers(from: event.modifierFlags)
            let added = newMask & ~heldModifierMask
            if added != 0, !building {
                resetCaptured()
                building = true
            }
            heldModifierMask = newMask
            capturedModifierMask |= newMask
            if capturedKey == nil {
                if let rm = modifierOnlyKey(from: event) {
                    capturedRightModifier = rm        // lone right modifier
                } else if newMask != 0 {
                    capturedRightModifier = nil        // multi/left → not modifier-only
                }
                // newMask == 0 (release): keep capturedRightModifier high-water.
            }
            return commitIfReleased()

        default:
            return nil
        }
    }

    private mutating func resetCaptured() {
        capturedModifierMask = 0
        capturedKey = nil
        capturedRightModifier = nil
    }

    private mutating func commitIfReleased() -> HotkeyShortcut? {
        guard building, heldModifierMask == 0, heldKeyCodes.isEmpty else {
            return nil
        }
        building = false
        if let capturedKey {
            if capturedKey.keyCode == UInt32(kVK_Space), capturedModifierMask == 0 {
                return .holdSpace
            }
            return .combo(HotkeyTapCombo(
                keyCode: capturedKey.keyCode,
                modifiers: capturedModifierMask,
                keyTitle: capturedKey.keyTitle
            ))
        }
        if let capturedRightModifier {
            return .modifier(capturedRightModifier)
        }
        return nil   // invalid (left/multi modifier with no key)
    }

    private static func modifierContents(for mask: UInt32) -> [KeycapContent] {
        var result: [KeycapContent] = []
        if mask & UInt32(controlKey) != 0 { result.append(.text(HotkeyGlyph.control)) }
        if mask & UInt32(optionKey) != 0 { result.append(.text(HotkeyGlyph.option)) }
        if mask & UInt32(shiftKey) != 0 { result.append(.text(HotkeyGlyph.shift)) }
        if mask & UInt32(cmdKey) != 0 { result.append(.text(HotkeyGlyph.command)) }
        return result
    }

    private func modifierOnlyKey(from event: NSEvent) -> HotkeyModifierKey? {
        let rawFlags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        if HotkeyFlags.isOnly(.rightCommand, rawFlags) {
            return .rightCommand
        }
        if HotkeyFlags.isOnly(.rightOption, rawFlags) {
            return .rightOption
        }
        return nil
    }

    private struct RecorderKey {
        let keyCode: UInt32
        let keyTitle: String
        let content: KeycapContent
    }
}

struct HotkeyConfiguration: Equatable {
    var agentTextShortcut: HotkeyShortcut
    var agentVoiceShortcut: HotkeyShortcut
    var agentVoiceGesture: HotkeyGesture
    var dropVoiceGesture: HotkeyGesture
    var dropVoiceShortcut: HotkeyShortcut
    var agentCloseShortcut: HotkeyShortcut
    var usefulLinksInsertShortcut: HotkeyShortcut
    var usefulLinksOpenShortcut: HotkeyShortcut
    var usefulLinksNextShortcut: HotkeyShortcut
    var usefulLinksPreviousShortcut: HotkeyShortcut
    /// Positional Hover-slot shortcuts (ROO-210). `hoverSlotNShortcut` activates
    /// whatever tool currently occupies `HoverLayoutStore.slots[N-1]` — the
    /// binding follows the POSITION, not the tool, so a Toolbox reorder
    /// re-points ⌥N at the new occupant (D1). Default ⌥1..⌥5.
    var hoverSlot1Shortcut: HotkeyShortcut
    var hoverSlot2Shortcut: HotkeyShortcut
    var hoverSlot3Shortcut: HotkeyShortcut
    var hoverSlot4Shortcut: HotkeyShortcut
    var hoverSlot5Shortcut: HotkeyShortcut
    /// Google-search gesture, default Right Option (R-Option), symmetric to the
    /// agent's Right Command: tap = type a query, hold = speak a query. Both
    /// open the result in the default browser.
    var googleSearchTextShortcut: HotkeyShortcut
    var googleSearchVoiceShortcut: HotkeyShortcut
    var googleSearchVoiceGesture: HotkeyGesture
    /// Meeting-record toggle: tap starts a manual Meeting Notes recording
    /// (bypassing the detector nudge), tap again stops it. Default ⌥M.
    var meetingRecordShortcut: HotkeyShortcut

    init(
        agentTextShortcut: HotkeyShortcut,
        agentVoiceShortcut: HotkeyShortcut,
        agentVoiceGesture: HotkeyGesture = .hold,
        dropVoiceGesture: HotkeyGesture = .tap,
        dropVoiceShortcut: HotkeyShortcut,
        agentCloseShortcut: HotkeyShortcut = .combo(.optionQ),
        usefulLinksInsertShortcut: HotkeyShortcut = .combo(.leftArrow),
        usefulLinksOpenShortcut: HotkeyShortcut = .combo(.rightArrow),
        usefulLinksNextShortcut: HotkeyShortcut = .combo(.downArrow),
        usefulLinksPreviousShortcut: HotkeyShortcut = .combo(.upArrow),
        hoverSlot1Shortcut: HotkeyShortcut = .combo(.optionOne),
        hoverSlot2Shortcut: HotkeyShortcut = .combo(.optionTwo),
        hoverSlot3Shortcut: HotkeyShortcut = .combo(.optionThree),
        hoverSlot4Shortcut: HotkeyShortcut = .combo(.optionFour),
        hoverSlot5Shortcut: HotkeyShortcut = .combo(.optionFive),
        googleSearchTextShortcut: HotkeyShortcut = .modifier(.rightOption),
        googleSearchVoiceShortcut: HotkeyShortcut = .modifier(.rightOption),
        googleSearchVoiceGesture: HotkeyGesture = .hold,
        meetingRecordShortcut: HotkeyShortcut = .combo(.optionM)
    ) {
        self.agentTextShortcut = agentTextShortcut
        self.agentVoiceShortcut = agentVoiceShortcut
        self.agentVoiceGesture = agentVoiceGesture
        self.dropVoiceGesture = dropVoiceGesture
        self.dropVoiceShortcut = dropVoiceShortcut
        self.agentCloseShortcut = agentCloseShortcut
        self.usefulLinksInsertShortcut = usefulLinksInsertShortcut
        self.usefulLinksOpenShortcut = usefulLinksOpenShortcut
        self.usefulLinksNextShortcut = usefulLinksNextShortcut
        self.usefulLinksPreviousShortcut = usefulLinksPreviousShortcut
        self.hoverSlot1Shortcut = hoverSlot1Shortcut
        self.hoverSlot2Shortcut = hoverSlot2Shortcut
        self.hoverSlot3Shortcut = hoverSlot3Shortcut
        self.hoverSlot4Shortcut = hoverSlot4Shortcut
        self.hoverSlot5Shortcut = hoverSlot5Shortcut
        self.googleSearchTextShortcut = googleSearchTextShortcut
        self.googleSearchVoiceShortcut = googleSearchVoiceShortcut
        self.googleSearchVoiceGesture = googleSearchVoiceGesture
        self.meetingRecordShortcut = meetingRecordShortcut
    }

    init(
        agentTextKey: HotkeyModifierKey,
        agentVoiceKey: HotkeyModifierKey,
        agentVoiceGesture: HotkeyGesture = .hold,
        dropVoiceGesture: HotkeyGesture = .tap,
        dropVoiceTapCombo: HotkeyTapCombo,
        agentCloseCombo: HotkeyTapCombo = .optionQ,
        usefulLinksInsertCombo: HotkeyTapCombo = .leftArrow,
        usefulLinksOpenCombo: HotkeyTapCombo = .rightArrow,
        usefulLinksNextCombo: HotkeyTapCombo = .downArrow,
        usefulLinksPreviousCombo: HotkeyTapCombo = .upArrow
    ) {
        self.init(
            agentTextShortcut: .modifier(agentTextKey),
            agentVoiceShortcut: .modifier(agentVoiceKey),
            agentVoiceGesture: agentVoiceGesture,
            dropVoiceGesture: dropVoiceGesture,
            dropVoiceShortcut: .combo(dropVoiceTapCombo),
            agentCloseShortcut: .combo(agentCloseCombo),
            usefulLinksInsertShortcut: .combo(usefulLinksInsertCombo),
            usefulLinksOpenShortcut: .combo(usefulLinksOpenCombo),
            usefulLinksNextShortcut: .combo(usefulLinksNextCombo),
            usefulLinksPreviousShortcut: .combo(usefulLinksPreviousCombo)
        )
    }

    init(
        agentGestureKey: HotkeyModifierKey,
        dropVoiceTapCombo: HotkeyTapCombo,
        agentCloseCombo: HotkeyTapCombo = .optionQ,
        usefulLinksInsertCombo: HotkeyTapCombo = .leftArrow,
        usefulLinksOpenCombo: HotkeyTapCombo = .rightArrow,
        usefulLinksNextCombo: HotkeyTapCombo = .downArrow,
        usefulLinksPreviousCombo: HotkeyTapCombo = .upArrow
    ) {
        self.init(
            agentTextShortcut: .modifier(agentGestureKey),
            agentVoiceShortcut: .modifier(agentGestureKey),
            agentVoiceGesture: .hold,
            dropVoiceGesture: .tap,
            dropVoiceShortcut: .combo(dropVoiceTapCombo),
            agentCloseShortcut: .combo(agentCloseCombo),
            usefulLinksInsertShortcut: .combo(usefulLinksInsertCombo),
            usefulLinksOpenShortcut: .combo(usefulLinksOpenCombo),
            usefulLinksNextShortcut: .combo(usefulLinksNextCombo),
            usefulLinksPreviousShortcut: .combo(usefulLinksPreviousCombo)
        )
    }

    var agentGestureKey: HotkeyModifierKey {
        get { agentTextKey }
        set {
            agentTextKey = newValue
            agentVoiceKey = newValue
        }
    }

    var agentTextKey: HotkeyModifierKey {
        get { agentTextShortcut.modifierKey ?? HotkeyConfiguration.defaults.agentTextKey }
        set { agentTextShortcut = .modifier(newValue) }
    }

    var agentVoiceKey: HotkeyModifierKey {
        get { agentVoiceShortcut.modifierKey ?? HotkeyConfiguration.defaults.agentVoiceKey }
        set { agentVoiceShortcut = .modifier(newValue) }
    }

    /// Non-optional Drop combo accessor. Post-cutover the default Drop
    /// shortcut is `.holdSpace`, which has no combo, so the fallback is the
    /// literal `.optionSlash` — **not** `HotkeyConfiguration.defaults.dropVoiceTapCombo`,
    /// which would recurse into this same getter on `.defaults` (whose
    /// `dropVoiceShortcut.combo` is now `nil`) and overflow the stack.
    /// Callers that must distinguish "hold Space" from a real combo use
    /// `dropVoiceTapComboIfPresent` instead.
    var dropVoiceTapCombo: HotkeyTapCombo {
        get { dropVoiceShortcut.combo ?? .optionSlash }
        set { dropVoiceShortcut = .combo(newValue) }
    }

    /// The Drop combo only when one actually exists, with no fallback.
    /// Returns `nil` for `.holdSpace` (and any non-combo shortcut) so
    /// callers that must distinguish "hold Space" from a real key combo
    /// don't get a spurious fallback combo.
    var dropVoiceTapComboIfPresent: HotkeyTapCombo? {
        dropVoiceShortcut.combo
    }

    /// Assign a recorded Drop binding. `.holdSpace` forces the `.hold` gesture
    /// (Space is hold-only: a tap is indistinguishable from typing a space);
    /// every other shortcut keeps the user's current gesture choice — `.tap`
    /// (toggle) drops the release callback and runs the start/stop press
    /// routing, `.hold` keeps the release-to-stop flow.
    mutating func setDropShortcut(_ shortcut: HotkeyShortcut) {
        dropVoiceShortcut = shortcut
        dropVoiceGesture = Self.normalizedDropGesture(shortcut: shortcut, gesture: dropVoiceGesture)
    }

    /// The Drop gesture with the Space hold-only rule applied. Stale persisted
    /// state (e.g. `.holdSpace` + `.tap` written by an older build) normalizes
    /// to `.hold` instead of producing a tap-Space monitor that would fire on
    /// every typed space.
    var normalizedDropGesture: HotkeyGesture {
        HotkeyConfiguration.normalizedDropGesture(shortcut: dropVoiceShortcut, gesture: dropVoiceGesture)
    }

    /// The Space hold-only rule as a pure static function so both the instance
    /// property and AppDelegate's inline guards share a single source of truth.
    static func normalizedDropGesture(shortcut: HotkeyShortcut, gesture: HotkeyGesture) -> HotkeyGesture {
        shortcut == .holdSpace ? .hold : gesture
    }

    /// Restore the "hold Space (default)" Drop binding programmatically.
    /// No production callers since the preset chip removal (B3) — the user's
    /// path back is recording a bare Space (B1). Kept as the canonical
    /// programmatic reset, used by tests; dead-code wave 2 decides its fate.
    mutating func resetDropToHoldSpace() {
        dropVoiceShortcut = .holdSpace
        dropVoiceGesture = .hold
    }

    var agentCloseCombo: HotkeyTapCombo {
        get { agentCloseShortcut.combo ?? HotkeyConfiguration.defaults.agentCloseCombo }
        set { agentCloseShortcut = .combo(newValue) }
    }

    var usefulLinksInsertCombo: HotkeyTapCombo {
        get { usefulLinksInsertShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksInsertCombo }
        set { usefulLinksInsertShortcut = .combo(newValue) }
    }

    var usefulLinksOpenCombo: HotkeyTapCombo {
        get { usefulLinksOpenShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksOpenCombo }
        set { usefulLinksOpenShortcut = .combo(newValue) }
    }

    var usefulLinksNextCombo: HotkeyTapCombo {
        get { usefulLinksNextShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksNextCombo }
        set { usefulLinksNextShortcut = .combo(newValue) }
    }

    var usefulLinksPreviousCombo: HotkeyTapCombo {
        get { usefulLinksPreviousShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksPreviousCombo }
        set { usefulLinksPreviousShortcut = .combo(newValue) }
    }

    /// The five Hover-slot shortcuts in slot order (index 0 = slot 1). Read-only
    /// view used by registration and the conflict graph so callers iterate the
    /// positional family without restating each field.
    var hoverSlotShortcuts: [HotkeyShortcut] {
        [
            hoverSlot1Shortcut,
            hoverSlot2Shortcut,
            hoverSlot3Shortcut,
            hoverSlot4Shortcut,
            hoverSlot5Shortcut
        ]
    }

    static let defaults = HotkeyConfiguration(
        agentTextShortcut: .modifier(.rightCommand),
        agentVoiceShortcut: .modifier(.rightCommand),
        agentVoiceGesture: .hold,
        // Drop = hold the Space bar (Stage 4 cutover). `.hold` keeps the
        // default consistent with the Space hold-only rule; even if `.tap`
        // slipped in here, `normalizedDropGesture` would correct it at
        // registration anyway.
        dropVoiceGesture: .hold,
        dropVoiceShortcut: .holdSpace,
        agentCloseShortcut: .combo(.optionQ),
        usefulLinksInsertShortcut: .combo(.leftArrow),
        usefulLinksOpenShortcut: .combo(.rightArrow),
        usefulLinksNextShortcut: .combo(.downArrow),
        usefulLinksPreviousShortcut: .combo(.upArrow)
        // googleSearch* omitted -> defaults to R-Option tap (text) / R-Option hold (voice)
    )
}

enum HotkeyGesture: String, CaseIterable, Codable, Hashable, Identifiable {
    case tap
    case hold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap:
            return "Tap"
        case .hold:
            return "Hold"
        }
    }

    /// Display name for VOICE bindings: `.tap` reads "Toggle" (tap starts,
    /// tap stops); hold rows keep `title` ("Hold"). One-shot actions where
    /// `.tap` genuinely means "tap once" should continue to use `title`.
    var voiceTitle: String { self == .tap ? "Toggle" : title }
}

struct HotkeyBinding: Hashable {
    enum Key: Hashable {
        case modifier(HotkeyModifierKey)
        case combo(HotkeyTapCombo)
        /// Hold-the-space-bar binding. Distinct from `.combo` so it never
        /// collides with a real Option+Space combo during conflict grouping.
        case holdSpace
    }

    let gesture: HotkeyGesture
    let key: Key

    /// Identity used to detect conflicts at the level of the *physical key*.
    ///
    /// - A `.modifier` (Right ⌘ / Right ⌥) can carry a tap/hold split — tap =
    ///   Agent text, hold = Agent voice — so its identity includes the gesture:
    ///   two modifier bindings conflict only when both gesture *and* key match.
    /// - A `.combo` (a real key code) or `.holdSpace` (a bare press-and-hold on
    ///   Space) is one physical key = one action. Its identity drops the gesture
    ///   so that tap and hold on the same ordinary key are reported as a
    ///   conflict — they are indistinguishable to the user and fire falsely
    ///   (ROO-234). `.holdSpace` stays a case of its own, deliberately distinct
    ///   from `.combo` (a recorded combo always carries a modifier, so a
    ///   modifier-less Space combo is unreachable), so it collides only with
    ///   another `.holdSpace`, not with `⌥+Space`.
    enum ConflictKey: Hashable {
        case modifier(HotkeyGesture, HotkeyModifierKey)
        case combo(HotkeyTapCombo)
        case holdSpace
    }

    var conflictKey: ConflictKey {
        switch key {
        case .modifier(let modifierKey):
            return .modifier(gesture, modifierKey)
        case .combo(let combo):
            return .combo(combo)
        case .holdSpace:
            return .holdSpace
        }
    }
}

struct HotkeyBindingAssignment: Equatable {
    let actionTitle: String
    let binding: HotkeyBinding
}

struct HotkeyConflict: Equatable, Identifiable {
    var id: HotkeyBinding { binding }

    let binding: HotkeyBinding
    let actionTitles: [String]

    var message: String {
        "Shortcut \(displayTitle) is already used by \(actionTitles.joined(separator: " and "))."
    }

    private var displayTitle: String {
        switch binding.key {
        case .modifier(let key):
            return key.title
        case .combo(let combo):
            return combo.title
        case .holdSpace:
            return "Space"
        }
    }
}

enum HotkeyConfigurationError: Error, Equatable {
    case conflictingBindings([HotkeyConflict])
}

extension HotkeyConfiguration {
    var assignments: [HotkeyBindingAssignment] {
        [
            HotkeyBindingAssignment(
                actionTitle: "Agent text",
                binding: HotkeyBinding(gesture: .tap, key: agentTextShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Agent voice",
                binding: HotkeyBinding(gesture: agentVoiceGesture, key: agentVoiceShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Drop voice",
                binding: HotkeyBinding(gesture: dropVoiceGesture, key: dropVoiceShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Agent close",
                binding: HotkeyBinding(gesture: .tap, key: agentCloseShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Useful links insert",
                binding: HotkeyBinding(gesture: .tap, key: usefulLinksInsertShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Useful links open",
                binding: HotkeyBinding(gesture: .tap, key: usefulLinksOpenShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Useful links next",
                binding: HotkeyBinding(gesture: .tap, key: usefulLinksNextShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Useful links previous",
                binding: HotkeyBinding(gesture: .tap, key: usefulLinksPreviousShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Hover slot 1",
                binding: HotkeyBinding(gesture: .tap, key: hoverSlot1Shortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Hover slot 2",
                binding: HotkeyBinding(gesture: .tap, key: hoverSlot2Shortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Hover slot 3",
                binding: HotkeyBinding(gesture: .tap, key: hoverSlot3Shortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Hover slot 4",
                binding: HotkeyBinding(gesture: .tap, key: hoverSlot4Shortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Hover slot 5",
                binding: HotkeyBinding(gesture: .tap, key: hoverSlot5Shortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Google text",
                binding: HotkeyBinding(gesture: .tap, key: googleSearchTextShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Google voice",
                binding: HotkeyBinding(gesture: googleSearchVoiceGesture, key: googleSearchVoiceShortcut.bindingKey)
            ),
            HotkeyBindingAssignment(
                actionTitle: "Meeting record",
                binding: HotkeyBinding(gesture: .tap, key: meetingRecordShortcut.bindingKey)
            )
        ]
    }

    var conflicts: [HotkeyConflict] {
        // Group by the physical-key identity (`conflictKey`), not the raw
        // `(gesture, key)` binding: tap/hold on a modifier is an allowed split,
        // but tap/hold on the same ordinary key (combo / hold-Space) is a
        // conflict because the two gestures are indistinguishable there.
        Dictionary(grouping: assignments, by: \.binding.conflictKey)
            .values
            .filter { $0.count > 1 }
            .map { group in
                HotkeyConflict(
                    binding: group[0].binding,
                    actionTitles: group.map(\.actionTitle)
                )
            }
            .sorted { $0.actionTitles.joined() < $1.actionTitles.joined() }
    }
}

enum HotkeyDisplay {
    static func agentTextHint(for configuration: HotkeyConfiguration) -> String {
        "tap \(configuration.agentTextShortcut.compactToken)"
    }

    static func agentVoiceHint(for configuration: HotkeyConfiguration) -> String {
        "\(configuration.agentVoiceGesture.voiceTitle.lowercased()) \(configuration.agentVoiceShortcut.compactToken)"
    }

    static func dropVoiceHint(for configuration: HotkeyConfiguration) -> String {
        "\(configuration.normalizedDropGesture.voiceTitle.lowercased()) \(configuration.dropVoiceShortcut.compactToken)"
    }

    static func agentCloseHint(for configuration: HotkeyConfiguration) -> String {
        "tap \(configuration.agentCloseShortcut.compactToken)"
    }

    static func usefulLinksInsertHint(for configuration: HotkeyConfiguration) -> String {
        "tap \(configuration.usefulLinksInsertShortcut.compactToken)"
    }

    static func usefulLinksOpenHint(for configuration: HotkeyConfiguration) -> String {
        "tap \(configuration.usefulLinksOpenShortcut.compactToken)"
    }

    static func usefulLinksNextHint(for configuration: HotkeyConfiguration) -> String {
        "tap \(configuration.usefulLinksNextShortcut.compactToken)"
    }

    static func usefulLinksPreviousHint(for configuration: HotkeyConfiguration) -> String {
        "tap \(configuration.usefulLinksPreviousShortcut.compactToken)"
    }
}

@MainActor
final class HotkeyPreferences: ObservableObject {
    static let shared = HotkeyPreferences()

    @Published var agentTextShortcut: HotkeyShortcut {
        didSet { save(agentTextShortcut.rawValue, forKey: Self.agentTextShortcutDefaultsKey) }
    }

    @Published var agentVoiceShortcut: HotkeyShortcut {
        didSet { save(agentVoiceShortcut.rawValue, forKey: Self.agentVoiceShortcutDefaultsKey) }
    }

    @Published var agentVoiceGesture: HotkeyGesture {
        didSet { save(agentVoiceGesture.rawValue, forKey: Self.agentVoiceGestureDefaultsKey) }
    }

    @Published var dropVoiceGesture: HotkeyGesture {
        didSet { save(dropVoiceGesture.rawValue, forKey: Self.dropVoiceGestureDefaultsKey) }
    }

    @Published var dropVoiceShortcut: HotkeyShortcut {
        didSet { save(dropVoiceShortcut.rawValue, forKey: Self.dropVoiceShortcutDefaultsKey) }
    }

    @Published var agentCloseShortcut: HotkeyShortcut {
        didSet { save(agentCloseShortcut.rawValue, forKey: Self.agentCloseShortcutDefaultsKey) }
    }

    @Published var usefulLinksInsertShortcut: HotkeyShortcut {
        didSet { save(usefulLinksInsertShortcut.rawValue, forKey: Self.usefulLinksInsertShortcutDefaultsKey) }
    }

    @Published var usefulLinksOpenShortcut: HotkeyShortcut {
        didSet { save(usefulLinksOpenShortcut.rawValue, forKey: Self.usefulLinksOpenShortcutDefaultsKey) }
    }

    @Published var usefulLinksNextShortcut: HotkeyShortcut {
        didSet { save(usefulLinksNextShortcut.rawValue, forKey: Self.usefulLinksNextShortcutDefaultsKey) }
    }

    @Published var usefulLinksPreviousShortcut: HotkeyShortcut {
        didSet { save(usefulLinksPreviousShortcut.rawValue, forKey: Self.usefulLinksPreviousShortcutDefaultsKey) }
    }

    @Published var hoverSlot1Shortcut: HotkeyShortcut {
        didSet { save(hoverSlot1Shortcut.rawValue, forKey: Self.hoverSlot1ShortcutDefaultsKey) }
    }

    @Published var hoverSlot2Shortcut: HotkeyShortcut {
        didSet { save(hoverSlot2Shortcut.rawValue, forKey: Self.hoverSlot2ShortcutDefaultsKey) }
    }

    @Published var hoverSlot3Shortcut: HotkeyShortcut {
        didSet { save(hoverSlot3Shortcut.rawValue, forKey: Self.hoverSlot3ShortcutDefaultsKey) }
    }

    @Published var hoverSlot4Shortcut: HotkeyShortcut {
        didSet { save(hoverSlot4Shortcut.rawValue, forKey: Self.hoverSlot4ShortcutDefaultsKey) }
    }

    @Published var hoverSlot5Shortcut: HotkeyShortcut {
        didSet { save(hoverSlot5Shortcut.rawValue, forKey: Self.hoverSlot5ShortcutDefaultsKey) }
    }

    @Published var meetingRecordShortcut: HotkeyShortcut {
        didSet { save(meetingRecordShortcut.rawValue, forKey: Self.meetingRecordShortcutDefaultsKey) }
    }

    var configuration: HotkeyConfiguration {
        HotkeyConfiguration(
            agentTextShortcut: agentTextShortcut,
            agentVoiceShortcut: agentVoiceShortcut,
            agentVoiceGesture: agentVoiceGesture,
            dropVoiceGesture: dropVoiceGesture,
            dropVoiceShortcut: dropVoiceShortcut,
            agentCloseShortcut: agentCloseShortcut,
            usefulLinksInsertShortcut: usefulLinksInsertShortcut,
            usefulLinksOpenShortcut: usefulLinksOpenShortcut,
            usefulLinksNextShortcut: usefulLinksNextShortcut,
            usefulLinksPreviousShortcut: usefulLinksPreviousShortcut,
            hoverSlot1Shortcut: hoverSlot1Shortcut,
            hoverSlot2Shortcut: hoverSlot2Shortcut,
            hoverSlot3Shortcut: hoverSlot3Shortcut,
            hoverSlot4Shortcut: hoverSlot4Shortcut,
            hoverSlot5Shortcut: hoverSlot5Shortcut,
            meetingRecordShortcut: meetingRecordShortcut
        )
    }

    var agentTextKey: HotkeyModifierKey {
        get { agentTextShortcut.modifierKey ?? HotkeyConfiguration.defaults.agentTextKey }
        set { agentTextShortcut = .modifier(newValue) }
    }

    var agentVoiceKey: HotkeyModifierKey {
        get { agentVoiceShortcut.modifierKey ?? HotkeyConfiguration.defaults.agentVoiceKey }
        set { agentVoiceShortcut = .modifier(newValue) }
    }

    /// See `HotkeyConfiguration.dropVoiceTapCombo`: the fallback is the
    /// literal `.optionSlash`, not the recursive `defaults` accessor, because
    /// the default Drop shortcut is now `.holdSpace` (no combo).
    var dropVoiceTapCombo: HotkeyTapCombo {
        get { dropVoiceShortcut.combo ?? .optionSlash }
        set { dropVoiceShortcut = .combo(newValue) }
    }

    var agentCloseCombo: HotkeyTapCombo {
        get { agentCloseShortcut.combo ?? HotkeyConfiguration.defaults.agentCloseCombo }
        set { agentCloseShortcut = .combo(newValue) }
    }

    var usefulLinksInsertCombo: HotkeyTapCombo {
        get { usefulLinksInsertShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksInsertCombo }
        set { usefulLinksInsertShortcut = .combo(newValue) }
    }

    var usefulLinksOpenCombo: HotkeyTapCombo {
        get { usefulLinksOpenShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksOpenCombo }
        set { usefulLinksOpenShortcut = .combo(newValue) }
    }

    var usefulLinksNextCombo: HotkeyTapCombo {
        get { usefulLinksNextShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksNextCombo }
        set { usefulLinksNextShortcut = .combo(newValue) }
    }

    var usefulLinksPreviousCombo: HotkeyTapCombo {
        get { usefulLinksPreviousShortcut.combo ?? HotkeyConfiguration.defaults.usefulLinksPreviousCombo }
        set { usefulLinksPreviousShortcut = .combo(newValue) }
    }

    private static let legacyAgentGestureKeyDefaultsKey = "hotkeys.agentGestureKey"
    private static let agentTextKeyDefaultsKey = "hotkeys.agentTextKey"
    private static let agentVoiceKeyDefaultsKey = "hotkeys.agentVoiceKey"
    private static let agentTextShortcutDefaultsKey = "hotkeys.agentTextShortcut"
    private static let agentVoiceShortcutDefaultsKey = "hotkeys.agentVoiceShortcut"
    private static let agentVoiceGestureDefaultsKey = "hotkeys.agentVoiceGesture"
    private static let dropVoiceGestureDefaultsKey = "hotkeys.dropVoiceGesture"
    private static let dropVoiceTapComboDefaultsKey = "hotkeys.dropVoiceTapCombo"
    private static let dropVoiceShortcutDefaultsKey = "hotkeys.dropVoiceShortcut"
    private static let agentCloseComboDefaultsKey = "hotkeys.agentCloseCombo"
    private static let agentCloseShortcutDefaultsKey = "hotkeys.agentCloseShortcut"
    private static let usefulLinksInsertComboDefaultsKey = "hotkeys.usefulLinksInsertCombo"
    private static let usefulLinksInsertShortcutDefaultsKey = "hotkeys.usefulLinksInsertShortcut"
    private static let usefulLinksOpenComboDefaultsKey = "hotkeys.usefulLinksOpenCombo"
    private static let usefulLinksOpenShortcutDefaultsKey = "hotkeys.usefulLinksOpenShortcut"
    private static let usefulLinksNextComboDefaultsKey = "hotkeys.usefulLinksNextCombo"
    private static let usefulLinksNextShortcutDefaultsKey = "hotkeys.usefulLinksNextShortcut"
    private static let usefulLinksPreviousComboDefaultsKey = "hotkeys.usefulLinksPreviousCombo"
    private static let usefulLinksPreviousShortcutDefaultsKey = "hotkeys.usefulLinksPreviousShortcut"
    private static let hoverSlot1ShortcutDefaultsKey = "hotkeys.hoverSlot1Shortcut"
    private static let hoverSlot2ShortcutDefaultsKey = "hotkeys.hoverSlot2Shortcut"
    private static let hoverSlot3ShortcutDefaultsKey = "hotkeys.hoverSlot3Shortcut"
    private static let hoverSlot4ShortcutDefaultsKey = "hotkeys.hoverSlot4Shortcut"
    private static let hoverSlot5ShortcutDefaultsKey = "hotkeys.hoverSlot5Shortcut"
    private static let meetingRecordShortcutDefaultsKey = "hotkeys.meetingRecordShortcut"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let legacyAgentKey = defaults
            .string(forKey: Self.legacyAgentGestureKeyDefaultsKey)
            .flatMap(HotkeyModifierKey.init(rawValue:))

        // Non-Drop slots decode through `nonDropShortcut(rawValue:)`: a stale
        // `.holdSpace` is rejected like a decode failure and the slot falls
        // back through its legacy/default chain. Drop (below) keeps the raw
        // decode — `.holdSpace` is its legitimate default.
        if let rawValue = defaults.string(forKey: Self.agentTextShortcutDefaultsKey),
           let value = Self.nonDropShortcut(rawValue: rawValue) {
            self.agentTextShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.agentTextKeyDefaultsKey),
                  let value = HotkeyModifierKey(rawValue: rawValue) {
            self.agentTextShortcut = .modifier(value)
        } else {
            self.agentTextShortcut = .modifier(legacyAgentKey ?? HotkeyConfiguration.defaults.agentTextKey)
        }

        if let rawValue = defaults.string(forKey: Self.agentVoiceShortcutDefaultsKey),
           let value = Self.nonDropShortcut(rawValue: rawValue) {
            self.agentVoiceShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.agentVoiceKeyDefaultsKey),
                  let value = HotkeyModifierKey(rawValue: rawValue) {
            self.agentVoiceShortcut = .modifier(value)
        } else {
            self.agentVoiceShortcut = .modifier(legacyAgentKey ?? HotkeyConfiguration.defaults.agentVoiceKey)
        }

        if let rawValue = defaults.string(forKey: Self.agentVoiceGestureDefaultsKey),
           let value = HotkeyGesture(rawValue: rawValue) {
            self.agentVoiceGesture = value
        } else {
            self.agentVoiceGesture = HotkeyConfiguration.defaults.agentVoiceGesture
        }

        if let rawValue = defaults.string(forKey: Self.dropVoiceGestureDefaultsKey),
           let value = HotkeyGesture(rawValue: rawValue) {
            self.dropVoiceGesture = value
        } else {
            self.dropVoiceGesture = HotkeyConfiguration.defaults.dropVoiceGesture
        }

        if let rawValue = defaults.string(forKey: Self.dropVoiceShortcutDefaultsKey),
           let value = HotkeyShortcut(rawValue: rawValue) {
            self.dropVoiceShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.dropVoiceTapComboDefaultsKey),
                  let value = HotkeyTapCombo(rawValue: rawValue) {
            self.dropVoiceShortcut = .combo(value)
        } else {
            self.dropVoiceShortcut = HotkeyConfiguration.defaults.dropVoiceShortcut
        }

        if let rawValue = defaults.string(forKey: Self.agentCloseShortcutDefaultsKey),
           let value = Self.nonDropShortcut(rawValue: rawValue) {
            self.agentCloseShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.agentCloseComboDefaultsKey),
                  let value = HotkeyTapCombo(rawValue: rawValue) {
            self.agentCloseShortcut = .combo(value)
        } else {
            self.agentCloseShortcut = HotkeyConfiguration.defaults.agentCloseShortcut
        }

        if let rawValue = defaults.string(forKey: Self.usefulLinksInsertShortcutDefaultsKey),
           let value = Self.nonDropShortcut(rawValue: rawValue) {
            self.usefulLinksInsertShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.usefulLinksInsertComboDefaultsKey),
                  let value = HotkeyTapCombo(rawValue: rawValue) {
            self.usefulLinksInsertShortcut = .combo(value)
        } else {
            self.usefulLinksInsertShortcut = HotkeyConfiguration.defaults.usefulLinksInsertShortcut
        }

        if let rawValue = defaults.string(forKey: Self.usefulLinksOpenShortcutDefaultsKey),
           let value = Self.nonDropShortcut(rawValue: rawValue) {
            self.usefulLinksOpenShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.usefulLinksOpenComboDefaultsKey),
                  let value = HotkeyTapCombo(rawValue: rawValue) {
            self.usefulLinksOpenShortcut = .combo(value)
        } else {
            self.usefulLinksOpenShortcut = HotkeyConfiguration.defaults.usefulLinksOpenShortcut
        }

        if let rawValue = defaults.string(forKey: Self.usefulLinksNextShortcutDefaultsKey),
           let value = Self.nonDropShortcut(rawValue: rawValue) {
            self.usefulLinksNextShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.usefulLinksNextComboDefaultsKey),
                  let value = HotkeyTapCombo(rawValue: rawValue) {
            self.usefulLinksNextShortcut = .combo(value)
        } else {
            self.usefulLinksNextShortcut = HotkeyConfiguration.defaults.usefulLinksNextShortcut
        }

        if let rawValue = defaults.string(forKey: Self.usefulLinksPreviousShortcutDefaultsKey),
           let value = Self.nonDropShortcut(rawValue: rawValue) {
            self.usefulLinksPreviousShortcut = value
        } else if let rawValue = defaults.string(forKey: Self.usefulLinksPreviousComboDefaultsKey),
                  let value = HotkeyTapCombo(rawValue: rawValue) {
            self.usefulLinksPreviousShortcut = .combo(value)
        } else {
            self.usefulLinksPreviousShortcut = HotkeyConfiguration.defaults.usefulLinksPreviousShortcut
        }

        // Hover-slot shortcuts are new keys (no legacy combo fallback): load the
        // stored shortcut or seed the ⌥1..⌥5 default.
        self.hoverSlot1Shortcut = Self.loadShortcut(
            defaults, Self.hoverSlot1ShortcutDefaultsKey,
            default: HotkeyConfiguration.defaults.hoverSlot1Shortcut
        )
        self.hoverSlot2Shortcut = Self.loadShortcut(
            defaults, Self.hoverSlot2ShortcutDefaultsKey,
            default: HotkeyConfiguration.defaults.hoverSlot2Shortcut
        )
        self.hoverSlot3Shortcut = Self.loadShortcut(
            defaults, Self.hoverSlot3ShortcutDefaultsKey,
            default: HotkeyConfiguration.defaults.hoverSlot3Shortcut
        )
        self.hoverSlot4Shortcut = Self.loadShortcut(
            defaults, Self.hoverSlot4ShortcutDefaultsKey,
            default: HotkeyConfiguration.defaults.hoverSlot4Shortcut
        )
        self.hoverSlot5Shortcut = Self.loadShortcut(
            defaults, Self.hoverSlot5ShortcutDefaultsKey,
            default: HotkeyConfiguration.defaults.hoverSlot5Shortcut
        )
        self.meetingRecordShortcut = Self.loadShortcut(
            defaults, Self.meetingRecordShortcutDefaultsKey,
            default: HotkeyConfiguration.defaults.meetingRecordShortcut
        )
    }

    /// Decode a persisted NON-Drop shortcut. `.holdSpace` is Drop-only — the
    /// SpaceHold tap asserts a release handler that non-Drop registrations
    /// legitimately don't pass — so a stale persisted `.holdSpace` on a
    /// non-Drop slot (written by builds where the recorder emitted it before
    /// the Settings gate existed, or a hand-edited plist) is treated exactly
    /// like a decode failure: the caller falls through to its existing
    /// fallback chain (legacy key, then the slot default). Drop's own load
    /// path uses raw `HotkeyShortcut(rawValue:)` and keeps `.holdSpace`.
    private static func nonDropShortcut(rawValue: String) -> HotkeyShortcut? {
        guard let value = HotkeyShortcut(rawValue: rawValue), value != .holdSpace else {
            return nil
        }
        return value
    }

    /// Load helper for the Hover-slot family (all non-Drop): stored shortcut
    /// or the slot default. Routes through `nonDropShortcut(rawValue:)`, so a
    /// stale `.holdSpace` also falls back to the default.
    private static func loadShortcut(
        _ defaults: UserDefaults,
        _ key: String,
        default fallback: HotkeyShortcut
    ) -> HotkeyShortcut {
        guard let rawValue = defaults.string(forKey: key),
              let value = nonDropShortcut(rawValue: rawValue) else {
            return fallback
        }
        return value
    }

    func apply(_ configuration: HotkeyConfiguration) throws {
        let conflicts = configuration.conflicts
        guard conflicts.isEmpty else {
            throw HotkeyConfigurationError.conflictingBindings(conflicts)
        }
        agentTextShortcut = configuration.agentTextShortcut
        agentVoiceShortcut = configuration.agentVoiceShortcut
        agentVoiceGesture = configuration.agentVoiceGesture
        // Space hold-only rule on the write path: a stale `.holdSpace`+`.tap`
        // pair (older builds) heals on Save instead of round-tripping through
        // the plist forever. Same single source the display and registration
        // paths use.
        dropVoiceGesture = configuration.normalizedDropGesture
        dropVoiceShortcut = configuration.dropVoiceShortcut
        agentCloseShortcut = configuration.agentCloseShortcut
        usefulLinksInsertShortcut = configuration.usefulLinksInsertShortcut
        usefulLinksOpenShortcut = configuration.usefulLinksOpenShortcut
        usefulLinksNextShortcut = configuration.usefulLinksNextShortcut
        usefulLinksPreviousShortcut = configuration.usefulLinksPreviousShortcut
        hoverSlot1Shortcut = configuration.hoverSlot1Shortcut
        hoverSlot2Shortcut = configuration.hoverSlot2Shortcut
        hoverSlot3Shortcut = configuration.hoverSlot3Shortcut
        hoverSlot4Shortcut = configuration.hoverSlot4Shortcut
        hoverSlot5Shortcut = configuration.hoverSlot5Shortcut
        meetingRecordShortcut = configuration.meetingRecordShortcut
    }

    func resetToDefaults() {
        agentTextShortcut = HotkeyConfiguration.defaults.agentTextShortcut
        agentVoiceShortcut = HotkeyConfiguration.defaults.agentVoiceShortcut
        agentVoiceGesture = HotkeyConfiguration.defaults.agentVoiceGesture
        dropVoiceGesture = HotkeyConfiguration.defaults.dropVoiceGesture
        dropVoiceShortcut = HotkeyConfiguration.defaults.dropVoiceShortcut
        agentCloseShortcut = HotkeyConfiguration.defaults.agentCloseShortcut
        usefulLinksInsertShortcut = HotkeyConfiguration.defaults.usefulLinksInsertShortcut
        usefulLinksOpenShortcut = HotkeyConfiguration.defaults.usefulLinksOpenShortcut
        usefulLinksNextShortcut = HotkeyConfiguration.defaults.usefulLinksNextShortcut
        usefulLinksPreviousShortcut = HotkeyConfiguration.defaults.usefulLinksPreviousShortcut
        hoverSlot1Shortcut = HotkeyConfiguration.defaults.hoverSlot1Shortcut
        hoverSlot2Shortcut = HotkeyConfiguration.defaults.hoverSlot2Shortcut
        hoverSlot3Shortcut = HotkeyConfiguration.defaults.hoverSlot3Shortcut
        hoverSlot4Shortcut = HotkeyConfiguration.defaults.hoverSlot4Shortcut
        hoverSlot5Shortcut = HotkeyConfiguration.defaults.hoverSlot5Shortcut
        meetingRecordShortcut = HotkeyConfiguration.defaults.meetingRecordShortcut
    }

    private func save(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
