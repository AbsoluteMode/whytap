import Foundation

/// Drains text to a sink at a fixed character rate so SSE deltas that arrive
/// in <100ms still play out as a typewriter for the user.
///
/// Driving model:
///  - `append(_:)` extends the target with a streaming delta (used by
///    `summary.delta`). The drain task keeps running, no jump.
///  - `replace(_:)` replaces the target wholesale (used by `tool.executing`
///    and `chat.title`, which arrive in one event). If the new target shares
///    a prefix with what's already on screen, the drain continues from the
///    current cursor; otherwise the visible string is reset to "" and the
///    new target re-types from scratch.
///  - `flush()` snaps to the full target — for cases where the stream is
///    closing and we want to leave the visible text complete.
///  - `clear()` wipes everything.
///
/// Rate is **~80 cps** (12 ms/char). Tests can override via the initializer.
///
/// All mutation happens on the main actor — the sink is a SwiftUI
/// `@Published` setter so we must stay on the main queue.
@MainActor
final class TypewriterStream {
    /// Time between revealed characters. Default = 12 ms ≈ 83 cps.
    /// Picked so longer Sonnet answers don't feel sluggish but still
    /// read as a typewriter rather than a flash. `nonisolated` so it can
    /// be referenced from the initializer's default argument (which runs
    /// outside the main actor).
    nonisolated static let defaultInterval: Duration = .milliseconds(12)

    private let interval: Duration
    private let sink: (String) -> Void
    private let sleep: (Duration) async -> Void

    private var targetChars: [Character] = []
    private var cursor: Int = 0
    private(set) var displayed: String = ""
    private var drainTask: Task<Void, Never>?

    init(
        interval: Duration = TypewriterStream.defaultInterval,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        sink: @escaping (String) -> Void
    ) {
        self.interval = interval
        self.sleep = sleep
        self.sink = sink
    }

    deinit {
        drainTask?.cancel()
    }

    /// Append a streaming delta. Keeps drain running.
    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        targetChars.append(contentsOf: delta)
        startDrainIfNeeded()
    }

    /// Ensure `targetChars` covers `text` entirely without resetting or
    /// jumping the visible cursor. If the current target is already a
    /// prefix of `text`, append the missing suffix and keep draining at
    /// the configured rate. If the target is already `text` (or longer),
    /// no-op. Used when `block.complete` arrives carrying the canonical
    /// final body — we want to guarantee the typewriter ends up rendering
    /// the whole thing even if upstream `summary.delta` events stopped
    /// short, *without* the visible "popping to full text" that
    /// `replace(_:)` causes when the delta target lags the final body.
    func extendTarget(toCover text: String) {
        let current = String(targetChars)
        guard text.count > current.count else { return }
        guard text.hasPrefix(current) else { return }
        let suffix = String(text.dropFirst(current.count))
        append(suffix)
    }

    /// Replace the target text. If `text` extends what's already displayed
    /// (same prefix), the typewriter continues from the cursor. Otherwise
    /// the visible string resets and the first character of `text` is
    /// emitted **synchronously** so any UI gated on a non-empty value
    /// (e.g. Pill 1 showing only when `currentToolLabel != nil`) becomes
    /// visible on the same RunLoop tick. Subsequent characters drain at
    /// the configured rate.
    func replace(_ text: String) {
        if text == displayed && cursor == targetChars.count {
            // No-op — already showing exactly this.
            return
        }
        if !displayed.isEmpty && text.hasPrefix(displayed) {
            targetChars = Array(text)
            // Cursor stays put — drain advances toward the longer target.
        } else {
            targetChars = Array(text)
            cursor = 0
            displayed = ""
            if let first = targetChars.first {
                displayed.append(first)
                cursor = 1
            }
            sink(displayed)
        }
        startDrainIfNeeded()
    }

    /// Cancel drain and emit the empty string.
    func clear() {
        drainTask?.cancel()
        drainTask = nil
        targetChars = []
        cursor = 0
        if !displayed.isEmpty {
            displayed = ""
            sink(displayed)
        }
    }

    /// Cancel drain and jump to the full target immediately.
    func flush() {
        drainTask?.cancel()
        drainTask = nil
        let full = String(targetChars)
        cursor = targetChars.count
        if displayed != full {
            displayed = full
            sink(displayed)
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let strong = self else { return }
                if strong.cursor >= strong.targetChars.count {
                    strong.drainTask = nil
                    return
                }
                await strong.sleep(strong.interval)
                if Task.isCancelled { return }
                guard strong.cursor < strong.targetChars.count else {
                    strong.drainTask = nil
                    return
                }
                strong.displayed.append(strong.targetChars[strong.cursor])
                strong.cursor += 1
                strong.sink(strong.displayed)
            }
        }
    }
}
