import SwiftUI

/// Settings -> Toolbox -> Display: Hold, Extra and Brightness keys for the island
/// display, without opening the island. It reads the display when it appears and then follows
/// the controller's display notifications. Opening Settings starts no polling; an enabled
/// Hold or Extra owns its own timer independently of the Settings window.
@MainActor
struct ToolboxDisplayPane: View {
    static let noExtraText = "This display has no extra brightness."
    /// Replaces the Brightness keys description while macOS refuses the keys.
    static let keysRefusedText = "Needs Accessibility. Allow it in Permissions."

    @ObservedObject private var controller: ScreenBrightnessController
    @ObservedObject private var keys: BrightnessKeys

    /// Nil uses the shared instances; default arguments would read them outside the main actor.
    init(controller: ScreenBrightnessController? = nil, keys: BrightnessKeys? = nil) {
        self.controller = controller ?? .shared
        self.keys = keys ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacCard {
                MacRow(title: "Hold brightness", subtitle: "Restores this level. Adjust with Whytap's slider or Brightness keys. Uses more battery.") {
                    MacSwitch(isOn: Binding(get: { controller.isHoldingLevel }, set: { controller.setHoldingLevel($0) }))
                        .disabled(!controller.isAvailable)
                        .accessibilityLabel("Hold brightness")
                }
                MacRowSeparator()
                if controller.supportsExtra {
                    MacRow(title: "Extra", subtitle: "First decrease only turns Extra off. Uses more battery.") {
                        MacSwitch(isOn: Binding(get: { controller.isExtraOn }, set: { controller.setExtra($0) }))
                            .accessibilityLabel("Extra brightness")
                    }
                    MacRowSeparator()
                }
                MacRow(title: "Brightness keys", subtitle: keysSubtitle) {
                    MacSwitch(isOn: Binding(get: { keys.isEnabled }, set: { keys.setEnabled($0) }))
                        .accessibilityLabel("Brightness keys")
                }
            }

            if !controller.supportsExtra {
                Text(controller.isAvailable ? Self.noExtraText : IslandBrightnessStrip.unavailableText)
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = controller.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(MacSettingsTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            controller.refresh()
            // Accessibility may have been allowed since macOS refused the keys.
            keys.retryIfNeeded()
        }
    }

    private var keysSubtitle: String {
        if keys.isEnabled, !keys.isListening { return Self.keysRefusedText }
        let island = "Shown in the island instead of macOS."
        return controller.supportsExtra ? island + " Press up twice at full brightness for Extra." : island
    }
}
