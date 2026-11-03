import Foundation

public struct GitShowTool: AgentTool {
    public static let toolName = "git_show"

    private let maximumFileBytes = 40_000
    private let maximumDiffBytes = 24_000

    public init() {}

    public var capabilities: Set<ToolCapability> { [.gitRead] }

    public var schema: ToolSchema {
        ToolSchema(
            name: Self.toolName,
            description: """
            Show what a revision contains. With path: the file's content at that revision \
            (HEAD, a branch, a tag, HEAD~2, or a commit hash). Without path: the commit message \
            and the changes that commit introduced. Use it to understand why code looks the way \
            it does.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Revision to inspect. Defaults to HEAD.")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File to read at that revision. Omit to show the commit instead.")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var ref: String?
            var path: String?
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard let git = context.git else {
            return ToolOutput(content: "Git inspection is not available in this project.")
        }
        guard git.isRepository(at: context.workspace.root) else {
            return ToolOutput(content: "This project is not a git repository.")
        }

        let requestedRef = arguments.ref?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ref = requestedRef.isEmpty ? "HEAD" : requestedRef
        let path = arguments.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        do {
            if path.isEmpty {
                let details = try await git.commitDetails(at: context.workspace.root, ref: ref)
                return ToolOutput(content: commitSummary(details))
            }
            do {
                try context.workspace.validate(path)
            } catch {
                throw ToolError.workspace(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            let blob = try await git.blob(at: context.workspace.root, ref: ref, path: path)
            return ToolOutput(content: fileContent(blob, ref: ref))
        } catch let error as GitInspectError {
            return ToolOutput(content: "Error: \(error.errorDescription ?? "git show failed")")
        }
    }

    private func fileContent(_ blob: GitBlobContent, ref: String) -> String {
        guard !blob.isBinary else {
            return "\(blob.path) at \(ref) is binary (\(blob.sizeBytes) bytes)."
        }

        var lines = ["path: \(blob.path)", "ref: \(ref)", "size: \(blob.sizeBytes) bytes", ""]
        lines.append(numbered(blob.text))
        return lines.joined(separator: "\n")
    }

    private func commitSummary(_ details: GitCommitDetails) -> String {
        var lines = [
            "commit \(details.hash)",
            "author: \(details.author)",
            "date: \(ISO8601DateFormatter().string(from: details.date))",
            "",
            details.message.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if !details.diff.isEmpty {
            lines.append("")
            lines.append(details.diff)
        }

        var text = lines.joined(separator: "\n")
        if text.utf8.count > maximumDiffBytes {
            text = Self.clipped(text, to: maximumDiffBytes) + "\n[truncated]"
        }
        return text
    }

    private func numbered(_ text: String) -> String {
        guard !text.isEmpty else { return "(empty file)" }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        let rendered = lines.enumerated()
            .map { String(format: "%5d\t%@", $0.offset + 1, $0.element) }
            .joined(separator: "\n")
        guard rendered.utf8.count > maximumFileBytes else { return rendered }
        return Self.clipped(rendered, to: maximumFileBytes) + "\n[truncated]"
    }

    private static func clipped(_ text: String, to bytes: Int) -> String {
        String(decoding: Array(text.utf8).prefix(bytes), as: UTF8.self)
    }
}
