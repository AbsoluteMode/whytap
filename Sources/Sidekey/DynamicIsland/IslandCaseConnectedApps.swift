import AppKit
import SwiftUI

/// Registrations are persistent connections, not live process activity.
struct IslandCaseConnectedApps: View {
    let registrations: [CaseAppRegistration]
    let onOpenAccess: (UUID) -> Void
    let onConnect: () -> Void

    static func visibleRegistrations(_ registrations: [CaseAppRegistration]) -> [CaseAppRegistration] {
        registrations.filter { $0.identity != .builtInOpenCode }
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Self.visibleRegistrations(registrations)) { app in
                        CaseConnectedAppButton(app: app) { onOpenAccess(app.id) }
                    }
                }
            }
            Button(action: onConnect) {
                Label("Connect", systemImage: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .contentShape(Capsule())
            }
            .buttonStyle(CaseAccessButtonStyle(cornerRadius: 14))
            .foregroundStyle(.white.opacity(0.92))
            .fixedSize()
            .help("Connect an agent and choose its access")
            .accessibilityIdentifier("case.access.open")
        }
        .frame(height: 30)
    }

    static func brandAsset(for identity: CaseAppIdentity) -> String? {
        switch CaseKnownClient(identity: identity) {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .cursor: return "cursor"
        default: return nil
        }
    }

    static func highlight(for identity: CaseAppIdentity) -> CaseAppHighlight {
        switch CaseKnownClient(identity: identity) {
        case .claudeCode: return .orange
        case .codex: return .blue
        default: return .neutral
        }
    }
}

enum CaseAppHighlight: Equatable {
    case blue, orange, neutral

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.35, green: 0.65, blue: 1)
        case .orange: return Color(red: 1, green: 0.61, blue: 0.34)
        case .neutral: return .white
        }
    }
}

private struct CaseConnectedAppButton: View {
    let app: CaseAppRegistration
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private var active: Bool { isEnabled && (hovering || focused) }

    var body: some View {
        Button(action: action) {
            CaseConnectedAppIcon(app: app, isHighlighted: active, isFocused: focused && isEnabled)
        }
        .buttonStyle(CaseAccessButtonStyle(cornerRadius: 14))
        .focused($focused)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        .help(app.displayName)
        .accessibilityLabel("\(app.displayName), connected to Case. Change access")
        .accessibilityIdentifier("case.access.app.\(app.id)")
    }


}

/// Shared visual for hover/focus and native offscreen verification.
struct CaseConnectedAppIcon: View {
    let app: CaseAppRegistration
    let isHighlighted: Bool
    var isFocused = false
    private var active: Bool { isHighlighted }
    private var accent: Color { IslandCaseConnectedApps.highlight(for: app.identity).color }

    var body: some View {
            CaseAppBrandIcon(identity: app.identity, size: 18, color: active ? accent : .white.opacity(0.88))
                .foregroundStyle(active ? accent : .white.opacity(0.88))
                .frame(width: 28, height: 28)
                .background(Circle().fill(active ? accent.opacity(0.15) : .clear))
                .overlay(Circle().strokeBorder(isFocused ? accent : .clear, lineWidth: 1))
                .shadow(color: active ? accent.opacity(0.45) : .clear, radius: 4)
                .contentShape(Rectangle())
    }

}

/// The same bundled brand mark is used for Connect and saved registrations.
struct CaseAppBrandIcon: View {
    let identity: CaseAppIdentity
    var size: CGFloat = 18
    var color: Color = .white

    @ViewBuilder
    var body: some View {
        if let asset = IslandCaseConnectedApps.brandAsset(for: identity) {
            ProviderBrandIcon(assetName: asset, size: size, color: color)
        } else if case let .executablePath(path) = identity,
                  FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: size * 0.9, weight: .medium))
                .accessibilityHidden(true)
        }
    }
}
