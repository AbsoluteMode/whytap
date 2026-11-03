import SwiftUI
import WhytapCaseKit

// WHY: .project-docs/decisions/2026-10-20-todo-hover.md
// WHY: .project-docs/decisions/2026-11-03-todo-tree.md
/// Retains only the draft across openings. Completed rows survive the current
/// opening so an accidental click can be undone; History is their durable home.
@MainActor
final class TodoHoverModel: ObservableObject {
    static let shared = TodoHoverModel(store: .shared, activityChanged: { AppState.shared.todoActive = $0 })
    let store: PlannerStore
    @Published var draft = "" {
        didSet {
            guard draft != oldValue else { return }
            validationMessage = nil
            publishActivity()
        }
    }
    @Published var showingHistory = false
    @Published private(set) var completedThisOpening: Set<UUID> = []
    @Published private(set) var validationMessage: String?
    @Published private(set) var lastAddedID: UUID?
    /// Collapsed folders, kept for the app session.
    @Published private(set) var collapsed: Set<UUID> = []
    /// One inline editor at a time: a new subtask, a status or a title.
    @Published var editor: TodoInlineEditor? {
        didSet { if editor?.text != oldValue?.text { validationMessage = nil }; publishActivity() }
    }
    private(set) var visible = false
    private let activityChanged: (Bool) -> Void

    init(store: PlannerStore, activityChanged: @escaping (Bool) -> Void = { _ in }) {
        self.store = store
        self.activityChanged = activityChanged
    }

    func begin() {
        guard !visible else { return }
        // Shows tasks agents added through the file while the panel was closed.
        store.refreshFromDisk()
        completedThisOpening = []
        showingHistory = false
        validationMessage = nil
        lastAddedID = nil
        editor = nil
        TodoHoverPreviewState.shared.anchor = nil
        visible = true
        publishActivity()
    }

    func end() { visible = false; TodoHoverPreviewState.shared.anchor = nil; publishActivity() }

    var tasks: [PlannerTask] { rows.map(\.task) }

    /// Active view: the tree in folder order, open tasks before ones closed in
    /// this opening, collapsed folders hiding their subtasks. History: closed
    /// tasks, newest first, each with its parent's title.
    var rows: [TodoHoverRowModel] {
        let tasks = store.archive.tasks
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if showingHistory {
            return tasks.filter(\.completed).sorted {
                // Legacy completed tasks have no known completion time.
                ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
            }.map { TodoHoverRowModel(task: $0, depth: 0, childCount: 0, parentTitle: $0.parentID.flatMap { byID[$0]?.title }) }
        }
        let shown: (TodoNode) -> Bool = { !$0.completed || self.completedThisOpening.contains($0.id) }
        let nodes = tasks.map(\.node)
        return TodoTree.ordered(nodes, include: shown, descend: { !self.collapsed.contains($0.id) },
                                before: { $0.completed != $1.completed ? !$0.completed : nil }).compactMap { entry in
            byID[entry.node.id].map {
                TodoHoverRowModel(task: $0, depth: entry.depth,
                                  childCount: nodes.filter { $0.parentID == entry.node.id && shown($0) }.count, parentTitle: nil)
            }
        }
    }

    enum SubtaskEligibility { case allowed, tooDeep, completed }
    static let actionSlotWidth: CGFloat = 18

    /// One rule for the hover "+" and the context menu: open tasks above the
    /// deepest level. The deepest level shows the button disabled.
    static func subtaskEligibility(for row: TodoHoverRowModel) -> SubtaskEligibility {
        if row.task.completed { return .completed }
        return row.depth + 1 < TodoTree.maxDepth ? .allowed : .tooDeep
    }

