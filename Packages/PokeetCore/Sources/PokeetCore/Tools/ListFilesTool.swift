import Foundation

public struct ListFilesTool: AgentTool {
    private let maxEntries = 500

    public init() {}

    public var capabilities: Set<ToolCapability> { [.readFiles] }

    public var schema: ToolSchema {
        ToolSchema(
            name: "list_files",
            description: "List files and directories in the repository. Paths are relative to the repository root.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Directory to list. Defaults to the repository root.")
                    ]),
                    "recursive": .object([
                        "type": .string("boolean"),
                        "description": .string("List recursively when true. Defaults to false.")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        try Task.checkCancellation()
        struct Arguments: Decodable {
            var path: String?
            var recursive: Bool?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        let entries = try context.workspace.list(
            arguments.path ?? "",
            recursive: arguments.recursive ?? false,
            maxEntries: maxEntries
        )

        guard !entries.isEmpty else {
            return ToolOutput(content: "No files found.")
        }

        var lines = entries.map { entry in
            entry.isDirectory ? "\(entry.path)/" : entry.path
        }
        if entries.count >= maxEntries {
            lines.append("[truncated at \(maxEntries) entries]")
        }
        return ToolOutput(content: lines.joined(separator: "\n"))
    }
}
