import Foundation

public struct DeleteFileTool: AgentTool {
    public init() {}

    public var capabilities: Set<ToolCapability> { [.writeFiles] }

    public var schema: ToolSchema {
        ToolSchema(
            name: "delete_file",
            description: "Propose deleting a file. The user reviews the change and must approve it before the file is removed.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to the repository root.")
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Short explanation of why this file should be deleted.")
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
        guard context.workspace.exists(arguments.path) else {
            throw ToolError.invalidInput("File not found: \(arguments.path)")
        }

        let baseContent: String?
        do {
            baseContent = try context.workspace.read(
                arguments.path,
                maxBytes: WorkspaceLimits.maxReadBytes
            )
        } catch WorkspaceError.binaryFile {
            baseContent = nil
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let diff = baseContent.map { LineDiff.compare(old: $0, new: "") } ?? .empty
        let proposal = FileProposal(
            path: arguments.path,
            kind: .delete,
            baseContent: baseContent,
            newContent: "",
            diff: diff
        )

        return ToolOutput(
            content: "Proposed deleting \(arguments.path) (-\(diff.removedLines)). Awaiting user approval.",
            proposals: [proposal]
        )
    }
}
