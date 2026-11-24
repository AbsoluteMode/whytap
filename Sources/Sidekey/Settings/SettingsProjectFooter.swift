import AppKit
import SwiftUI

/// App identity and browser destinations share a type scale, but separate rows.
struct SettingsProjectFooter: View {
    let identity: AppBuildIdentity
    /// Nil only in previews and tests without an app delegate: no button.
    var updateController: UpdateController?
    /// With releases to show, the version is a button that opens What's New.
    // WHY: .project-docs/decisions/2026-11-24-whats-new-window.md
    var whatsNew: WhatsNewPresenter?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let whatsNew, !whatsNew.history.isEmpty {
                    Button { whatsNew.presentHistory() } label: {
                        Text("\(identity.name) \(identity.version)").lineLimit(1)
                    }
                    .buttonStyle(SettingsFooterLinkStyle())
                    .padding(.leading, -6)
                    .help("What’s new in \(identity.name) \(identity.version)")
                    .accessibilityLabel("\(identity.name) \(identity.version)")
                    .accessibilityHint("Shows what’s new in this version")
                } else {
                    Text("\(identity.name) \(identity.version)")
                        .foregroundStyle(MacSettingsTheme.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let updateController {
                    SettingsFooterUpdateButton(controller: updateController)
                }
            }
            .padding(.leading, SettingsSidebarStyle.buttonHorizontalPadding)
            .padding(.trailing, SettingsSidebarStyle.buttonHorizontalPadding - 6)

            Rectangle()
                .fill(MacSettingsTheme.sep)
                .frame(height: 1)
                .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                SettingsFooterLink(title: "Whytap", destination: URL(string: "https://whytap.ai")!)
                SettingsFooterLink(title: "GitHub", destination: BuildConfig.landingURL, brand: "github")
            }
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding - 6)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

/// Keeps an available update reachable after ✕ hid the island pill: the
/// same Update / Restart action as the pill, for as long as the app runs.
/// WHY: .project-docs/decisions/2026-11-21-settings-update-button.md
private struct SettingsFooterUpdateButton: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        if let offer = controller.settingsOffer {
            Button {
                controller.updateFromSettings()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: Self.symbol(for: offer.action))
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(Self.title(for: offer.action))
                        .lineLimit(1)
                }
            }
            .buttonStyle(SettingsFooterLinkStyle(prominent: offer.action != .downloading))
            .disabled(offer.action == .downloading)
            .help(Self.help(for: offer))
            .accessibilityLabel(Self.title(for: offer.action))
            .accessibilityHint(Self.help(for: offer))
        }
    }

    static func title(for action: SettingsUpdateOffer.Action) -> String {
        switch action {
        case .update: "Update"
        case .downloading: "Updating…"
        case .restart: "Restart"
        }
    }

    static func symbol(for action: SettingsUpdateOffer.Action) -> String {
        switch action {
        case .update, .downloading: "arrow.down.circle"
        case .restart: "arrow.clockwise"
        }
    }

    static func help(for offer: SettingsUpdateOffer) -> String {
        switch offer.action {
        case .update: "Download and install Whytap \(offer.displayVersion)"
        case .downloading: "Downloading Whytap \(offer.displayVersion)"
        case .restart: "Restart to finish updating to Whytap \(offer.displayVersion)"
        }
    }
}

private struct SettingsFooterLink: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let destination: URL
    var brand: String?

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 5) {
                icon
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
            }
        }
        .buttonStyle(SettingsFooterLinkStyle())
        .help(destination.absoluteString)
        .accessibilityLabel(title)
        .accessibilityHint("Opens \(destination.absoluteString) in your browser")
    }

    @ViewBuilder
    private var icon: some View {
        if let brand, let image = UsefulLinkIconAsset.image(named: brand) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Circle()
                .strokeBorder(colorScheme == .dark ? Color.white : Color.black, lineWidth: 1.5)
        }
    }
}

private struct SettingsFooterLinkStyle: ButtonStyle {
    /// Accent text for an action that needs attention (Update / Restart).
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, prominent: prominent)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(pressed ? MacSettingsTheme.selection : (highlighted ? MacSettingsTheme.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // A disabled control (Updating…) shows no pointing hand.
                .background { if isEnabled { SettingsFooterLinkCursor() } }
                .onHover { hovered = $0 }
        }

        /// The pointer can stay over Update while it turns into Updating….
        private var highlighted: Bool { isEnabled && hovered }
        private var pressed: Bool { isEnabled && configuration.isPressed }

        private var foreground: Color {
            if !isEnabled { return MacSettingsTheme.text3 }
            if prominent { return pressed ? MacSettingsTheme.accentPress : MacSettingsTheme.accent }
            return highlighted || pressed ? MacSettingsTheme.text : MacSettingsTheme.text2
        }
    }
}

/// Cursor rectangles follow view/window lifetime without a global cursor stack.
private struct SettingsFooterLinkCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
