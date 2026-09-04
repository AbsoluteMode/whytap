import AppKit
import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the permissions screen. Brand words (Whytap) and
/// the faux macOS "Privacy & Security" panel labels stay English — the
/// latter mirrors the real OS panel, which renders in the system
/// language, not the app's onboarding language.
protocol OnboardingPermissionsCopy {
    var headlineLead: String { get }
    var headlineTail: String { get }
    var subtitle: String { get }
    var micTitle: String { get }
    var micDesc: String { get }
    var accessibilityTitle: String { get }
    var accessibilityDesc: String { get }
    var accessibilityReassurance: String { get }
    var back: String { get }
    var ccontinue: String { get }
    /// "n / 2 granted" — `n` substituted at the call site.
    func grantedCount(_ n: Int) -> String
    var statusOn: String { get }
    var statusRequesting: String { get }
    var enable: String { get }
    var unlockReady: String { get }
    var unlockWaiting: String { get }
}

struct OnboardingPermissionsCopyEN: OnboardingPermissionsCopy {
    let headlineLead = "Two quick "
    let headlineTail = "permissions."
    let subtitle = "Both are required so your voice becomes text where you need it. Nothing is shared elsewhere."
    let micTitle = "Microphone"
    let micDesc = "So Whytap can hear you."
    let accessibilityTitle = "Accessibility"
    let accessibilityDesc = "So Whytap can paste at your cursor."
    let accessibilityReassurance = "Accessibility is read-only — used to type, never to read your screen."
    let back = "Back"
    let ccontinue = "Continue"
    func grantedCount(_ n: Int) -> String { "\(n) / 2 granted" }
    let statusOn = "On"
    let statusRequesting = "Requesting"
    let enable = "Enable"
    let unlockReady = "Ready to run."
    let unlockWaiting = "Waiting for permissions…"
}

struct OnboardingPermissionsCopyRU: OnboardingPermissionsCopy {
    let headlineLead = "Два коротких "
    let headlineTail = "разрешения."
    let subtitle = "Оба нужны, чтобы ваш голос превращался в текст там, где вам это нужно. Whytap слушает только пока вы держите клавишу — никакой записи в фоне, больше никуда ничего не передаётся."
    let micTitle = "Микрофон"
    let micDesc = "Чтобы Whytap вас слышал."
    let accessibilityTitle = "Универсальный доступ"
    let accessibilityDesc = "Чтобы Whytap вставлял текст у курсора."
    let accessibilityReassurance = "Универсальный доступ нужен, чтобы вставлять текст у курсора, а не читать ваш экран."
    let back = "Назад"
    let ccontinue = "Продолжить"
    func grantedCount(_ n: Int) -> String { "выдано \(n) из 2" }
    let statusOn = "Вкл"
    let statusRequesting = "Запрос"
    let enable = "Включить"
    let unlockReady = "Готов к работе."
    let unlockWaiting = "Ждём разрешений…"
}

func onboardingPermissionsCopy(for language: OnboardingUILanguage) -> OnboardingPermissionsCopy {
    switch language {
    case .en: return OnboardingPermissionsCopyEN()
    case .ru: return OnboardingPermissionsCopyRU()
    }
}

