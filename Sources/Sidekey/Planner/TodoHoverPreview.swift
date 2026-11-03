import AppKit
import SwiftUI
import WhytapCaseKit

/// Full text of a hovered To-do row, shown left of the drawer like the History
/// preview. Only rows whose title or status the row cuts off get one.
// WHY: .project-docs/decisions/2026-11-03-todo-tree.md
enum TodoHoverPreviewPolicy {
    static let bubbleWidth = HistoryHoverPreviewPolicy.bubbleWidth
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let statusFont = NSFont.systemFont(ofSize: 10.5)

    /// Lines `text` needs at `width`; the row shows at most two of each.
    static func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int {
        guard width > 0 else { return Int.max }
        let height = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return Int((height / line).rounded(.up))
    }

    static func needsPreview(title: String, status: String?, textWidth: CGFloat) -> Bool {
        lineCount(title, font: titleFont, width: textWidth) > 2
            || status.map { lineCount($0, font: statusFont, width: textWidth - 12) > 2 } ?? false
    }
}

struct TodoHoverPreviewAnchor: Equatable {
    let taskID: UUID
    /// Hovered row frame in the island hover-zone coordinate space.
    let rowFrame: CGRect
}

/// Only the anchor, so typing in To-do does not re-render the whole island.
@MainActor
final class TodoHoverPreviewState: ObservableObject {
    static let shared = TodoHoverPreviewState()
    @Published var anchor: TodoHoverPreviewAnchor?

    func set(_ taskID: UUID, _ frame: CGRect?) {
        if let frame { anchor = TodoHoverPreviewAnchor(taskID: taskID, rowFrame: frame) }
        else if anchor?.taskID == taskID { anchor = nil }
    }
}

/// Non-interactive bubble: title, status, parent and subtask count.
struct TodoHoverPreviewBubble: View {
    let task: PlannerTask
    let parentTitle: String?
    let subtasks: Int

    var body: some View {
        if IslandHoverGlass.usesNativeLiquidGlass {
            content.padding(HistoryHoverPreviewPolicy.contentPadding).islandHoverGlassSurface(cornerRadius: 11)
        } else {
            content.padding(HistoryHoverPreviewPolicy.contentPadding)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.46))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let parentTitle {
                Text("in \(parentTitle)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Text(task.title)
                .font(.system(size: 12, weight: .medium)).strikethrough(task.completed)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            if let status = task.status {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .semibold))
                    Text(status).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            if subtasks > 0 {
                Text(subtasks == 1 ? "1 subtask" : "\(subtasks) subtasks")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: TodoHoverPreviewPolicy.bubbleWidth - HistoryHoverPreviewPolicy.contentPadding * 2, alignment: .topLeading)
    }
}
