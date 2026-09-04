import AVFoundation
import Foundation
import SwiftUI

/// Scripted timeline for the agent welcome screen. Loops through
/// three sample prompts; for each one:
///
/// 1. Right ⌘ flashes ON (press) and stays highlighted while the user
///    is holding the key.
/// 2. Bundled voice clip plays via `AVAudioPlayer` metering — the
///    orb reacts to live levels (`.agentVoice`), and `typedQuery`
///    streams the transcript under the orb in sync with the audio
///    so the user sees what was just said.
/// 3. Audio ends → orb morphs to `.agentProcessing`, the chat-name
///    streams into the titlebar, and the action surface fades up
///    (Calendar / Notion / Meetings History).
/// 4. Agent's mock response streams into the chat window.
@MainActor
final class OnboardingAgentController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case pressFlash
        case recording
        case processing
        case responding
        case done
    }

    struct Sample: Equatable {
        let audioName: String
        let query: String
        let chatName: String
        let actionText: String
        let actionIcon: String
        let response: String
        let link: LinkPreview
        /// When non-nil, the demo renders an ORDERED list of action
        /// steps (revealed one-by-one) instead of the single
        /// `actionText`/`actionIcon` card + bottom link chip — used for
        /// the multi-step "did it" demo (close a task, message the PM).
        /// The streamed `response` then reads as the confirmation line.
        var actionSteps: [ActionStep]? = nil
    }

    /// One completed action in a multi-step agent run (e.g. "Closed
    /// ROO-234" with a Linear link, then "Messaged Anna" with a Slack
    /// message preview).
    struct ActionStep: Equatable {
        let icon: String          // SF Symbol for the leading check tile
        let title: String         // "Closed ROO-234 · Auth logout bug"
        var detail: String? = nil // trailing label, e.g. "Linear"
        var detailIcon: String? = nil // SF Symbol next to `detail`, e.g. Slack
        var linkLabel: String? = nil  // inline link chip, e.g. "View"
        var message: String? = nil    // message-preview bubble (Slack/email)
    }

    struct LinkPreview: Equatable {
        let title: String
        let subtitle: String
        let icon: String  // SF Symbol name
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levels: [Float] = [0]
    @Published private(set) var currentSample: Sample?
    @Published private(set) var typedQuery: String = ""
    @Published private(set) var typedChatName: String = ""
    @Published private(set) var typedResponse: String = ""
    @Published private(set) var actionVisible: Bool = false
    /// Surfaces the link chip + hotkey hint UNDER the response text
    /// once streaming finishes. Mirrors the real Sidekey response
    /// panel where useful_links land after the agent's prose answer.
    @Published private(set) var linkVisible: Bool = false
    /// How many `actionSteps` are revealed so far (multi-step demo).
    @Published private(set) var visibleStepCount: Int = 0
    @Published var isMuted: Bool = false {
        didSet { audioPlayer?.volume = isMuted ? 0 : 1 }
    }

    let samples: [Sample]
    private let audioURLProvider: (String) -> URL?

    private var task: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?

    private static let meterFloorDB: Float = -50
    private static let meterCeilingDB: Float = 0

    init(samples: [Sample], audioURLProvider: @escaping (String) -> URL?) {
        self.samples = samples
        self.audioURLProvider = audioURLProvider
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil, !samples.isEmpty else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var index = 0
            while !Task.isCancelled {
                await self.runSampleCycle(samples[index])
                index = (index + 1) % samples.count
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        audioPlayer?.stop()
        audioPlayer = nil
        phase = .idle
        levels = [0]
        currentSample = nil
        typedQuery = ""
        typedChatName = ""
        typedResponse = ""
        actionVisible = false
        linkVisible = false
        visibleStepCount = 0
    }

    func toggleMute() { isMuted.toggle() }

    // MARK: - Cycle

    private func runSampleCycle(_ sample: Sample) async {
        currentSample = sample
        typedQuery = ""
        typedChatName = ""
        typedResponse = ""
        actionVisible = false
        linkVisible = false
        visibleStepCount = 0

        phase = .idle
        levels = [0]
        await sleep(0.8)
        guard !Task.isCancelled else { return }

        phase = .pressFlash
        await sleep(0.32)
        guard !Task.isCancelled else { return }

        phase = .recording
        await runRecording(for: sample)
        guard !Task.isCancelled else { return }

        phase = .processing
        await runProcessing(for: sample)
        guard !Task.isCancelled else { return }

        phase = .responding
        await streamResponse(for: sample)
        guard !Task.isCancelled else { return }

        phase = .done
        // Hold long enough that the user can read the full result.
        await sleep(4.8)
    }

    private func runRecording(for sample: Sample) async {
        if let url = audioURLProvider(sample.audioName) {
            await playAudioWithLiveTranscript(url: url, query: sample.query)
        } else {
            await runSyntheticEnvelope(duration: 2.0, query: sample.query)
        }
    }

    /// Streams the query character-by-character driven by the audio
    /// player's playback progress. The first character lands just
    /// after the first audible frame; the last character lands as the
    /// audio finishes.
    private func playAudioWithLiveTranscript(url: URL, query: String) async {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.isMeteringEnabled = true
            player.volume = isMuted ? 0 : 1
            player.prepareToPlay()
            audioPlayer = player
            player.play()

            let chars = Array(query)
            while !Task.isCancelled, player.isPlaying {
                player.updateMeters()
                let power = player.averagePower(forChannel: 0)
                levels = [Self.linearLevel(fromDB: power)]

                let progress = player.duration > 0
                    ? min(1.0, max(0.0, player.currentTime / player.duration))
                    : 0
                let revealed = max(1, Int(Double(chars.count) * progress))
                let endIndex = min(chars.count, revealed)
                let next = String(chars[0..<endIndex])
                if next != typedQuery {
                    typedQuery = next
                }

                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            typedQuery = query
            levels = [0]
            player.stop()
            audioPlayer = nil
        } catch {
            NSLog("OnboardingAgentController: audio playback failed — %@",
                  String(describing: error))
            await runSyntheticEnvelope(duration: 2.0, query: query)
        }
    }

    private func runSyntheticEnvelope(duration: TimeInterval, query: String) async {
        let start = Date()
        let chars = Array(query)
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= duration { break }
            let breath = (sin(elapsed * 1.8) + 1) * 0.5
            let burst = sin(elapsed * 7.5 + 1.2) * 0.18
            let jitter = Double.random(in: -0.04...0.04)
            let raw = breath * 0.7 + burst + jitter + 0.18
            let level = max(0.18, min(0.95, raw))
            levels = [Float(level)]

            let progress = min(1.0, elapsed / duration)
            let revealed = max(1, Int(Double(chars.count) * progress))
            typedQuery = String(chars[0..<min(chars.count, revealed)])

            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        typedQuery = query
        levels = [0]
    }

    /// Processing: action card appears, then chat name streams into
    /// the titlebar. Hangs briefly after so the user reads them
    /// before the response starts streaming.
    private func runProcessing(for sample: Sample) async {
        await sleep(0.35)
        guard !Task.isCancelled else { return }

        actionVisible = true
        if let steps = sample.actionSteps {
            // Reveal each completed action in turn — paced slowly so the
            // user can read each step as the agent "acts".
            for index in steps.indices {
                guard !Task.isCancelled else { return }
                visibleStepCount = index + 1
                await sleep(1.1)
            }
            await sleep(0.4)
        } else {
            await sleep(0.65)
        }
        guard !Task.isCancelled else { return }

        let chars = Array(sample.chatName)
        for i in chars.indices {
            guard !Task.isCancelled else { return }
            typedChatName = String(chars[0...i])
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
        await sleep(0.5)
    }

    private func streamResponse(for sample: Sample) async {
        let chars = Array(sample.response)
        for i in chars.indices {
            guard !Task.isCancelled else { return }
            typedResponse = String(chars[0...i])
            try? await Task.sleep(nanoseconds: 32_000_000)
        }
        // Let the response settle for a beat, then surface the
        // useful-link card + hotkey hint underneath. Multi-step demos
        // surface their link inline in a step, so the bottom link chip
        // stays hidden there.
        await sleep(0.4)
        guard !Task.isCancelled else { return }
        if sample.actionSteps == nil {
            linkVisible = true
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func linearLevel(fromDB db: Float) -> Float {
        let clamped = max(meterFloorDB, min(meterCeilingDB, db))
        let span = meterCeilingDB - meterFloorDB
        return (clamped - meterFloorDB) / span
    }
}

extension OnboardingAgentController.Sample {
    /// The three canonical demo samples — voice + intent + integration
    /// surface + mock response. Audio filenames must match the files
    /// copied into `Sources/OnboardingPreview/Audio/` (production
    /// bundle will get the same names once the assets are approved).
    static let demoSet: [OnboardingAgentController.Sample] = [
        .init(
            audioName: "when-meeting",
            query: "When’s my next meeting?",
            chatName: "Next Meeting",
            actionText: "Checking Google Calendar",
            actionIcon: "calendar",
            response: "Your next meeting is Standup with the design team at 2:00 PM today.",
            link: .init(
                title: "Standup — Design team",
                subtitle: "Today · 2:00 – 2:30 PM · Google Calendar",
                icon: "calendar"
            )
        ),
        .init(
            audioName: "auth-docs",
            query: "Where’s the auth service documentation?",
            chatName: "Auth Docs",
            actionText: "Searching Notion",
            actionIcon: "doc.text.magnifyingglass",
            response: "Last edited 3 days ago by Anna.",
            link: .init(
                title: "Auth Service — Architecture",
                subtitle: "Notion · Engineering / Services / Auth",
                icon: "doc.text"
            )
        ),
        .init(
            audioName: "ai-integrations",
            query: "What did we decide in the last meeting about AI integrations?",
            chatName: "AI Integrations",
            actionText: "Reading Meetings History",
            actionIcon: "rectangle.stack",
            response: "You decided to ship GPT-5 routing first, then revisit Gemini Flash if p95 latency holds.",
            link: .init(
                title: "Engineering Sync — May 19",
                subtitle: "Meeting note · 38 min",
                icon: "rectangle.stack"
            )
        ),
        .init(
            audioName: "messi",
            query: "Who is the greatest footballer?",
            chatName: "Greatest Footballer",
            actionText: "Searching the web",
            actionIcon: "globe",
            response: "Messi.",
            link: .init(
                title: "Lionel Messi",
                subtitle: "Wikipedia · The free encyclopedia",
                icon: "globe"
            )
        )
    ]

    /// Single looping demo for the merged Agent screen: one spoken
    /// request triggers a multi-step run — close a task (with a link)
    /// and message the PM in Slack — then a confirmation line. Shows the
    /// agent *acting*, not just answering.
    static let agentActionDemo: [OnboardingAgentController.Sample] = [
        .init(
            // `agent-close-task.m4a` — speaks the query verbatim so the voice
            // matches the on-screen text. Generated via macOS `say` (Samantha)
            // as a stand-in; swap for a human recording later if desired.
            audioName: "agent-close-task",
            query: "Close the auth bug task and tell the PM in Slack I shipped it.",
            chatName: "Auth logout bug",
            actionText: "",
            actionIcon: "checkmark",
            response: "Done — closed the task and let Anna know in Slack.",
            link: .init(title: "", subtitle: "", icon: "checkmark"),
            actionSteps: [
                .init(
                    icon: "checkmark",
                    title: "Closed ROO-234 · Auth logout bug",
                    detail: "Linear",
                    linkLabel: "View"
                ),
                .init(
                    icon: "checkmark",
                    title: "Messaged Anna (PM)",
                    detail: "#engineering",
                    detailIcon: "bubble.left.and.bubble.right.fill",
                    message: "Shipped the auth logout fix — it’s live now ✅ Closed the ticket too."
                )
            ]
        )
    ]
}