/// Screen 03 of the onboarding flow — system permissions + the
/// usage-data sharing opt-in. Microphone + Accessibility are the two
/// system permissions Sidekey needs to run; Screen Recording is no
/// longer required (we removed the always-on luminance feature).
/// Share-data is a non-blocking opt-in for the Langfuse observability
/// service.
///
/// Generic over an `OnboardingPermissionsSurface` so the same view
/// drives the real Sidekey flow (`RealOnboardingPermissionsSurface`)
/// and the preview's scripted cycle (`MockOnboardingPermissionsSurface`).
struct OnboardingPermissionsScreen<Surface: OnboardingPermissionsSurface>: View {
    @ObservedObject var surface: Surface
    /// `nil` when this is the first step of the tour (no Back target).
    let onBack: (() -> Void)?
    let onContinue: () -> Void

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingPermissionsCopy { onboardingPermissionsCopy(for: locale.language) }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
                .background(OnboardingTheme.bg)
                .overlay(
                    Rectangle().fill(OnboardingTheme.border).frame(width: 0.5),
                    alignment: .trailing
                )
            rightPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { surface.start() }
        .onDisappear { surface.stop() }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headline
                Text(copy.subtitle)
                    .font(OnboardingTheme.sans(14))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                PermissionCard(
                    icon: "mic",
                    title: copy.micTitle,
                    desc: copy.micDesc,
                    status: surface.mic,
                    statusOn: copy.statusOn,
                    statusRequesting: copy.statusRequesting,
                    enableLabel: copy.enable,
                    onEnable: surface.requestMic
                )
                PermissionCard(
                    icon: "cursorarrow.rays",
                    title: copy.accessibilityTitle,
                    desc: copy.accessibilityDesc,
                    status: surface.accessibility,
                    statusOn: copy.statusOn,
                    statusRequesting: copy.statusRequesting,
                    enableLabel: copy.enable,
                    onEnable: surface.requestAccessibility
                )
            }
            .padding(.top, 22)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(OnboardingTheme.muted)
                Text(copy.accessibilityReassurance)
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 40, leading: 36, bottom: 22, trailing: 28))
    }

    private var headline: some View {
        (
            Text(copy.headlineLead).font(OnboardingTheme.serif(42, language: locale.language))
            + Text(copy.headlineTail).font(OnboardingTheme.serifItalic(42, language: locale.language))
        )
        .foregroundColor(OnboardingTheme.ink)
        .kerning(-0.6)
        .lineSpacing(-6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        // Spacer-text-Spacer keeps "n / 2 GRANTED" equidistant from
        // the Back label and the Continue capsule's *visible* edges —
        // a centre-overlay would land on the geometric midpoint, but
        // the Continue capsule has more visual mass than the plain
        // Back text so the indicator would read as off-centre.
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text(copy.back)
                    }
                    .font(OnboardingTheme.sans(13, weight: .medium))
                    .foregroundColor(OnboardingTheme.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            if !surface.allRequiredGranted {
                Text(copy.grantedCount(grantedCount))
                    .font(OnboardingTheme.mono(10.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundColor(OnboardingTheme.faint)
                    .textCase(.uppercase)
                    .fixedSize()
            }

            Spacer(minLength: 0)

            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Text(copy.ccontinue)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(surface.allRequiredGranted ? OnboardingTheme.bg : OnboardingTheme.muted)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    Capsule(style: .continuous)
                        .fill(surface.allRequiredGranted ? OnboardingTheme.ink : OnboardingTheme.surface2)
                )
            }
            .buttonStyle(.plain)
            .disabled(!surface.allRequiredGranted)
        }
    }

    private var grantedCount: Int {
        (surface.mic == .granted ? 1 : 0) + (surface.accessibility == .granted ? 1 : 0)
    }

    // MARK: - Right pane

    private var rightPane: some View {
        ZStack {
            PermissionsRightPaneBackdrop()
            VStack(spacing: 16) {
                FakeSystemSettingsPanel(
                    micStatus: surface.mic,
                    accessibilityStatus: surface.accessibility
                )
                SidekeyUnlockCard(
                    unlocked: surface.allRequiredGranted,
                    readyLabel: copy.unlockReady,
                    waitingLabel: copy.unlockWaiting
                )
            }
            .frame(maxWidth: 420)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Permission card

private struct PermissionCard: View {
    let icon: String
    let title: String
    let desc: String
    let status: OnboardingPermissionStatus
    let statusOn: String
    let statusRequesting: String
    let enableLabel: String
    let onEnable: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(status == .granted ? Color(red: 0.31, green: 0.78, blue: 0.51) : OnboardingTheme.ink2)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OnboardingTheme.surface2)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OnboardingTheme.sans(13.5, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                Text(desc)
                    .font(OnboardingTheme.sans(12))
                    .foregroundColor(OnboardingTheme.muted)
            }

            Spacer()

            trailing
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OnboardingTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(status == .granted ? Color(red: 0.31, green: 0.78, blue: 0.51).opacity(0.4) : OnboardingTheme.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .granted:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                Text(statusOn)
                    .font(OnboardingTheme.mono(10.5, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
            }
            .foregroundColor(Color(red: 0.31, green: 0.78, blue: 0.51))
        case .requesting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(OnboardingTheme.accent)
                Text(statusRequesting)
                    .font(OnboardingTheme.mono(10.5, weight: .medium))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundColor(OnboardingTheme.muted)
            }
        case .denied:
            PermissionActionButton(title: enableLabel, tone: .primary, action: onEnable)
        case .pending:
            PermissionActionButton(title: enableLabel, tone: .primary, action: onEnable)
        }
    }
}

