import Foundation

public struct TodoWriteTool: AgentTool {
    public static let toolName = "todo_write"

    public init() {}

    public var capabilities: Set<ToolCapability> { [.tasks] }

    public var schema: ToolSchema {
        ToolSchema(
            name: Self.toolName,
            description: """
            Replace the running task list. Use it for work that takes several steps: write the \
            list first, mark one item in_progress while you work on it, and mark it done as soon \
            as it is finished. Send the whole list every time; sending an empty list clears it. \
            Keep items short and concrete.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "items": .object([
                        "type": .string("array"),
                        "description": .string("The complete task list, at most \(TaskListFormatter.maximumItems) items."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "content": .object([
                                    "type": .string("string"),
                                    "description": .string("What needs doing, in a few words.")
                                ]),
                                "status": .object([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string("pending"),
                                        .string("in_progress"),
                                        .string("done"),
                                        .string("skipped")
                                    ]),
                                    "description": .string("Defaults to pending.")
                                ])
                            ]),
                            "required": .array([.string("content")]),
                            "additionalProperties": .bool(false)
                        ])
                    ])
                ]),
                "required": .array([.string("items")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            struct Item: Decodable {
                var content: String
                var status: String?
            }

            var items: [Item]
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard arguments.items.count <= TaskListFormatter.maximumItems else {
            throw ToolError.invalidInput(
                "A task list holds at most \(TaskListFormatter.maximumItems) items."
            )
        }

        var tasks: [TaskItem] = []
        for item in arguments.items {
            let title = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw ToolError.invalidInput("Task content must not be empty.")
            }
            guard title.count <= TaskListFormatter.maximumTitleLength else {
                throw ToolError.invalidInput(
                    "Task content is too long (max \(TaskListFormatter.maximumTitleLength) characters)."
                )
            }
            guard let status = Self.status(item.status) else {
                throw ToolError.invalidInput(
                    "Unknown task status '\(item.status ?? "")'. Use pending, in_progress, done or skipped."
                )
            }
            tasks.append(TaskItem(title: title, status: status))
        }

        guard !tasks.isEmpty else {
            return ToolOutput(content: "Task list cleared.", tasks: [])
        }

        return ToolOutput(
            content: "\(TaskListFormatter.statusSummary(tasks)):\n\(TaskListFormatter.checklist(tasks))",
            tasks: tasks
        )
    }

    private static func status(_ raw: String?) -> TaskItem.Status? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "pending":
            .pending
        case "in_progress", "inprogress", "active":
            .inProgress
        case "done", "completed", "complete":
            .done
        case "skipped":
            .skipped
        default:
            nil
        }
    }
}
