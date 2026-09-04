import SwiftUI
#if DEBUG
import os.log

/// DEBUG-only logger for the music strip's transport-button actions. Shares
/// the `com.sidekey.nowplaying` / `hittest` channel with
/// `ClickThroughHostingView`'s strip hit-test trace so Andrey can read the
/// whole click chain (region accepted → button fired) in one `log show`.
/// Compiled out of release.
private let islandMusicTransportLog = OSLog(
    subsystem: "com.sidekey.nowplaying",
    category: "hittest"
)
#endif

/// Which transport control the cursor is over, for the hover highlight. The
/// strip's buttons are SwiftUI `Button`s in a non-activating panel where
/// `.onHover` delivery flickers; hover (like clicks) is resolved geometrically
/// in `IslandPanel` and published for the strip to render.
enum MusicTransportButton: Equatable {
    case previous
    case playPause
    case next
}

/// Visual + layout constants for the always-on player strip (Stage 3).
/// Kept in one place so the art tile / text column / transport cluster
/// stay in proportion to the strip's fixed height and the island width.
enum IslandMusicStrip {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 5
    /// Gap between the three structural columns (art | text | transport).
    static let columnSpacing: CGFloat = 10
    /// Art tile shrunk to fit the reduced strip height with breathing room.
    static let artworkSize: CGFloat = 30
    static let artworkCornerRadius: CGFloat = 6
    static let artworkPlaceholderGlyphSize: CGFloat = 14
    /// Title + artist now share ONE marquee line, so the font sizes drive a
    /// single row instead of a stacked title/subtitle pair.
    static let titleFontSize: CGFloat = 11
    static let artistFontSize: CGFloat = 10
    /// Spacing around the " · " separator between title and artist.
    static let titleArtistSeparator = "  ·  "
    /// Gap between the three transport buttons.
    static let transportSpacing: CGFloat = 4
    static let transportButtonSize: CGFloat = 24
    static let transportIconSize: CGFloat = 11
    static let transportPlayIconSize: CGFloat = 13
    static let cornerRadius: CGFloat = 14

    /// One-line combined label: title (emphasized) + a dim separator + artist
    /// (dimmer). Built as an `AttributedString` so `IslandMarqueeText` can
    /// render the mixed styling on a single scrolling line. Pure + testable.
    static func combinedTitleArtist(
        title: String,
        artist: String
    ) -> AttributedString {
        var titleRun = AttributedString(title)
        titleRun.font = .system(size: titleFontSize, weight: .semibold)
        titleRun.foregroundColor = .white.opacity(0.95)

        guard !artist.isEmpty else { return titleRun }

        var separatorRun = AttributedString(titleArtistSeparator)
        separatorRun.font = .system(size: artistFontSize, weight: .regular)
        separatorRun.foregroundColor = .white.opacity(0.4)

        var artistRun = AttributedString(artist)
        artistRun.font = .system(size: artistFontSize, weight: .regular)
        artistRun.foregroundColor = .white.opacity(0.6)

        return titleRun + separatorRun + artistRun
    }
}

