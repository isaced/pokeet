import Foundation

/// One entry in the agent's task list.
///
/// Plans and todos share this model: a plan is a reviewed list of tasks, a todo
/// list is the running checklist the agent keeps for itself.
public struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case done
        case skipped
    }

    public let id: UUID
    public var title: String
    public var detail: String?
    public var files: [String]
    public var status: Status

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        files: [String] = [],
        status: Status = .pending
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.files = files
        self.status = status
    }
}

public enum TaskListFormatter {
    public static let maximumItems = 20
    public static let maximumTitleLength = 200

    /// Compact checklist for prompts and tool results.
    public static func checklist(_ items: [TaskItem]) -> String {
        items.map { item in
            "\(marker(item.status)) \(item.title)"
        }.joined(separator: "\n")
    }

    /// Reminder injected after compaction, when earlier tool results may be gone.
    public static func reminder(_ items: [TaskItem]) -> String {
        "[Task list — keep this up to date with \(TodoWriteTool.toolName).]\n"
            + checklist(items)
            + "\n[End of task list]"
    }

    public static func statusSummary(_ items: [TaskItem]) -> String {
        let done = items.filter { $0.status == .done }.count
        let active = items.filter { $0.status == .inProgress }.count
        var parts = ["\(done)/\(items.count) done"]
        if active > 0 {
            parts.append("\(active) in progress")
        }
        return parts.joined(separator: ", ")
    }

    private static func marker(_ status: TaskItem.Status) -> String {
        switch status {
        case .pending: "[ ]"
        case .inProgress: "[~]"
        case .done: "[x]"
        case .skipped: "[-]"
        }
    }
}