private enum PermissionActionButtonTone {
    case primary
    case secondary
}

private struct PermissionActionButton: View {
    let title: String
    let tone: PermissionActionButtonTone
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OnboardingTheme.sans(12, weight: .medium))
                .foregroundColor(foregroundColor)
                .frame(width: 126, height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(borderColor, lineWidth: isHovering ? 1.1 : 0.5)
                )
                .shadow(
                    color: shadowColor,
                    radius: isHovering ? 10 : 0,
                    x: 0,
                    y: isHovering ? 3 : 0
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
    }

    private var foregroundColor: Color {
        switch tone {
        case .primary: return OnboardingTheme.bg
        case .secondary: return OnboardingTheme.ink
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .primary:
            return isHovering ? Color.white : OnboardingTheme.ink
        case .secondary:
            return isHovering ? OnboardingTheme.surface3 : OnboardingTheme.surface2
        }
    }

    private var borderColor: Color {
        switch tone {
        case .primary:
            return isHovering ? Color.white.opacity(0.85) : Color.white.opacity(0.08)
        case .secondary:
            return isHovering ? OnboardingTheme.ink.opacity(0.26) : OnboardingTheme.border
        }
    }

    private var shadowColor: Color {
        switch tone {
        case .primary:
            return Color.white.opacity(0.18)
        case .secondary:
            return Color.black.opacity(0.24)
        }
    }
}

// MARK: - Right pane backdrop

private struct PermissionsRightPaneBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: OnboardingTheme.accent.opacity(0.22), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.80, y: 0.10),
                        startRadius: 0,
                        endRadius: 620
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.03), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.10, y: 1.0),
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            )
    }
}

// MARK: - Faux macOS System Settings panel (right pane visual)

