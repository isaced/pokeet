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
                    ]),
                    "offset": .object([
                        "type": .string("integer"),
                        "description": .string("Line number to start reading from (1-indexed). Defaults to 1.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of lines to return. Defaults to all available lines.")
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
            var offset: Int?
            var limit: Int?
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

        let totalLines = lines.count
        let offset = max(1, arguments.offset ?? 1)
        guard offset <= totalLines else {
            return ToolOutput(
                content: "Offset \(offset) is beyond the end of the file (\(totalLines) lines)."
            )
        }

        let startIndex = offset - 1
        let endIndex = arguments.limit.map {
            min(totalLines, startIndex + max(1, $0))
        } ?? totalLines
        let selected = lines[startIndex..<endIndex]
        let numbered = selected.enumerated().map { index, line in
            String(format: "%5d\t%@", startIndex + index + 1, line)
        }

        var content = numbered.joined(separator: "\n")
        if endIndex < totalLines {
            content += "\n[showing lines \(offset)-\(endIndex) of \(totalLines)]"
        }
        return ToolOutput(content: content)
    }
}
