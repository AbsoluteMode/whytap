import SwiftUI

// WHY: .project-docs/decisions/2026-10-20-todo-hover.md
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
    private(set) var visible = false
    private let activityChanged: (Bool) -> Void

    init(store: PlannerStore, activityChanged: @escaping (Bool) -> Void = { _ in }) {
        self.store = store
        self.activityChanged = activityChanged
    }

    func begin() {
        guard !visible else { return }
        completedThisOpening = []
        showingHistory = false
        validationMessage = nil
        lastAddedID = nil
        visible = true
        publishActivity()
    }

    func end() { visible = false; publishActivity() }

    var tasks: [PlannerTask] {
        let tasks = store.archive.tasks
        if showingHistory {
            return tasks.filter(\.completed).sorted {
                // Legacy completed tasks have no known completion time.
                ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
            }
        }
        return tasks.filter { !$0.completed || completedThisOpening.contains($0.id) }.sorted {
            if $0.completed != $1.completed { return !$0.completed }
            return $0.createdAt < $1.createdAt
        }
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

    func toggle(_ id: UUID, now: Date = Date()) {
        guard var task = store.archive.tasks.first(where: { $0.id == id }) else { return }
        task.completed.toggle()
        guard store.saveTask(task, now: now) else { return }
        if task.completed { completedThisOpening.insert(id) }
        else { completedThisOpening.remove(id) }
    }

    private func publishActivity() {
        activityChanged(visible || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

struct TodoHoverView: View {
    static let contentHeight: CGFloat = 290
    @ObservedObject var model: TodoHoverModel
    @ObservedObject private var store: PlannerStore
    let onBack: () -> Void
    @FocusState private var inputFocused: Bool
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
                        if model.tasks.isEmpty {
                            Text(model.showingHistory ? "No completed tasks" : "No tasks yet")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.76))
                                .frame(maxWidth: .infinity).padding(.vertical, 28)
                        } else {
                            ForEach(model.tasks) { task in
                                TodoHoverRow(task: task, showingHistory: model.showingHistory) { model.toggle(task.id) }
                                    .disabled(!store.canWrite)
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

private struct TodoHoverRow: View {
    let task: PlannerTask
    let showingHistory: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(task.completed ? 0.76 : 0.9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .strikethrough(task.completed)
                        .font(.system(size: 12))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.white.opacity(task.completed ? 0.76 : 0.96))
                    if showingHistory {
                        Text(task.completedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
                             ?? "Completion time unknown")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).frame(height: showingHistory ? 46 : 32)
            .background(.white.opacity(hovering ? 0.14 : 0.035), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.title)
        .onHover { hovering = $0 }
        .accessibilityLabel(task.title)
        .accessibilityValue(task.completed ? "Completed" : "Active")
        .accessibilityHint(task.completed ? "Reopen task" : "Complete task")
        .accessibilityCustomContent("Completed at", task.completedAt.map {
            $0.formatted(date: .complete, time: .shortened)
        } ?? (task.completed ? "Unknown" : "Not completed"))
    }
}
