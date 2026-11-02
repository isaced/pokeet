import Foundation

public struct EditFileTool: AgentTool {
    public init() {}

    public var schema: ToolSchema {
        ToolSchema(
            name: "edit_file",
            description: "Propose precise text replacements in an existing file. Each old_text must appear exactly once in the original file. The user reviews the diff before anything is written.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to the repository root.")
                    ]),
                    "edits": .object([
                        "type": .string("array"),
                        "description": .string("Targeted replacements. All edits are matched against the original file, not incrementally. Use write_file for new files or complete rewrites."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "old_text": .object([
                                    "type": .string("string"),
                                    "description": .string("Exact text to replace. It must be unique in the original file and must not overlap other edits.")
                                ]),
                                "new_text": .object([
                                    "type": .string("string"),
                                    "description": .string("Replacement text.")
                                ])
                            ]),
                            "required": .array([.string("old_text"), .string("new_text")]),
                            "additionalProperties": .bool(false)
                        ])
                    ])
                ]),
                "required": .array([.string("path"), .string("edits")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Edit: Decodable {
            let oldText: String
            let newText: String

            enum CodingKeys: String, CodingKey {
                case oldText = "old_text"
                case newText = "new_text"
            }
        }

        struct Arguments: Decodable {
            let path: String
            let edits: [Edit]
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard !arguments.path.isEmpty else {
            throw ToolError.invalidInput("path must not be empty.")
        }
        guard !arguments.edits.isEmpty else {
            throw ToolError.invalidInput("Provide at least one edit.")
        }

        do {
            try context.workspace.validate(arguments.path)
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let baseContent: String
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

        var replacements: [(range: Range<String.Index>, newText: String)] = []

        for edit in arguments.edits {
            guard !edit.oldText.isEmpty else {
                throw ToolError.invalidInput("old_text must not be empty.")
            }

            let matches = Self.occurrences(of: edit.oldText, in: baseContent)
            guard matches.count == 1, let range = matches.first else {
                throw ToolError.invalidInput(
                    "old_text must appear exactly once in \(arguments.path). "
                        + "Add more surrounding context or split the edit."
                )
            }
            replacements.append((range, edit.newText))
        }

        replacements.sort { $0.range.lowerBound < $1.range.lowerBound }
        for index in 1..<replacements.count {
            guard replacements[index].range.lowerBound >= replacements[index - 1].range.upperBound else {
                throw ToolError.invalidInput("Edits must not overlap. Merge nearby changes into one edit.")
            }
        }

        var pieces: [String] = []
        var cursor = baseContent.startIndex
        for replacement in replacements {
            pieces.append(String(baseContent[cursor..<replacement.range.lowerBound]))
            pieces.append(replacement.newText)
            cursor = replacement.range.upperBound
        }
        pieces.append(String(baseContent[cursor...]))
        let newContent = pieces.joined()

        guard newContent != baseContent else {
            return ToolOutput(content: "No changes to \(arguments.path): replacement is identical.")
        }
        guard newContent.utf8.count <= WorkspaceLimits.maxWriteBytes else {
            throw ToolError.invalidInput(
                "Edited content is too large (max \(WorkspaceLimits.maxWriteBytes) bytes)."
            )
        }

        let diff = LineDiff.compare(old: baseContent, new: newContent)
        let proposal = FileProposal(
            path: arguments.path,
            kind: .update,
            baseContent: baseContent,
            newContent: newContent,
            diff: diff
        )

        return ToolOutput(
            content: "Proposed \(arguments.edits.count) edit(s) to \(arguments.path) "
                + "(+\(diff.addedLines)/-\(diff.removedLines)). Awaiting user approval.",
            proposals: [proposal]
        )
    }

    private static func occurrences(
        of needle: String,
        in haystack: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex

        while searchStart < haystack.endIndex,
              let range = haystack.range(
                  of: needle,
                  options: [],
                  range: searchStart..<haystack.endIndex
              ) {
            ranges.append(range)
            if ranges.count > 1 {
                break
            }
            searchStart = range.upperBound
        }

        return ranges
    }
}
