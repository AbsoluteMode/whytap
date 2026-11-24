import AppKit
import SwiftUI
import Vision
@testable import Sidekey

/// Frames of the step drops' motion, drawn from the real drop view and the
/// real model's timeline without a window: the review material for the
/// feature. It draws the path without native glass (macOS 26 glass does not
/// render off screen); positions and progress are eased here the way the
/// row's spring moves them.
/// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
@MainActor
enum AgentStepDropsStoryboard {
    struct DropState {
        let step: AgentAppStep
        /// 0 at its parent, 1 in place.
        let progress: CGFloat
        /// Leading edge in the row.
        let x: CGFloat
    }

    struct Frame {
        let time: TimeInterval
        let drops: [DropState]
    }

    static let framesPerSecond = 30.0
    /// How long one drop's arrival, exit or slide takes on screen.
    static let motion: TimeInterval = 0.42

    private static func ease(_ value: Double) -> CGFloat {
        let t = min(1, max(0, value))
        // Slight overshoot, like the row's spring.
        let c = 0.35
        return CGFloat(1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2))
    }

    private static func width(of step: AgentAppStep) -> CGFloat {
        NSHostingView(rootView: AgentStepDrop(step: step)).fittingSize.width
    }

    /// Replays the model with a hand-moved clock and samples it.
    static func frames(steps: [AgentAppStep]) -> [Frame] {
        var queue: [(at: TimeInterval, order: Int, work: @MainActor () -> Void)] = []
        var order = 0, clock: TimeInterval = 0
        let model = AgentStepDropsModel(schedule: { seconds, work in
            order += 1
            let id = order
            queue.append((clock + seconds, id, work))
            return { queue.removeAll { $0.order == id } }
        })
        // (time, ids on screen) every time the row changes.
        var states: [(time: TimeInterval, ids: [Int])] = []
        let watch = model.$visible.dropFirst().sink { states.append((clock, $0.map(\.id))) }
        model.show(steps)
        while let next = queue.min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            queue.removeAll { $0.order == next.order }
            clock = next.at
            next.work()
        }
        watch.cancel()
        let end = clock
        let widths = steps.map(width(of:))
        let gap = AgentStepDropsView.Metrics.gap

        func position(of id: Int, in ids: [Int]) -> CGFloat? {
            guard let index = ids.firstIndex(of: id) else { return nil }
            return ids[..<index].reduce(0) { $0 + widths[$1] + gap }
        }

        var frames: [Frame] = []
        var time: TimeInterval = 0
        while time <= end + 0.001 {
            var drops: [DropState] = []
            for id in steps.indices {
                let present = states.filter { $0.ids.contains(id) }
                guard let appeared = present.first?.time else { continue }
                let removed = states.first { $0.time > appeared && !$0.ids.contains(id) }?.time
                guard time >= appeared, removed.map({ time < $0 + motion }) ?? true else { continue }
                var progress = ease((time - appeared) / motion)
                if let removed, time >= removed { progress = min(progress, 1 - ease((time - removed) / motion)) }
                // Slide between the places the row gave it.
                var x: CGFloat = 0
                var last: CGFloat?
                for state in states where state.time <= time {
                    guard let target = position(of: id, in: state.ids) else { continue }
                    if let from = last, from != target {
                        x = from + (target - from) * ease((time - state.time) / motion)
                        last = (time - state.time) >= motion ? target : from
                        if (time - state.time) < motion { break }
                    } else {
                        x = target
                        last = target
                    }
                }
                drops.append(DropState(step: steps[id], progress: max(0, progress), x: x))
            }
            frames.append(Frame(time: time, drops: drops))
            time += 1 / framesPerSecond
        }
        return frames
    }

    // MARK: Drawing

    private struct Scene: View {
        let frame: Frame
        let dark: Bool

        static let size = CGSize(width: 860, height: 64)
        static let islandWidth: CGFloat = 190
        static let barHeight: CGFloat = 32

        var body: some View {
            ZStack(alignment: .topLeading) {
                // Wallpaper and menu bar.
                LinearGradient(colors: dark ? [Color(red: 0.13, green: 0.16, blue: 0.24), Color(red: 0.22, green: 0.18, blue: 0.3)]
                               : [Color(red: 0.62, green: 0.76, blue: 0.9), Color(red: 0.86, green: 0.8, blue: 0.9)],
                               startPoint: .leading, endPoint: .trailing)
                Rectangle().fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
                    .frame(height: Self.barHeight)
                // A drop comes out from behind the one before it.
                ForEach(Array(frame.drops.enumerated().reversed()), id: \.offset) { _, drop in
                    AgentStepDrop(step: drop.step)
                        .modifier(AgentStepBud(progress: drop.progress))
                        .offset(x: Self.islandWidth + AgentStepDropsView.Metrics.islandGap + drop.x,
                                y: (Self.barHeight - AgentStepDropsView.Metrics.rowHeight) / 2)
                }
                // The island is above the drops: one arriving comes out from under it.
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                    .fill(Color.black)
                    .frame(width: Self.islandWidth, height: Self.barHeight)
                Text(String(format: "%.2f s", frame.time))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45))
                    .offset(x: 8, y: Self.size.height - 18)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    static func render(_ frame: Frame, dark: Bool, scale: CGFloat = 2) -> CGImage? {
        let legacy = IslandHoverGlass.drawsLegacyPathForReview
        IslandHoverGlass.drawsLegacyPathForReview = true
        defer { IslandHoverGlass.drawsLegacyPathForReview = legacy }
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: Scene(frame: frame, dark: dark))
            renderer.scale = scale
            image = renderer.cgImage
        }
        return image
    }

    static func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US", "ru-RU"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: Review files

    private static func png(_ image: CGImage, to url: URL) throws {
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try data?.write(to: url)
    }

    /// Frame sequences, light and dark: a word, a model change, a hotkey,
    /// hover tools, three steps and five steps.
    static func write(to directory: URL) throws {
        let scenes: [(String, [AgentAppStep])] = [
            ("one", [AgentAppStep(operation: "vocab_add", line: "Vocab + whytap")]),
            ("model", [AgentAppStep(operation: "set_model", line: "Agent: claude-sonnet-5-5 → claude-opus-5-5")]),
            ("hotkey", [AgentAppStep(operation: "hotkey_set", line: "Hotkey: Shot — ⌥S")]),
            ("hover", [AgentAppStep(operation: "toolbox_set", line: "Toolbox + Shot"),
                       AgentAppStep(operation: "toolbox_set", line: "Toolbox − Monitor")]),
            ("three", [AgentAppStep(operation: "vocab_add", line: "Vocab + whytap"),
                       AgentAppStep(operation: "filler_add", line: "Filler + короче"),
                       AgentAppStep(operation: "set_setting", line: "Drop mode → Smart")]),
            ("five", [AgentAppStep(operation: "vocab_add", line: "Vocab + whytap"),
                      AgentAppStep(operation: "filler_add", line: "Filler + короче"),
                      AgentAppStep(operation: "set_setting", line: "Drop mode → Smart"),
                      AgentAppStep(operation: "toolbox_set", line: "Toolbox + Shot · ⌥S"),
                      AgentAppStep(operation: "todo_add", line: "To-do + Send the report")])
        ]
        for (name, steps) in scenes {
            for dark in [false, true] {
                let folder = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light")", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, frame) in frames(steps: steps).enumerated() {
                    guard let image = render(frame, dark: dark) else { continue }
                    try png(image, to: folder.appendingPathComponent(String(format: "f%04d.png", index)))
                }
            }
        }
    }
}
