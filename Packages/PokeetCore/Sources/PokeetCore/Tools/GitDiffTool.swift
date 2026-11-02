import Foundation

public struct GitDiffTool: AgentTool {
    public init() {}

    public var schema: ToolSchema {
        ToolSchema(
            name: "git_diff",
            description: "Show a unified diff of uncommitted changes. Use staged=true for changes already in the index.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Limit the diff to this file or directory.")
                    ]),
                    "staged": .object([
                        "type": .string("boolean"),
                        "description": .string("Diff HEAD against the index instead of the working tree. Defaults to false.")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var path: String?
            var staged: Bool?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard let git = context.git else {
            return ToolOutput(content: "Git inspection is not available in this project.")
        }
        guard git.isRepository(at: context.workspace.root) else {
            return ToolOutput(content: "This project is not a git repository.")
        }

        let path = arguments.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let diff = try await git.diff(
                at: context.workspace.root,
                path: path?.isEmpty == false ? path : nil,
                staged: arguments.staged ?? false
            )

            guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolOutput(content: "No changes.")
            }

            let limit = 40_000
            if diff.count > limit {
                return ToolOutput(content: String(diff.prefix(limit)) + "\n[truncated]")
            }
            return ToolOutput(content: diff)
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