/// The hover-gated Now Playing player strip: a player row that renders in
/// the gap BETWEEN the compact island and the hover panel — at the top of
/// the hover drawer — while a track is active (playing OR paused) AND the
/// island is hover-expanded. Shows album art + a one-line title · artist
/// marquee (scrolls on overflow) + three transport controls. The hover
/// panel (history / controls) still renders BELOW it.
///
/// The transport clicks are delivered GEOMETRICALLY by the window, not by
/// these SwiftUI `Button`s. In the non-key, non-activating `IslandPanel` the
/// AppKit→SwiftUI bridge drops the click before the `Button` action fires
/// on-device (the dedicated hit zone reports the point as "ours", yet the
/// `Button` never receives it). So `IslandPanel.sendEvent` intercepts the
/// `.leftMouseDown` against each button's hotspot rect and invokes the
/// matching action directly — the same mechanism the agent answer panel's ✕
/// close hotspot uses. The `Button`s remain as a harmless, accessible visual
/// affordance (and the keyboard/VoiceOver path), but they are NOT the
/// production click delivery path. The strip band is kept mouse-active by the
/// dedicated `IslandMusicStripHitZone` union so `sendEvent` actually receives
/// the click.
struct IslandMusicStripView: View {
    let snapshot: NowPlayingSnapshot
    let width: CGFloat
    /// Transport button the cursor is over (resolved geometrically by
    /// `IslandPanel`), or `nil`. Drives the hover highlight — replaces the
    /// per-button SwiftUI `.onHover`, which flickered in the non-activating panel.
    let hovered: MusicTransportButton?
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: IslandMusicStrip.columnSpacing) {
            artwork

            // Title + artist on ONE line (refinement 5). The combined
            // attributed label scrolls (marquee) when it overflows the
            // available width and stays static when it fits.
            IslandMarqueeText(
                attributed: IslandMusicStrip.combinedTitleArtist(
                    title: snapshot.title,
                    artist: snapshot.artist
                )
            )
            .frame(height: IslandMusicStrip.titleFontSize + 5)
            .frame(maxWidth: .infinity, alignment: .leading)

            transport
        }
        .padding(.horizontal, IslandMusicStrip.horizontalPadding)
        .padding(.vertical, IslandMusicStrip.verticalPadding)
        .frame(width: width, height: IslandDropModeControl.musicStripHeight)
        .background(IslandDetachedHoverPanelBackground())
        .clipShape(
            RoundedRectangle(
                cornerRadius: IslandMusicStrip.cornerRadius,
                style: .continuous
            )
        )
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(
            cornerRadius: IslandMusicStrip.artworkCornerRadius,
            style: .continuous
        )
        Group {
            if let image = snapshot.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            } else {
                shape
                    .fill(Color.white.opacity(0.12))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(
                                size: IslandMusicStrip.artworkPlaceholderGlyphSize,
                                weight: .semibold
                            ))
                            .foregroundStyle(.white.opacity(0.66))
                    )
            }
        }
        .frame(
            width: IslandMusicStrip.artworkSize,
            height: IslandMusicStrip.artworkSize
        )
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    // MARK: - Transport

    /// Transport cluster, trailing-aligned. For a finite track: prev / play ·
    /// pause / next. For radio or a live stream (`snapshot.isLive`): ONLY
    /// play/pause — there is nothing to seek or skip — and it stays in the
    /// trailing-most slot, aligned with the geometric live hit dispatch in
    /// `IslandPanel.sendEvent`.
    @ViewBuilder
    private var transport: some View {
        HStack(spacing: IslandMusicStrip.transportSpacing) {
            if !snapshot.isLive {
                transportButton(
                    systemImage: "backward.end.fill",
                    size: IslandMusicStrip.transportIconSize,
                    label: "Previous track",
                    button: .previous,
                    action: onPrevious
                )
            }
            transportButton(
                systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill",
                size: IslandMusicStrip.transportPlayIconSize,
                label: snapshot.isPlaying ? "Pause" : "Play",
                button: .playPause,
                action: onPlayPause
            )
            if !snapshot.isLive {
                transportButton(
                    systemImage: "forward.end.fill",
                    size: IslandMusicStrip.transportIconSize,
                    label: "Next track",
                    button: .next,
                    action: onNext
                )
            }
        }
    }

    private func transportButton(
        systemImage: String,
        size: CGFloat,
        label: String,
        button: MusicTransportButton,
        action: @escaping () -> Void
    ) -> some View {
        IslandMusicTransportButton(
            systemImage: systemImage,
            iconSize: size,
            label: label,
            isHovered: hovered == button,
            action: {
                #if DEBUG
                // Trace that the transport button's action actually fired.
                // Pairs with the `hittest` log in
                // `ClickThroughHostingView.acceptsEvent` (same subsystem) so
                // Andrey can see whether the click reached the SwiftUI Button
                // at all, or died in the AppKit→SwiftUI bridge. Compiled out
                // of release.
                os_log(
                    "transport button fired: %{public}@",
                    log: islandMusicTransportLog,
                    type: .debug,
                    label
                )
                #endif
                action()
            }
        )
    }
}

/// One transport icon button: a hover scale, a circular hit shape, and an
/// explicit accessibility label + button trait.
///
/// The `Button` action is NOT the production mouse-click delivery path — in
/// the non-key, non-activating panel the click never reaches it on-device.
/// `IslandPanel.sendEvent` delivers transport clicks geometrically (mirror of
/// the agent answer panel's ✕ close hotspot). The `Button` is kept for the
/// accessible / keyboard path and the hover affordance; it fires harmlessly
/// if SwiftUI ever does deliver a click.
private struct IslandMusicTransportButton: View {
    let systemImage: String
    let iconSize: CGFloat
    let label: String
    /// Driven by `IslandPanel`'s geometric hover resolution, not SwiftUI
    /// `.onHover` (which flickered in this non-activating panel).
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .frame(
                    width: IslandMusicStrip.transportButtonSize,
                    height: IslandMusicStrip.transportButtonSize
                )
                .background(
                    Circle().fill(Color.white.opacity(isHovered ? 0.16 : 0.08))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}
