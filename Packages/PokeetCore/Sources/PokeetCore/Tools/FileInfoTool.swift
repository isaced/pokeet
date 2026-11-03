import Foundation

public struct FileInfoTool: AgentTool {
    public static let toolName = "file_info"

    public init() {}

    public var capabilities: Set<ToolCapability> { [.readFiles] }

    public var schema: ToolSchema {
        ToolSchema(
            name: Self.toolName,
            description: """
            Inspect a path before reading it: kind, size, line count, whether it is UTF-8 text, \
            and when it last changed. Use it for unknown, large or possibly binary files so \
            read_file does not fail on them. Paths are relative to the repository root.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File or directory relative to the repository root.")
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
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        let path = arguments.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw ToolError.invalidInput("path must not be empty.")
        }

        let info: FileInfo
        do {
            info = try FileProbe.probe(path, in: context.workspace)
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        guard info.exists else {
            return ToolOutput(content: "No such file or directory: \(path)")
        }

        if info.isDirectory {
            return ToolOutput(content: try directorySummary(path, info: info, context: context))
        }

        var lines = [
            "path: \(info.path)",
            "kind: \(info.isSymbolicLink ? "file (symbolic link)" : "file")",
            "size: \(info.sizeDescription) (\(info.sizeBytes) bytes)",
            "lines: \(info.isText && info.lineCount > 0 ? String(info.lineCount) : "unknown")",
            "text: \(info.isText ? "yes" : "no (binary)")"
        ]
        if let modified = info.modified {
            lines.append("modified: \(ISO8601DateFormatter().string(from: modified))")
        }
        lines.append("read_file: \(readHint(for: info))")
        return ToolOutput(content: lines.joined(separator: "\n"))
    }

    private func directorySummary(
        _ path: String,
        info: FileInfo,
        context: ToolContext
    ) throws -> String {
        let entries = try context.workspace.list(path, recursive: false, maxEntries: 500)
        var lines = ["path: \(info.path)", "kind: directory", "entries: \(entries.count)"]
        if entries.count >= 500 {
            lines[2] = "entries: 500+ (use list_files)"
        }
        return lines.joined(separator: "\n")
    }

    private func readHint(for info: FileInfo) -> String {
        guard info.isText else {
            return "not readable as text; read_file cannot open this file"
        }
        if info.sizeBytes > WorkspaceLimits.maxWriteBytes {
            return "large; pass offset and limit to read it in parts"
        }
        return "ok"
    }
}
