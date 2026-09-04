import Foundation

@MainActor
final class InsertExecutor {
    private let formatter: ClientInsertFormatter
    private let textInserter: TextInserter
    private let pasteTargetProvider: () -> FocusSnapshot?
    let snapshot: FocusSnapshot?

    init(
        formatter: ClientInsertFormatter,
        textInserter: TextInserter,
        snapshot: FocusSnapshot?,
        pasteTargetProvider: @escaping () -> FocusSnapshot? = FocusSnapshot.capture
    ) {
        self.formatter = formatter
        self.textInserter = textInserter
        self.snapshot = snapshot
        self.pasteTargetProvider = pasteTargetProvider
    }

    func availableVariants(for block: UIBlock) -> [InsertVariant] {
        formatter.variants(
            for: block,
            targetApp: formatter.detect(from: snapshot?.bundleID),
            isEditable: snapshot?.isEditable ?? false,
            hasSelection: snapshot?.hasSelection ?? false
        )
    }

    func execute(_ variant: InsertVariant, snapshot: FocusSnapshot) async throws -> Bool {
        switch variant.actionType {
        case .paste:
            let pasteTarget = pasteTargetProvider() ?? snapshot
            guard pasteTarget.restoreFocus() else {
                return false
            }
            textInserter.paste(variant.text)
            return true
        case .replace:
            guard
                snapshot.isEditable,
                snapshot.hasSelection,
                AppCompatibility.supportsReplaceSelection(bundleID: snapshot.bundleID)
            else {
                return false
            }

            guard snapshot.restoreFocus() else {
                return false
            }
            return textInserter.replaceSelection(with: variant.text)
        }
    }
}

private extension FocusSnapshot {
    var hasSelection: Bool {
        guard let selectionText else {
            return false
        }

        return !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
