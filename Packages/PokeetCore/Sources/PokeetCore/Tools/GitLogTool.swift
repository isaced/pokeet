import Foundation

public struct GitLogTool: AgentTool {
    public init() {}

    public var schema: ToolSchema {
        ToolSchema(
            name: "git_log",
            description: "Show recent commits with hash, date, author and subject.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Number of commits to show. Defaults to 10, maximum 50.")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var limit: Int?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard let git = context.git else {
            return ToolOutput(content: "Git inspection is not available in this project.")
        }
        guard git.isRepository(at: context.workspace.root) else {
            return ToolOutput(content: "This project is not a git repository.")
        }

        let limit = min(max(1, arguments.limit ?? 10), 50)
        do {
            let commits = try await git.log(at: context.workspace.root, limit: limit)
            guard !commits.isEmpty else {
                return ToolOutput(content: "No commits yet.")
            }

            let formatter = ISO8601DateFormatter()
            let lines = commits.map { commit in
                let date = formatter.string(from: commit.date)
                return "\(String(commit.hash.prefix(8))) \(date) \(commit.author): \(commit.subject)"
            }
            return ToolOutput(content: lines.joined(separator: "\n"))
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
