import Foundation

/// To-do as a tree, shared by PlannerStore and `whytap todo`/MCP: a task can be
/// a folder of subtasks (parentID), carries an optional one-line status, and
/// closing it closes every open descendant. Reopening restores the subtree it
/// closed and reopens closed ancestors so the task is visible again.
// WHY: .project-docs/decisions/2026-11-03-todo-tree.md
public struct TodoNode: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var completed: Bool
    public var createdAt: Date
    public var completedAt: Date?
    public var parentID: UUID?
    public var status: String?

    public init(id: UUID = UUID(), title: String, completed: Bool = false, createdAt: Date = Date(),
                completedAt: Date? = nil, parentID: UUID? = nil, status: String? = nil) {
        self.id = id; self.title = title; self.completed = completed; self.createdAt = createdAt
        self.completedAt = completedAt; self.parentID = parentID; self.status = status
    }
}

/// One requested task with its subtasks.
public struct TodoItem: Equatable, Sendable {
    public var title: String
    public var status: String?
    public var children: [TodoItem]
    public init(title: String, status: String? = nil, children: [TodoItem] = []) {
        self.title = title; self.status = status; self.children = children
    }
}

public enum TodoChange<T: Equatable & Sendable>: Equatable, Sendable {
    case keep
    case set(T)
}

public enum TodoTree {
    /// Levels including the top one; keeps the narrow island readable.
    public static let maxDepth = 5
    public static let maxStatusLength = 300

    // MARK: Validation

    /// Parents exist, no cycles, depth within maxDepth, statuses within limits.
    public static func isValid(_ nodes: [TodoNode]) -> Bool {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return nodes.allSatisfy { node in
            if let status = node.status,
               normalizedStatus(status) != status || status.isEmpty || status.count > maxStatusLength { return false }
            var depth = 1
            var seen: Set<UUID> = [node.id]
            var cursor = node.parentID
            while let parent = cursor {
                guard let next = byID[parent], seen.insert(parent).inserted else { return false }
                depth += 1
                guard depth <= maxDepth else { return false }
                cursor = next.parentID
            }
            return true
        }
    }

    /// One line; empty means no status.
    public static func normalizedStatus(_ raw: String) -> String {
        PlannerTodoFile.normalizedTitle(raw)
    }

    static func validatedStatus(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let status = normalizedStatus(raw)
        guard status.count <= maxStatusLength else {
            throw PlannerTodoFile.Failure("status_too_long", "A status has \(status.count) characters; the limit is \(maxStatusLength). Nothing was changed.")
        }
        return status.isEmpty ? nil : status
    }

    // MARK: Shape

    public static func depth(of id: UUID, in nodes: [TodoNode]) -> Int {
        var depth = 0
        var cursor: UUID? = id
        while let current = cursor, let node = nodes.first(where: { $0.id == current }), depth <= maxDepth {
            depth += 1
            cursor = node.parentID
        }
        return depth
    }

    public static func descendants(of id: UUID, in nodes: [TodoNode]) -> [UUID] {
        var result: [UUID] = []
        var frontier = [id]
        while let next = frontier.popLast() {
            let children = nodes.filter { $0.parentID == next }.map(\.id)
            result += children
            frontier += children
        }
        return result
    }

    /// Height of a subtree, 1 for a leaf.
    static func height(of id: UUID, in nodes: [TodoNode]) -> Int {
        1 + (nodes.filter { $0.parentID == id }.map { height(of: $0.id, in: nodes) }.max() ?? 0)
    }

    /// Depth-first order: siblings by creation time, then insertion order.
    /// A node hidden by `include` hides its subtree too.
    public static func ordered(_ nodes: [TodoNode], include: (TodoNode) -> Bool = { _ in true },
                               descend: (TodoNode) -> Bool = { _ in true },
                               before: ((TodoNode, TodoNode) -> Bool?)? = nil) -> [(node: TodoNode, depth: Int)] {
        let ids = Set(nodes.map(\.id))
        var children: [UUID?: [(offset: Int, node: TodoNode)]] = [:]
        for (offset, node) in nodes.enumerated() {
            // A missing parent never happens in a valid archive; show such a node at the top.
            let parent = node.parentID.flatMap { ids.contains($0) ? $0 : nil }
            children[parent, default: []].append((offset, node))
        }
        var result: [(node: TodoNode, depth: Int)] = []
        func visit(_ parent: UUID?, _ depth: Int) {
            let siblings = (children[parent] ?? []).sorted {
                if let first = before?($0.node, $1.node) { return first }
                return $0.node.createdAt != $1.node.createdAt ? $0.node.createdAt < $1.node.createdAt : $0.offset < $1.offset
            }
            for sibling in siblings where include(sibling.node) {
                result.append((sibling.node, depth))
                if depth < maxDepth + 1, descend(sibling.node) { visit(sibling.node.id, depth + 1) }
            }
        }
        visit(nil, 0)
        return result
    }

