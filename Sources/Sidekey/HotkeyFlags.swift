import Foundation

/// Pure-logic helper for testing CGEvent flag values from
/// `RightCmdGestureMonitor`.
///
/// CGEventFlags raw bits (from CGEventTypes.h):
/// - NX_DEVICERCMDKEYMASK (device-dependent right Command) = 0x10
/// - NX_DEVICELALTKEYMASK (device-dependent left Option) = 0x20
/// - NX_DEVICERALTKEYMASK (device-dependent right Option) = 0x40
/// - kCGEventFlagMaskCommand = 0x100000
/// - kCGEventFlagMaskShift = 0x020000
/// - kCGEventFlagMaskControl = 0x040000
/// - kCGEventFlagMaskAlternate (general Option) = 0x080000
/// - kCGEventFlagMaskAlphaShift (caps lock) = 0x010000
enum HotkeyFlags {
    static let rightCommandMask: UInt64 = 0x10
    static let leftCommandMask: UInt64 = 0x08
    static let leftOptionMask: UInt64 = 0x20
    static let rightOptionMask: UInt64 = 0x40

    private static let shiftMask: UInt64 = 0x020000
    private static let controlMask: UInt64 = 0x040000
    private static let commandMask: UInt64 = 0x100000
    private static let alternateMask: UInt64 = 0x080000

    /// Returns true iff the device-dependent right Command bit is set and no
    /// other functional modifier is held. The general Command mask is expected
    /// because right Command itself contributes it.
    static func isRightCommandOnly(_ rawFlags: UInt64) -> Bool {
        isOnly(.rightCommand, rawFlags)
    }

    static func isRightCommandHeld(_ rawFlags: UInt64) -> Bool {
        isHeld(.rightCommand, rawFlags)
    }

    static func isOnly(_ key: HotkeyModifierKey, _ rawFlags: UInt64) -> Bool {
        switch key {
        case .rightCommand:
            let rightCommandSet = (rawFlags & rightCommandMask) == rightCommandMask
            let leftCommandSet = (rawFlags & leftCommandMask) == leftCommandMask
            let noOtherModifier = (rawFlags & (shiftMask | controlMask | alternateMask)) == 0
            return rightCommandSet && !leftCommandSet && noOtherModifier
        case .rightOption:
            let rightOptionSet = (rawFlags & rightOptionMask) == rightOptionMask
            let leftOptionSet = (rawFlags & leftOptionMask) == leftOptionMask
            let noOtherModifier = (rawFlags & (shiftMask | controlMask | commandMask)) == 0
            return rightOptionSet && !leftOptionSet && noOtherModifier
        }
    }

    static func isHeld(_ key: HotkeyModifierKey, _ rawFlags: UInt64) -> Bool {
        switch key {
        case .rightCommand:
            return (rawFlags & rightCommandMask) == rightCommandMask
        case .rightOption:
            return (rawFlags & rightOptionMask) == rightOptionMask
        }
    }
}
