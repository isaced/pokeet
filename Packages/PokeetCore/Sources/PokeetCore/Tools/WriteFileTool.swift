import Foundation

public struct WriteFileTool: AgentTool {
    public init() {}

    public var capabilities: Set<ToolCapability> { [.writeFiles] }

    public var schema: ToolSchema {
        ToolSchema(
            name: "write_file",
            description: "Propose writing a UTF-8 text file. The user reviews the diff and may approve some or all hunks before anything is written.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to the repository root.")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Complete new content of the file.")
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Short explanation of why this change is needed.")
                    ])
                ]),
                "required": .array([.string("path"), .string("content")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var path: String
            var content: String
            var reason: String?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard !arguments.path.isEmpty else {
            throw ToolError.invalidInput("path must not be empty.")
        }
        do {
            try context.workspace.validate(arguments.path)
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        guard arguments.content.utf8.count <= WorkspaceLimits.maxWriteBytes else {
            throw ToolError.invalidInput(
                "Content is too large (max \(WorkspaceLimits.maxWriteBytes) bytes)."
            )
        }

        let baseContent: String?
        let exists = context.workspace.exists(arguments.path)
        if exists {
            do {
                baseContent = try context.workspace.read(
                    arguments.path,
                    maxBytes: WorkspaceLimits.maxReadBytes
                )
            } catch {
                throw ToolError.workspace(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        } else {
            baseContent = nil
        }

        if baseContent == arguments.content {
            return ToolOutput(content: "No changes to \(arguments.path): content is identical.")
        }

        let diff = LineDiff.compare(old: baseContent, new: arguments.content)
        let proposal = FileProposal(
            path: arguments.path,
            kind: exists ? .update : .create,
            baseContent: baseContent,
            newContent: arguments.content,
            diff: diff
        )

        return ToolOutput(
            content: "Proposed change to \(arguments.path) (+\(diff.addedLines)/-\(diff.removedLines)). Awaiting user approval.",
            proposals: [proposal]
        )
    }
}
