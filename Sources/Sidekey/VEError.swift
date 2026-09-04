import Foundation

enum VEError: Error, CustomStringConvertible {
    case hotkeyFailed(String)
    case recorderNotStarted
    case audioFileEmpty

    var description: String {
        switch self {
        case .hotkeyFailed(let message):
            return "Hotkey monitor failed: \(message). Check Accessibility permission in System Settings → Privacy & Security."
        case .recorderNotStarted:
            return "Audio recorder is not running."
        case .audioFileEmpty:
            return "Recorded audio is empty."
        }
    }
}
