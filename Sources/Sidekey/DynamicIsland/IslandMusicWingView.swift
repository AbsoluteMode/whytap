import SwiftUI

/// Visual + layout constants for the right-band music wing (Stage 2). Kept
/// in one place so the thumbnail / waveform / progress proportions stay in
/// sync with the 70 pt right band and mirror the meeting recording slot's
/// sizing discipline.
enum IslandMusicWing {
    static let thumbnailSize: CGFloat = 17
    static let thumbnailCornerRadius: CGFloat = 4
    /// Gap between the thumbnail and the equalizer column.
    static let horizontalSpacing: CGFloat = 5
    /// Compact equalizer envelope. Narrow so the bars read as a tight chip and
    /// never run toward the screen edge. `IslandMusicEqualizerView` sizes its
    /// bars to this width and hard-clips, so nothing paints outside the wing.
    static let waveformWidth: CGFloat = 30
    /// Total content width: thumbnail + spacing + waveform. The progress bar
    /// spans this same width below the row, so both read compact (down from
    /// the old 64 pt full-band envelope).
    static var contentWidth: CGFloat {
        thumbnailSize + horizontalSpacing + waveformWidth
    }
    /// Height of the thumbnail + waveform row (the progress bar sits below).
    static let topHeight: CGFloat = 17
    static let rowToProgressSpacing: CGFloat = 3
    static let progressHeight: CGFloat = 2.5
    static let verticalOffset: CGFloat = -1
    static let placeholderGlyphSize: CGFloat = 9

    static var totalHeight: CGFloat {
        topHeight + rowToProgressSpacing + progressHeight
    }
}

/// The right-band music wing: a small album thumbnail, a synthetic equalizer,
/// and a thin linear progress bar. Rendered while a track is active (playing OR
/// paused) and no higher-priority right-band slot owns the band, replacing the
/// AFK passive hints.
///
/// The equalizer (`IslandMusicEqualizerView`) is decorative — there is no audio
/// capture (see that view for the full rationale). It animates while the track
/// plays and settles to a calm resting row when paused, gated purely on
/// `snapshot.isPlaying`. The progress bar reflects the published snapshot
/// fraction; a live/radio stream (`isLive`) hides it.
struct IslandMusicWingView: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        VStack(spacing: IslandMusicWing.rowToProgressSpacing) {
            HStack(spacing: IslandMusicWing.horizontalSpacing) {
                thumbnail

                IslandMusicEqualizerView(isPlaying: snapshot.isPlaying)
                    // Fixed compact envelope + hard clip so the equalizer
                    // always paints inside the narrowed band, never toward the
                    // screen edge.
                    .frame(
                        width: IslandMusicWing.waveformWidth,
                        height: IslandMusicWing.topHeight
                    )
                    .clipped()
            }
            .frame(
                width: IslandMusicWing.contentWidth,
                height: IslandMusicWing.topHeight
            )

            // Radio / live stream has no finite length to seek, so the
            // progress capsule is omitted. The freed space stays empty and
            // transparent — the wing's outer frame height
            // (`IslandMusicWing.totalHeight`, pinned below) and the
            // thumbnail+waveform row above stay put, so the right band never
            // jumps between live and finite items.
            if snapshot.isLive {
                Color.clear
                    .frame(
                        width: IslandMusicWing.contentWidth,
                        height: IslandMusicWing.progressHeight
                    )
            } else {
                progressBar
                    .frame(
                        width: IslandMusicWing.contentWidth,
                        height: IslandMusicWing.progressHeight
                    )
            }
        }
        // Leading-align the narrowed content inside the full right band so
        // the thumbnail sits toward the notch / island center instead of
        // hugging the screen edge (refinement 2). The band is laid out by
        // `IslandWrapRow` at `rightSideWidth`; leading there == toward the
        // notch.
        .frame(
            width: IslandMusicWing.contentWidth,
            height: IslandMusicWing.totalHeight,
            alignment: .leading
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: IslandMusicWing.verticalOffset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(
            cornerRadius: IslandMusicWing.thumbnailCornerRadius,
            style: .continuous
        )
        Group {
            if let artwork = snapshot.artwork {
                Image(nsImage: artwork)
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
                                size: IslandMusicWing.placeholderGlyphSize,
                                weight: .semibold
                            ))
                            .foregroundStyle(.white.opacity(0.66))
                    )
            }
        }
        .frame(
            width: IslandMusicWing.thumbnailSize,
            height: IslandMusicWing.thumbnailSize
        )
        .clipShape(shape)
        .overlay(
            shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
    }

    private var progressBar: some View {
        // The published snapshot changes only on a player event (MediaRemote is
        // push-based), so a static read freezes the fill between events — the bar
        // would only "catch up" on a transport command. Tick a clock and
        // extrapolate the fraction to the current date so a playing track's bar
        // advances in real time; a paused track reports a frozen fraction, so the
        // bar simply holds. `.periodic` (not `.animation`) keeps this informative
        // bar advancing even under Reduce Motion, and 0.5 s is plenty for a fill
        // that moves sub-pixel per second.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))

                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(
                            width: geometry.size.width
                                * CGFloat(snapshot.progressFraction(at: context.date))
                        )
                }
            }
        }
    }

    private var accessibilityDescription: String {
        let state = snapshot.isPlaying ? "Playing" : "Paused"
        return "\(state), \(snapshot.title) by \(snapshot.artist)"
    }
}