private struct FakeSystemSettingsPanel: View {
    let micStatus: OnboardingPermissionStatus
    let accessibilityStatus: OnboardingPermissionStatus

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 14) {
                section(
                    label: "Microphone",
                    rows: [
                        SettingsRowData(name: "Whytap", status: micStatus, highlight: true, icon: .whytap),
                        SettingsRowData(name: "Voice Memos", status: .granted, icon: .voiceMemos),
                        SettingsRowData(name: "Zoom", status: .granted, icon: .zoom)
                    ]
                )
                section(
                    label: "Accessibility",
                    rows: [
                        SettingsRowData(name: "Whytap", status: accessibilityStatus, highlight: true, icon: .whytap),
                        SettingsRowData(name: "Raycast", status: .granted, icon: .raycast),
                        SettingsRowData(name: "Cleanshot", status: .granted, icon: .cleanshot)
                    ]
                )
            }
            .padding(14)
            .background(OnboardingTheme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.40), radius: 30, x: 0, y: 20)
        .shadow(color: .black.opacity(0.20), radius: 8, x: 0, y: 4)
    }

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 6) {
                Circle().fill(OnboardingTheme.trafficRed).frame(width: 9, height: 9)
                Circle().fill(OnboardingTheme.trafficYellow).frame(width: 9, height: 9)
                Circle().fill(OnboardingTheme.trafficGreen).frame(width: 9, height: 9)
                Spacer()
            }
            Text("Privacy & Security")
                .font(OnboardingTheme.sans(12, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(OnboardingTheme.surface2)
        .overlay(
            Rectangle().fill(OnboardingTheme.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// Icon shown in the left chip of a settings row. Replaces the old
    /// first-letter monogram with a per-app glyph + brand-tinted tile so
    /// the faux panel reads like the real macOS list.
    private struct AppIcon {
        let symbol: String
        let tile: Color
        let glyph: Color
        var size: CGFloat = 11.5
        /// Real app-icon PNG name (extracted from the installed .app). When it
        /// loads, the row shows the genuine icon; otherwise the symbol+tile
        /// fallback is used (e.g. for apps not installed on this machine).
        var asset: String? = nil

        // Whytap shows its real logo (replaces the old lightning bolt).
        static let whytap = AppIcon(
            symbol: "bolt.fill", tile: OnboardingTheme.accent, glyph: OnboardingTheme.bg, asset: "whytap"
        )
        static let voiceMemos = AppIcon(
            symbol: "mic.fill",
            tile: Color(red: 0.17, green: 0.17, blue: 0.18),
            glyph: Color(red: 1.0, green: 0.29, blue: 0.29),
            asset: "voicememos"
        )
        static let zoom = AppIcon(
            symbol: "video.fill",
            tile: Color(red: 0.176, green: 0.549, blue: 1.0),
            glyph: .white,
            asset: "zoom"
        )
        static let raycast = AppIcon(
            symbol: "command",
            tile: Color(red: 1.0, green: 0.388, blue: 0.388),
            glyph: .white,
            asset: "raycast"
        )
        static let cleanshot = AppIcon(
            symbol: "camera.fill",
            tile: Color(red: 0.122, green: 0.714, blue: 0.651),
            glyph: .white,
            asset: "cleanshot"
        )
    }

    private struct SettingsRowData {
        let name: String
        let status: OnboardingPermissionStatus
        var highlight: Bool = false
        let icon: AppIcon
    }

    private func section(label: String, rows: [SettingsRowData]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(OnboardingTheme.mono(10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .textCase(.uppercase)
                .padding(.leading, 6)
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    settingsRow(row)
                }
            }
        }
    }

    private func settingsRow(_ row: SettingsRowData) -> some View {
        HStack(spacing: 10) {
            Group {
                if let asset = row.icon.asset, let image = onboardingAppIcon(asset) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(row.icon.tile)
                        Image(systemName: row.icon.symbol)
                            .font(.system(size: row.icon.size, weight: .semibold))
                            .foregroundColor(row.icon.glyph)
                    }
                }
            }
            .frame(width: 22, height: 22)

            Text(row.name)
                .font(OnboardingTheme.sans(12.5, weight: row.highlight ? .semibold : .regular))
                .foregroundColor(OnboardingTheme.ink)
            Spacer()

            if row.status == .requesting {
                Circle()
                    .fill(OnboardingTheme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(0.85)
            }
            macOSToggle(on: row.status == .granted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.highlight ? OnboardingTheme.accent.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(row.highlight ? OnboardingTheme.accent.opacity(0.30) : Color.clear, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.25), value: row.status)
    }

    private func macOSToggle(on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color(red: 0.31, green: 0.78, blue: 0.51) : OnboardingTheme.surface3)
                .frame(width: 28, height: 16)
                .overlay(
                    Capsule().stroke(OnboardingTheme.borderStrong, lineWidth: 0.5)
                )
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .padding(.horizontal, 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: on)
    }
}

// MARK: - Sidekey unlock card

/// Sits under the fake System Settings panel and visualises Sidekey
/// transitioning from "locked" (permissions missing) to "ready"
/// (both Mic + Accessibility granted). Picks up the green from the
/// settings toggles so the cause-and-effect reads visually.
private struct SidekeyUnlockCard: View {
    let unlocked: Bool
    let readyLabel: String
    let waitingLabel: String

    private static let greenTint = Color(red: 0.31, green: 0.78, blue: 0.51)

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(unlocked ? Self.greenTint.opacity(0.18) : OnboardingTheme.surface2)
                Image(systemName: unlocked ? "checkmark.circle.fill" : "lock.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(unlocked ? Self.greenTint : OnboardingTheme.muted)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Whytap")
                    .font(OnboardingTheme.sans(13.5, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                Text(unlocked ? readyLabel : waitingLabel)
                    .font(OnboardingTheme.sans(12))
                    .foregroundColor(unlocked ? Self.greenTint : OnboardingTheme.muted)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(unlocked ? Self.greenTint.opacity(0.08) : OnboardingTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(unlocked ? Self.greenTint.opacity(0.40) : OnboardingTheme.border, lineWidth: 0.5)
        )
        .shadow(color: unlocked ? Self.greenTint.opacity(0.20) : .clear, radius: 16, y: 6)
        .animation(.easeInOut(duration: 0.45), value: unlocked)
    }
}
