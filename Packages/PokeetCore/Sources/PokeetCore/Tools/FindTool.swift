import Foundation

public struct FindTool: AgentTool {
    public init() {}

    public var capabilities: Set<ToolCapability> { [.readFiles] }

    public var schema: ToolSchema {
        ToolSchema(
            name: "find",
            description: "Find files and directories by glob pattern. Recursively scans the project and skips .git and common build directories.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("Glob pattern, e.g. '*.swift', '**/*.json', or 'src/**/*.swift'.")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Directory to search in, relative to the repo root. Defaults to the repo root.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of results. Defaults to 1000, max 2000.")
                    ])
                ]),
                "required": .array([.string("pattern")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            let pattern: String
            let path: String?
            let limit: Int?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard !arguments.pattern.isEmpty else {
            throw ToolError.invalidInput("pattern must not be empty.")
        }

        let limit = min(max(1, arguments.limit ?? 1_000), 2_000)
        let globMatcher: GlobMatcher
        do {
            globMatcher = try GlobMatcher(pattern: arguments.pattern)
        } catch {
            throw ToolError.invalidInput(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let searchPath = arguments.path ?? ""
        let entries: [WorkspaceEntry]
        do {
            entries = try context.workspace.list(
                searchPath,
                recursive: true,
                maxEntries: limit + 1
            )
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let matches = entries.filter { globMatcher.matches($0.path) }
        let truncated = matches.count > limit || entries.count > limit
        let results = Array(matches.prefix(limit))

        guard !results.isEmpty else {
            return ToolOutput(content: "No files found.")
        }

        var content = results
            .map { $0.isDirectory ? "\($0.path)/" : $0.path }
            .joined(separator: "\n")

        if truncated {
            content += "\n[limit reached: \(limit) results]"
        }
        return ToolOutput(content: content)
    }
}
