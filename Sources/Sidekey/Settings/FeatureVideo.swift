import AVKit
import SwiftUI

/// Short silent clips that show a feature at work, bundled in the app under
/// `Resources/FeatureVideos` (never fetched: Whytap contacts no Whytap
/// service). They are the accepted motion videos published on whytap.ai.
// WHY: .project-docs/decisions/2026-11-20-other-feature-videos.md
enum FeatureVideo: String, CaseIterable {
    case agent
    case meetings

    static let subdirectory = "FeatureVideos"
    /// Where the clips are looked up. Offscreen render tests point it at a
    /// folder holding `FeatureVideos/`; the app always uses its own bundle.
    nonisolated(unsafe) static var resourceBundle: Bundle = .main

    var featureTitle: String {
        switch self {
        case .agent: return "Agent"
        case .meetings: return "Meeting Notes"
        }
    }

    func url(in bundle: Bundle = FeatureVideo.resourceBundle) -> URL? {
        bundle.url(forResource: rawValue, withExtension: "mp4", subdirectory: Self.subdirectory)
    }
}

/// One live shortcut shown under a clip. The clips are recorded with the
/// default keys, so the popover names the keys the user has now.
struct FeatureVideoShortcut: Identifiable, Equatable {
    let label: String
    let contents: [KeycapContent]
    var id: String { label }
}

/// A small play button for a Settings row. Nothing plays until it is clicked;
/// a build without the bundled clip shows no button.
struct FeatureVideoButton: View {
    let video: FeatureVideo
    var shortcuts: @MainActor () -> [FeatureVideoShortcut] = { [] }
    var bundle: Bundle = FeatureVideo.resourceBundle
    @State private var presented = false

    var body: some View {
        if let url = video.url(in: bundle) {
            Button { presented.toggle() } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(presented ? MacSettingsTheme.text : MacSettingsTheme.text2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Watch how \(video.featureTitle) works")
            .accessibilityLabel("Watch how \(video.featureTitle) works")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                FeatureVideoPopover(url: url, shortcuts: shortcuts())
            }
        }
    }
}

struct FeatureVideoPopover: View {
    let url: URL
    let shortcuts: [FeatureVideoShortcut]

    static let videoSize = CGSize(width: 480, height: 270)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LoopingVideoView(url: url)
                .frame(width: Self.videoSize.width, height: Self.videoSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            if !shortcuts.isEmpty {
                HStack(spacing: 12) {
                    Text("Your shortcut:")
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                    ForEach(shortcuts) { shortcut in
                        HotkeyHintView(label: shortcut.label, contents: shortcut.contents,
                                       style: .keycaps, size: .compact)
                    }
                }
            }
        }
        .padding(12)
    }
}

/// Muted, looping playback without controls. Stops when the popover closes.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        coordinator.looper?.disableLooping()
        coordinator.looper = nil
        nsView.player = nil
    }
}
