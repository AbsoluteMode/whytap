import AVFoundation
import SwiftUI

/// The list a person sees after an update, and again from Settings: a serif
/// headline with the version, the first change with its clip, the others as
/// short rows, one button. Follows the system appearance like Settings.
// WHY: .project-docs/decisions/2026-11-24-whats-new-window.md
struct WhatsNewView: View {
    static let width: CGFloat = 440
    static let maxHeight: CGFloat = 740
    static let clipSize = CGSize(width: 368, height: 207)

    let releases: [WhatsNewRelease]
    /// The version the person had before, when known and several releases
    /// are listed ("Since 2.2.25").
    var since: String?
    /// The middle scrolls only when the whole list is taller than the window.
    var scrolls = false
    /// Offscreen pictures show the clip's still frame.
    var playsVideo = true
    var onLink: (SettingsWindowTab) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 14)
            if scrolls {
                ScrollView { list.padding(.horizontal, 24).padding(.bottom, 14) }
                Rectangle().fill(MacSettingsTheme.sep).frame(height: 0.5).accessibilityHidden(true)
            } else {
                list.padding(.horizontal, 24)
            }
            HStack {
                Spacer(minLength: 0)
                MacButton(title: "Got it", style: .primary, action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .frame(width: Self.width)
        .background(MacSettingsTheme.bgContent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(MacSettingsTheme.text3)
            (Text("Whytap ").font(OnboardingTheme.serif(34))
                + Text(releases.first?.version ?? "").font(OnboardingTheme.serifItalic(34)))
                .foregroundStyle(MacSettingsTheme.text)
                .kerning(-0.4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("What’s new in Whytap \(releases.first?.version ?? "")")
        .accessibilityAddTraits(.isHeader)
    }

    private var caption: String {
        if releases.count > 1, let since { return "WHAT’S NEW SINCE \(since)" }
        return "WHAT’S NEW"
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(releases.enumerated()), id: \.offset) { index, release in
                VStack(alignment: .leading, spacing: 8) {
                    if releases.count > 1 {
                        Text(release.version)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .padding(.leading, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    WhatsNewReleaseCard(release: release, showsClip: index == 0,
                                        playsVideo: playsVideo, onLink: onLink)
                }
            }
        }
    }
}

/// One release: a card of rows. The first row of the newest release carries
/// its clip when the build has one.
private struct WhatsNewReleaseCard: View {
    let release: WhatsNewRelease
    let showsClip: Bool
    let playsVideo: Bool
    let onLink: (SettingsWindowTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(release.items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle().fill(MacSettingsTheme.rowSeparator).frame(height: 0.5)
                        .padding(.leading, 52)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if index == 0, showsClip, let url = item.featureVideo?.url() {
                        WhatsNewClip(url: url, plays: playsVideo)
                            .frame(width: WhatsNewView.clipSize.width, height: WhatsNewView.clipSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                    WhatsNewRow(item: item, onLink: onLink)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
            .fill(MacSettingsTheme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
            .strokeBorder(MacSettingsTheme.sep, lineWidth: 0.5))
    }
}

private struct WhatsNewRow: View {
    let item: WhatsNewItem
    let onLink: (SettingsWindowTab) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol ?? "sparkle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacSettingsTheme.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MacSettingsTheme.accent.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Text(item.body)
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = item.link, let tab = link.tab {
                    WhatsNewLinkButton(title: link.title) { onLink(tab) }
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }
}

/// A quiet accent action inside a row ("Open Models ›").
private struct WhatsNewLinkButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MacSettingsTheme.accent)
            .opacity(hovered ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// The clip of the first change: its still frame at once, the silent loop
/// over it. Reduce Motion and offscreen pictures keep the still frame.
private struct WhatsNewClip: View {
    let url: URL
    let plays: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let poster {
                Image(decorative: poster, scale: 1).resizable().scaledToFit()
            }
            if plays, !reduceMotion {
                LoopingVideoView(url: url)
            }
        }
        .task(id: url) { poster = await Self.poster(for: url) }
    }

    /// A frame a quarter into the clip, where the feature has just started.
    static func poster(for url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_200, height: 1_200)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: seconds.isFinite ? seconds * 0.25 : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