    func toggleCollapsed(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    func beginEditing(_ kind: TodoInlineEditor.Kind) {
        guard let task = store.archive.tasks.first(where: { $0.id == kind.taskID }) else { return }
        switch kind {
        case .subtask:
            guard !task.completed, TodoTree.depth(of: task.id, in: store.archive.tasks.map(\.node)) < TodoTree.maxDepth else { return }
            editor = TodoInlineEditor(kind: kind, text: ""); collapsed.remove(task.id)
        case .status: editor = TodoInlineEditor(kind: kind, text: task.status ?? "")
        case .title: editor = TodoInlineEditor(kind: kind, text: task.title)
        }
    }

    /// Return in an inline field. Keeps the editor and explains a rejected value.
    @discardableResult
    func commitEditor(now: Date = Date()) -> Bool {
        guard let editor else { return false }
        do {
            switch editor.kind {
            case .subtask(let parent):
                let title = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { self.editor = nil; return true }
                let planned = try store.addTasks([title], under: parent, now: now)
                lastAddedID = planned.first?.id
            case .status(let id):
                try store.editTasks { try TodoTree.update(id, status: .set(editor.text), in: &$0, now: now) }
            case .title(let id):
                try store.editTasks { try TodoTree.update(id, title: editor.text, in: &$0, now: now) }
            }
        } catch let failure as PlannerTodoFile.Failure {
            validationMessage = failure.message
            return false
        } catch {
            validationMessage = store.errorMessage ?? "Couldn’t save your changes."
            return false
        }
        self.editor = nil
        return true
    }

    @discardableResult
    func submit() -> Bool {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let task = PlannerTask(title: title)
        validationMessage = PlannerStore.validationMessage(for: task)
        guard validationMessage == nil, store.saveTask(task) else { return false }
        draft = ""
        lastAddedID = task.id
        return true
    }

    /// Closing a folder closes its open subtasks; they stay visible, struck
    /// through, until the panel closes, so one click undoes both.
    func toggle(_ id: UUID, now: Date = Date()) {
        guard let task = store.archive.tasks.first(where: { $0.id == id }) else { return }
        let before = Set(store.archive.tasks.filter(\.completed).map(\.id))
        guard store.setCompleted(id, !task.completed, now: now) else { return }
        let after = Set(store.archive.tasks.filter(\.completed).map(\.id))
        completedThisOpening.formUnion(after.subtracting(before))
        completedThisOpening.subtract(before.subtracting(after))
    }

    private func publishActivity() {
        let typing = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(editor?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        activityChanged(visible || typing)
    }
}

struct TodoInlineEditor: Equatable {
    enum Kind: Equatable {
        case subtask(parent: UUID), status(UUID), title(UUID)
        var taskID: UUID {
            switch self { case .subtask(let id), .status(let id), .title(let id): id }
        }
    }
    var kind: Kind
    var text: String
}

struct TodoHoverRowModel: Identifiable, Equatable {
    let task: PlannerTask
    let depth: Int
    let childCount: Int
    let parentTitle: String?
    var id: UUID { task.id }
}

struct TodoHoverView: View {
    static let contentHeight: CGFloat = 290
    @ObservedObject var model: TodoHoverModel
    @ObservedObject private var store: PlannerStore
    let onBack: () -> Void
    @FocusState private var inputFocused: Bool
    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: TodoHoverModel, onBack: @escaping () -> Void) {
        self.model = model
        self.store = model.store
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IslandHoverBackButton(destination: "todo", action: onBack)
                Text(model.showingHistory ? "History" : "To-do").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button {
                    model.showingHistory.toggle()
                    inputFocused = !model.showingHistory
                } label: {
                    Label(model.showingHistory ? "To-do" : "History",
                          systemImage: model.showingHistory ? "checklist" : "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .accessibilityLabel(model.showingHistory ? "Show active tasks" : "Show completed task history")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.96))

            if !model.showingHistory {
                TextField("Add a task, press Enter", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(inputFocused ? 0.7 : 0.18), lineWidth: 1))
                    .focused($inputFocused)
                    .onSubmit { if model.submit() { inputFocused = true } }
                    .disabled(!store.canWrite)
                    .accessibilityLabel("New task. Press Return to add")
            }

            if let message = (model.showingHistory ? nil : model.validationMessage) ?? store.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message).font(.system(size: 11)).foregroundStyle(.white)
                    if !store.canWrite { Button("Retry") { store.reload() } }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
            }

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        let rows = model.rows
                        if rows.isEmpty {
                            Text(model.showingHistory ? "No completed tasks" : "No tasks yet")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.76))
                                .frame(maxWidth: .infinity).padding(.vertical, 28)
                        } else {
                            ForEach(rows) { row in
                                TodoHoverRow(row: row, showingHistory: model.showingHistory, model: model,
                                             editorFocused: $editorFocused)
                                    .disabled(!store.canWrite)
                                if !model.showingHistory, model.editor?.kind == .subtask(parent: row.id) {
                                    TodoInlineField(placeholder: "Subtask, press Enter", depth: row.depth + 1,
                                                    model: model, focused: $editorFocused)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(model.showingHistory)
                .onChange(of: model.lastAddedID) { _, id in
                    if let id, !model.showingHistory { scroll.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .padding(12)
        .frame(height: Self.contentHeight)
        .task { await Task.yield(); inputFocused = true }
        // Rows move immediately, keeping repeated completion/reopen actions precise.
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }
}

/// Indent per tree level; five levels still leave room for the title.
private let todoIndent: CGFloat = 14

private struct TodoHoverRow: View {
    let row: TodoHoverRowModel
    let showingHistory: Bool
    @ObservedObject var model: TodoHoverModel
    var editorFocused: FocusState<Bool>.Binding
    @State private var hovering = false
    @State private var rowFrame: CGRect = .zero
    @State private var textWidth: CGFloat = 0

    private var task: PlannerTask { row.task }

    private func reportPreview() {
        let show = hovering && model.editor == nil
            && TodoHoverPreviewPolicy.needsPreview(title: task.title, status: task.status, textWidth: textWidth)
        TodoHoverPreviewState.shared.set(task.id, show ? rowFrame : nil)
    }
    private var editingStatus: Bool { model.editor?.kind == .status(task.id) }
    private var editingTitle: Bool { model.editor?.kind == .title(task.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if !showingHistory {
                // Folder disclosure; leaves keep the same column so titles align.
                Button { model.toggleCollapsed(task.id) } label: {
                    Image(systemName: model.collapsed.contains(task.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12, height: 18)
                        .opacity(row.childCount > 0 ? 0.75 : 0)
                }
                .buttonStyle(.plain)
                .disabled(row.childCount == 0)
                .accessibilityHidden(row.childCount == 0)
                .accessibilityLabel(model.collapsed.contains(task.id) ? "Expand \(task.title)" : "Collapse \(task.title)")
            }
            Button { model.toggle(task.id) } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(task.completed ? 0.76 : 0.9))
                    .frame(height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.completed ? "Reopen \(task.title)" : "Complete \(task.title)")
            .accessibilityHint(row.childCount > 0 && !task.completed ? "Also completes its subtasks" : "")

            VStack(alignment: .leading, spacing: 3) {
                if editingTitle {
                    TodoInlineField(placeholder: "Task title", depth: 0, model: model, focused: editorFocused)
                } else {
                    HStack(spacing: 5) {
                        Text(task.title)
                            .strikethrough(task.completed)
                            .font(.system(size: 12, weight: row.childCount > 0 ? .medium : .regular))
                            .lineLimit(2).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.white.opacity(task.completed ? 0.76 : 0.96))
                        if row.childCount > 0, model.collapsed.contains(task.id) {
                            Text("\(row.childCount)")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .padding(.horizontal, 5).frame(height: 15)
                                .background(.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(.white.opacity(0.8))
                                .accessibilityLabel("\(row.childCount) subtasks")
                        }
                    }
                    .frame(minHeight: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggle(task.id) }
                }
                if editingStatus {
                    TodoInlineField(placeholder: "Status, press Enter (empty clears)", depth: 0, model: model, focused: editorFocused)
                } else if let status = task.status {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .semibold))
                        Text(status).font(.system(size: 10.5)).lineLimit(2).truncationMode(.tail)
                    }
                    .foregroundStyle(.white.opacity(task.completed ? 0.55 : 0.68))
                    .help(status)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Status: \(status)")
                }
                if showingHistory {
                    Text([task.completedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Completion time unknown",
                          row.parentTitle.map { "in \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }

            if !showingHistory {
                // A fixed slot: showing the button on hover never reflows the title.
                let eligibility = TodoHoverModel.subtaskEligibility(for: row)
                Button { model.beginEditing(.subtask(parent: task.id)); editorFocused.wrappedValue = true } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        .frame(width: TodoHoverModel.actionSlotWidth, height: 18)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(eligibility != .allowed)
                .opacity(hovering && model.editor == nil && eligibility != .completed ? (eligibility == .allowed ? 1 : 0.35) : 0)
                .allowsHitTesting(hovering && eligibility == .allowed)
                .help(eligibility == .tooDeep ? "To-do allows \(TodoTree.maxDepth) levels" : "Add subtask")
                .accessibilityHidden(eligibility == .completed)
                .accessibilityLabel("Add subtask to \(task.title)")
            }
        }
        .padding(.leading, CGFloat(row.depth) * todoIndent + (showingHistory ? 8 : 4))
        .padding(.trailing, 8).padding(.vertical, 7)
        .frame(minHeight: showingHistory ? 46 : 32)
        .background(.white.opacity(hovering ? 0.14 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HistoryHoverView.hoverZoneSpaceName)) } action: { rowFrame = $0 }
        .onHover { hovering = $0; reportPreview() }
        .onChange(of: model.editor) { reportPreview() }
        .onDisappear { TodoHoverPreviewState.shared.set(task.id, nil) }
        .contextMenu {
            if !showingHistory {
                if !task.completed {
                    Button("Add Subtask") { model.beginEditing(.subtask(parent: task.id)); editorFocused.wrappedValue = true }
                        .disabled(TodoHoverModel.subtaskEligibility(for: row) != .allowed)
                }
                Button(task.status == nil ? "Add Status" : "Edit Status") {
                    model.beginEditing(.status(task.id)); editorFocused.wrappedValue = true
                }
                Button("Rename") { model.beginEditing(.title(task.id)); editorFocused.wrappedValue = true }
            }
            Button(task.completed ? "Reopen" : "Complete") { model.toggle(task.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
        .accessibilityValue(task.completed ? "Completed" : "Active")
        .accessibilityCustomContent("Completed at", task.completedAt.map {
            $0.formatted(date: .complete, time: .shortened)
        } ?? (task.completed ? "Unknown" : "Not completed"))
    }
}

/// Inline subtask/status/title field: Return commits, Escape cancels.
private struct TodoInlineField: View {
    let placeholder: String
    let depth: Int
    @ObservedObject var model: TodoHoverModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField(placeholder, text: Binding(get: { model.editor?.text ?? "" },
                                             set: { model.editor?.text = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).frame(height: 26)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .focused(focused)
            .onSubmit { if model.commitEditor() { focused.wrappedValue = false } }
            .onExitCommand { model.editor = nil }
            .padding(.leading, depth > 0 ? CGFloat(depth) * todoIndent + 34 : 0)
            .accessibilityLabel(placeholder)
    }
}