    /// A full UUID, or an unambiguous prefix of at least 8 characters.
    public static func resolve(_ reference: String, in nodes: [TodoNode]) throws -> UUID {
        let text = reference.trimmingCharacters(in: .whitespaces).lowercased()
        if let id = UUID(uuidString: text), nodes.contains(where: { $0.id == id }) { return id }
        let matches = text.count >= 8 ? nodes.filter { $0.id.uuidString.lowercased().hasPrefix(text) } : []
        guard matches.count == 1 else {
            throw matches.isEmpty
                ? PlannerTodoFile.Failure("not_found", "No task has the id \(reference). Run `whytap todo list` for ids.")
                : PlannerTodoFile.Failure("ambiguous_id", "Several tasks start with \(reference); use the full id.")
        }
        return matches[0].id
    }

    // MARK: Changes

    /// Adds items (with subtasks) under `parent`. An active sibling with the same
    /// title is reused, so a retry adds nothing; a given status is applied to it.
    @discardableResult
    public static func add(_ items: [TodoItem], under parent: UUID?, to nodes: inout [TodoNode],
                           now: Date) throws -> [PlannerTodoFile.Planned] {
        var working = nodes
        var depth = 1
        if let parent {
            guard let node = working.first(where: { $0.id == parent }) else {
                throw PlannerTodoFile.Failure("not_found", "The parent task no longer exists. Nothing was added.")
            }
            guard !node.completed else {
                throw PlannerTodoFile.Failure("parent_completed", "“\(node.title)” is completed; reopen it before adding subtasks. Nothing was added.")
            }
            depth = self.depth(of: parent, in: working) + 1
        }
        var planned: [PlannerTodoFile.Planned] = []
        var created = 0
        // New siblings sort after every existing task even when calls land within a millisecond.
        let start = max(now, (working.map(\.createdAt).max() ?? now).addingTimeInterval(0.000_01))
        func insert(_ items: [TodoItem], _ parent: UUID?, _ depth: Int) throws {
            guard items.isEmpty || depth <= maxDepth else {
                throw PlannerTodoFile.Failure("too_deep", "To-do allows \(maxDepth) levels. Nothing was added.")
            }
            for item in items {
                let id: UUID
                if let index = working.firstIndex(where: { !$0.completed && $0.parentID == parent && $0.title == item.title }) {
                    id = working[index].id
                    if let status = item.status { working[index].status = status }
                    planned.append(.init(id: id, title: item.title, isNew: false, parentID: parent))
                } else {
                    id = UUID()
                    // Distinct creation times keep the requested order among siblings.
                    working.append(TodoNode(id: id, title: item.title, createdAt: start.addingTimeInterval(Double(created) * 0.000_01),
                                            parentID: parent, status: item.status))
                    created += 1
                    planned.append(.init(id: id, title: item.title, isNew: true, parentID: parent))
                }
                try insert(item.children, id, depth + 1)
            }
        }
        try insert(items, parent, depth)
        guard working.count <= PlannerTodoFile.maxTasks else {
            throw PlannerTodoFile.Failure("too_many_tasks", "The to-do list is limited to \(PlannerTodoFile.maxTasks) tasks. Nothing was added.")
        }
        nodes = working
        return planned
    }

    /// Edits any field of one task. Moving checks for cycles and depth; closing
    /// cascades to open descendants.
    public static func update(_ id: UUID, title: String? = nil, status: TodoChange<String?> = .keep,
                              parent: TodoChange<UUID?> = .keep, completed: Bool? = nil,
                              in nodes: inout [TodoNode], now: Date) throws {
        var working = nodes
        guard let index = working.firstIndex(where: { $0.id == id }) else {
            throw PlannerTodoFile.Failure("not_found", "The task no longer exists.")
        }
        if let title { working[index].title = try PlannerTodoFile.validatedTitles([title])[0] }
        if case .set(let value) = status { working[index].status = try validatedStatus(value) }
        if case .set(let newParent) = parent, newParent != working[index].parentID {
            if let newParent {
                guard newParent != id, !descendants(of: id, in: working).contains(newParent) else {
                    throw PlannerTodoFile.Failure("invalid_parent", "A task can’t be moved inside itself.")
                }
                guard let target = working.first(where: { $0.id == newParent }) else {
                    throw PlannerTodoFile.Failure("not_found", "The new parent task no longer exists.")
                }
                guard !target.completed || working[index].completed else {
                    throw PlannerTodoFile.Failure("parent_completed", "“\(target.title)” is completed; reopen it first.")
                }
                guard depth(of: newParent, in: working) + height(of: id, in: working) <= maxDepth else {
                    throw PlannerTodoFile.Failure("too_deep", "To-do allows \(maxDepth) levels; this move would exceed it.")
                }
            }
            working[index].parentID = newParent
        }
        if let completed { setCompleted(id, completed, in: &working, now: now) }
        nodes = working
    }

