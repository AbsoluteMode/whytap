import AppKit

/// The coordinator's asynchronous commit boundary, isolated from capture/windows
/// so cancellation, stale sessions and pasteboard failures use deterministic tests.
@MainActor
enum ScreenshotTextCopy {
    enum Outcome: Equatable { case copied, empty, failed, discarded }

    static func perform(source: CGImage, size: CGSize, annotations: [ScreenshotAnnotation], crop: CGRect,
                        pasteboard: NSPasteboard = .general,
                        recognize: @escaping @Sendable (CGImage) async throws -> String = { image in
                            await ScreenshotTextDetector.warmUp().value
                            return try await ScreenshotTextDetector.text(image)
                        },
                        write: ((String, NSPasteboard) -> Bool)? = nil,
                        isCurrent: () -> Bool) async -> Outcome {
        guard !Task.isCancelled, isCurrent() else { return .discarded }
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                // Recognize only the flattened crop, including Blur, never hidden source pixels.
                // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
                let image = try ScreenshotRenderer.image(source: source, size: size, annotations: annotations, crop: crop)
                try Task.checkCancellation()
                return try await recognize(image)
            }
            let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, isCurrent() else { return .discarded }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
            return commit(text, to: pasteboard, write: write) ? .copied : .failed
        } catch {
            return Task.isCancelled || !isCurrent() ? .discarded : .failed
        }
    }

    /// Preserve every readable type/item on failure. Never restore over a newer
    /// owner, or clear a clipboard whose advertised data could not be snapshotted.
    // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    private static func commit(_ text: String, to board: NSPasteboard,
                               write: ((String, NSPasteboard) -> Bool)?) -> Bool {
        let originalCount = board.changeCount
        let items = board.pasteboardItems ?? []
        let snapshot = Pasteboard.snapshot(of: board)
        guard snapshot.items.count == items.count,
              (board.types ?? []).isEmpty || !items.isEmpty,
              zip(items, snapshot.items).allSatisfy({ item, data in
                  Set(item.types.map(\.rawValue)) == Set(data.keys)
              }), board.changeCount == originalCount, !Task.isCancelled else { return false }
        let ownedCount = board.clearContents()
        let written = write?(text, board) ?? board.setString(text, forType: .string)
        guard !written else { return true }
        if board.changeCount == ownedCount { Pasteboard.restore(snapshot, into: board) }
        return false
    }
}
