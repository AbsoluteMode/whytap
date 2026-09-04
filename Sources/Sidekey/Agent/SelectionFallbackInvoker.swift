import Foundation

/// Thin injectable wrapper around `SelectionFallback.captureAsync` so
/// `AgentController` can be unit-tested without firing real CGEvents or
/// real `DispatchQueue.main.async` hops.
///
/// Production binding (`SelectionFallbackInvoker.live`) calls
/// `SelectionFallback.captureAsync` with the live `Env`. Tests construct
/// the invoker with a custom `invoke` closure that records the target
/// pid and runs the completion synchronously with a stubbed return
/// value.
struct SelectionFallbackInvoker {
    /// `invoke(targetPID:completion:)` should kick off the Cmd+C dance
    /// for `targetPID` and call `completion` with the captured selection
    /// (or nil if the dance was skipped / yielded no text). Production
    /// runs `completion` on the main queue.
    let invoke: (_ targetPID: pid_t, _ completion: @escaping (String?) -> Void) -> Void

    /// Production invoker. Dispatches the Cmd+C dance via
    /// `SelectionFallback.captureAsync`, which posts events on the main
    /// queue from a fresh `DispatchQueue.main.async` block (outside any
    /// NSEvent monitor closure).
    @MainActor
    static let live = SelectionFallbackInvoker(
        invoke: { targetPID, completion in
            SelectionFallback.captureAsync(
                targetPID: targetPID,
                completion: completion
            )
        }
    )
}