    /// Closing closes every open descendant at the same time; reopening restores
    /// the descendants closed with it and reopens closed ancestors.
    public static func setCompleted(_ id: UUID, _ completed: Bool, in nodes: inout [TodoNode], now: Date) {
        guard let index = nodes.firstIndex(where: { $0.id == id }), nodes[index].completed != completed else { return }
        let subtree = Set(descendants(of: id, in: nodes))
        if completed {
            for i in nodes.indices where nodes[i].id == id || (subtree.contains(nodes[i].id) && !nodes[i].completed) {
                nodes[i].completed = true
                nodes[i].completedAt = now
            }
            return
        }
        let closedTogether = nodes[index].completedAt
        for i in nodes.indices where nodes[i].id == id
            || (subtree.contains(nodes[i].id) && nodes[i].completed && closedTogether != nil && nodes[i].completedAt == closedTogether) {
            nodes[i].completed = false
            nodes[i].completedAt = nil
        }
        var cursor = nodes[index].parentID
        while let parent = cursor, let i = nodes.firstIndex(where: { $0.id == parent }) {
            if nodes[i].completed { nodes[i].completed = false; nodes[i].completedAt = nil }
            cursor = nodes[i].parentID
        }
    }

    /// Removes a task with its whole subtree.
    public static func remove(_ id: UUID, from nodes: inout [TodoNode]) {
        let gone = Set(descendants(of: id, in: nodes) + [id])
        nodes.removeAll { gone.contains($0.id) }
    }
}

/// One `todo_add` / `todo_update` / `todo_list` request, validated before it
/// reaches the app or the file, and applied the same way by both.
public enum TodoRequest: Equatable, Sendable {
    case add(items: [TodoItem], parent: String?)
    case update(id: String, title: String?, status: TodoChange<String?>, parent: TodoChange<String?>, completed: Bool?)
    case list(includeCompleted: Bool)

    public var operation: String {
        switch self {
        case .add: "todo_add"
        case .update: "todo_update"
        case .list: "todo_list"
        }
    }

    public var mutates: Bool { if case .list = self { return false } else { return true } }

    /// Wire arguments. `titles` stays the form for flat batches, so an older
    /// running app that only knows it still accepts them.
    public var arguments: [String: AppControlValue] {
        switch self {
        case .add(let items, let parent):
            var result: [String: AppControlValue] = [:]
            if items.allSatisfy({ $0.status == nil && $0.children.isEmpty }) {
                result["titles"] = .array(items.map { .string($0.title) })
            } else {
                result["tasks"] = .array(items.map(Self.encode))
            }
            if let parent { result["parentID"] = .string(parent) }
            return result
        case .update(let id, let title, let status, let parent, let completed):
            var result: [String: AppControlValue] = ["id": .string(id)]
            if let title { result["title"] = .string(title) }
            if case .set(let value) = status { result["status"] = value.map(AppControlValue.string) ?? .null }
            if case .set(let value) = parent { result["parentID"] = value.map(AppControlValue.string) ?? .null }
            if let completed { result["completed"] = .bool(completed) }
            return result
        case .list(let includeCompleted):
            return includeCompleted ? ["includeCompleted": .bool(true)] : [:]
        }
    }

    private static func encode(_ item: TodoItem) -> AppControlValue {
        var object: [String: AppControlValue] = ["title": .string(item.title)]
        if let status = item.status { object["status"] = .string(status) }
        if !item.children.isEmpty { object["children"] = .array(item.children.map(encode)) }
        return .object(object)
    }

