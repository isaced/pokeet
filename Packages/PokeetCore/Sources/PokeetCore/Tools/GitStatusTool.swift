import Foundation

public struct GitStatusTool: AgentTool {
    public init() {}

    public var capabilities: Set<ToolCapability> { [.gitRead] }

    public var schema: ToolSchema {
        ToolSchema(
            name: "git_status",
            description: "Show uncommitted changes in the git working tree, including untracked and deleted files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Only show changes under this directory or file. Defaults to the whole repository.")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var path: String?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard let git = context.git else {
            return ToolOutput(content: "Git inspection is not available in this project.")
        }
        guard git.isRepository(at: context.workspace.root) else {
            return ToolOutput(content: "This project is not a git repository.")
        }

        do {
            var entries = try await git.workingTreeStatus(at: context.workspace.root)
            if let filter = arguments.path?.trimmingCharacters(in: .whitespacesAndNewlines),
               !filter.isEmpty {
                let prefix = filter.hasSuffix("/") ? filter : filter + "/"
                entries = entries.filter {
                    $0.path == filter || $0.path.hasPrefix(prefix)
                }
            }

            guard !entries.isEmpty else {
                return ToolOutput(content: "Working tree is clean.")
            }

            let lines = entries
                .sorted { $0.path < $1.path }
                .map { "\($0.state) \($0.path)" }
            return ToolOutput(content: lines.joined(separator: "\n"))
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
