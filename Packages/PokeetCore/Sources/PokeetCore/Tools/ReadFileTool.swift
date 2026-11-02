import Foundation

public struct ReadFileTool: AgentTool {
    public init() {}

    public var schema: ToolSchema {
        ToolSchema(
            name: "read_file",
            description: "Read a UTF-8 text file from the repository. Returns numbered lines.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to the repository root.")
                    ]),
                    "max_bytes": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of bytes to read. Defaults to 20000.")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var path: String
            var max_bytes: Int?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard !arguments.path.isEmpty else {
            throw ToolError.invalidInput("path must not be empty.")
        }

        let maxBytes = min(max(1, arguments.max_bytes ?? WorkspaceLimits.defaultReadBytes), 100_000)
        let text: String
        do {
            text = try context.workspace.read(arguments.path, maxBytes: maxBytes)
        } catch {
            throw ToolError.workspace((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        guard !text.isEmpty else {
            return ToolOutput(content: "(empty file: \(arguments.path))")
        }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        let numbered = lines.enumerated().map { index, line in
            String(format: "%5d\t%@", index + 1, line)
        }
        return ToolOutput(content: numbered.joined(separator: "\n"))
    }
}