    /// Validates shape and limits. One bad title or status rejects the whole request.
    public init(_ operation: String, _ arguments: [String: AppControlValue]) throws {
        func invalid(_ message: String) -> PlannerTodoFile.Failure { .init("invalid_arguments", message) }
        func reference(_ key: String) throws -> String? {
            guard let value = arguments[key] else { return nil }
            guard let text = value.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw invalid("\(key) must be a task id.")
            }
            return text
        }
        switch operation {
        case "todo_add":
            guard Set(arguments.keys).isSubset(of: ["titles", "tasks", "parentID"]),
                  (arguments["titles"] == nil) != (arguments["tasks"] == nil) else {
                throw invalid("Pass either titles (strings) or tasks (objects with title, optional status and children), and optionally parentID.")
            }
            var count = 0
            func item(_ value: AppControlValue, _ depth: Int) throws -> TodoItem {
                guard let object = value.object, Set(object.keys).isSubset(of: ["title", "status", "children"]),
                      let title = object["title"]?.string,
                      object["status"] == nil || object["status"]?.string != nil,
                      object["children"] == nil || object["children"]?.array != nil else {
                    throw invalid("Each task is {title, status?, children?}.")
                }
                guard depth <= TodoTree.maxDepth else {
                    throw PlannerTodoFile.Failure("too_deep", "To-do allows \(TodoTree.maxDepth) levels. Nothing was added.")
                }
                count += 1
                return TodoItem(title: title, status: object["status"]?.string,
                                children: try (object["children"]?.array ?? []).map { try item($0, depth + 1) })
            }
            var items: [TodoItem]
            if let titles = arguments["titles"] {
                guard let raw = titles.array, raw.allSatisfy({ $0.string != nil }) else {
                    throw invalid("Pass titles as an array of 1–\(PlannerTodoFile.maxBatch) strings.")
                }
                items = raw.compactMap(\.string).map { TodoItem(title: $0) }
                count = items.count
            } else {
                guard let raw = arguments["tasks"]?.array else { throw invalid("tasks must be an array.") }
                items = try raw.map { try item($0, 1) }
            }
            guard (1...PlannerTodoFile.maxBatch).contains(count) else {
                throw invalid("Provide 1–\(PlannerTodoFile.maxBatch) tasks in one request, counting subtasks.")
            }
            var position = 0
            func validated(_ item: TodoItem) throws -> TodoItem {
                position += 1
                let at = position
                var copy = item
                do { copy.title = try PlannerTodoFile.validatedTitles([item.title])[0] } catch let failure as PlannerTodoFile.Failure {
                    throw PlannerTodoFile.Failure(failure.code, failure.message.replacingOccurrences(of: "Task 1", with: "Task \(at)"))
                }
                copy.status = try TodoTree.validatedStatus(item.status)
                copy.children = try item.children.map(validated)
                return copy
            }
            items = try items.map(validated)
            self = .add(items: items, parent: try reference("parentID"))
        case "todo_update":
            guard Set(arguments.keys).isSubset(of: ["id", "title", "status", "parentID", "completed"]),
                  let id = try reference("id"), arguments.count > 1 else {
                throw invalid("Pass id and at least one of title, status (null clears), parentID (null moves to the top) or completed.")
            }
            var title: String?
            if let value = arguments["title"] {
                guard let text = value.string else { throw invalid("title must be a string.") }
                title = try PlannerTodoFile.validatedTitles([text])[0]
            }
            var status: TodoChange<String?> = .keep
            if let value = arguments["status"] {
                guard value == .null || value.string != nil else { throw invalid("status must be a string or null.") }
                status = .set(try TodoTree.validatedStatus(value.string))
            }
            var parent: TodoChange<String?> = .keep
            if let value = arguments["parentID"] {
                guard value == .null || value.string != nil else { throw invalid("parentID must be a task id or null.") }
                parent = .set(value == .null ? nil : try reference("parentID"))
            }
            var completed: Bool?
            if let value = arguments["completed"] {
                guard let flag = value.bool else { throw invalid("completed must be a boolean.") }
                completed = flag
            }
            self = .update(id: id, title: title, status: status, parent: parent, completed: completed)
        case "todo_list":
            guard Set(arguments.keys).isSubset(of: ["includeCompleted"]),
                  arguments["includeCompleted"] == nil || arguments["includeCompleted"]?.bool != nil else {
                throw invalid("includeCompleted must be a boolean.")
            }
            self = .list(includeCompleted: arguments["includeCompleted"]?.bool ?? false)
        default:
            throw PlannerTodoFile.Failure("unknown_operation", "Unknown to-do operation.")
        }
    }

    /// Applies the request; the returned builder renders the reply from the
    /// final saved state for a given delivery (`app` or `file`).
    public func apply(to nodes: inout [TodoNode], now: Date) throws -> (String) -> AppControlValue {
        switch self {
        case .add(let items, let parent):
            let parentID = try parent.map { try TodoTree.resolve($0, in: nodes) }
            let planned = try TodoTree.add(items, under: parentID, to: &nodes, now: now)
            let final = nodes
            return { PlannerTodoFile.result(planned, delivery: $0, nodes: final) }
        case .update(let id, let title, let status, let parent, let completed):
            let target = try TodoTree.resolve(id, in: nodes)
            let parentChange: TodoChange<UUID?>
            switch parent {
            case .keep: parentChange = .keep
            case .set(let reference): parentChange = .set(try reference.map { try TodoTree.resolve($0, in: nodes) })
            }
            try TodoTree.update(target, title: title, status: status, parent: parentChange, completed: completed,
                                in: &nodes, now: now)
            let final = nodes
            return { PlannerTodoFile.updated(target, delivery: $0, nodes: final) }
        case .list(let includeCompleted):
            let final = nodes
            return { PlannerTodoFile.listing(final, includeCompleted: includeCompleted, delivery: $0) }
        }
    }
}
