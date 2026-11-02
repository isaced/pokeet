import Foundation

public struct MoveFileTool: AgentTool {
    public init() {}

    public var schema: ToolSchema {
        ToolSchema(
            name: "move_file",
            description: "Propose moving or renaming a file. The user approves the move before anything changes on disk.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "from": .object([
                        "type": .string("string"),
                        "description": .string("Current file path relative to the repository root.")
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "description": .string("New file path relative to the repository root.")
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Short explanation of why the file should move.")
                    ])
                ]),
                "required": .array([.string("from"), .string("to")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var from: String
            var to: String
            var reason: String?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard !arguments.from.isEmpty, !arguments.to.isEmpty else {
            throw ToolError.invalidInput("from and to must not be empty.")
        }
        guard arguments.from != arguments.to else {
            throw ToolError.invalidInput("from and to are the same path.")
        }

        for path in [arguments.from, arguments.to] {
            do {
                try context.workspace.validate(path)
            } catch {
                throw ToolError.workspace(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }

        guard context.workspace.exists(arguments.from) else {
            throw ToolError.invalidInput("File not found: \(arguments.from)")
        }
        guard !context.workspace.exists(arguments.to) else {
            throw ToolError.invalidInput("Destination already exists: \(arguments.to)")
        }

        let baseContent: String?
        do {
            baseContent = try context.workspace.read(
                arguments.from,
                maxBytes: WorkspaceLimits.maxReadBytes
            )
        } catch WorkspaceError.binaryFile {
            baseContent = nil
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let proposal = FileProposal(
            path: arguments.from,
            kind: .move,
            destinationPath: arguments.to,
            baseContent: baseContent,
            newContent: baseContent ?? "",
            diff: .empty
        )

        return ToolOutput(
            content: "Proposed moving \(arguments.from) to \(arguments.to). Awaiting user approval.",
            proposals: [proposal]
        )
    }
}
