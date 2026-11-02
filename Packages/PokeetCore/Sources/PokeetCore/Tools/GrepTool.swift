import Foundation

public struct GrepTool: AgentTool {
    private let maxFiles = 5_000
    private let maxFileBytes = 500_000
    private let maxLineCharacters = 500

    public init() {}

    public var capabilities: Set<ToolCapability> { [.readFiles] }

    public var schema: ToolSchema {
        ToolSchema(
            name: "grep",
            description: "Search file contents with a regular expression or literal string. Recursively scans text files and skips .git and common build directories.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("Regex or literal text to search for.")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File or directory relative to the repo root. Defaults to the repo root.")
                    ]),
                    "glob": .object([
                        "type": .string("string"),
                        "description": .string("Only search files matching this glob, e.g. '*.swift' or 'src/**/*.swift'.")
                    ]),
                    "ignore_case": .object([
                        "type": .string("boolean"),
                        "description": .string("Case-insensitive search. Defaults to false.")
                    ]),
                    "literal": .object([
                        "type": .string("boolean"),
                        "description": .string("Treat pattern as literal text instead of a regex. Defaults to false.")
                    ]),
                    "context": .object([
                        "type": .string("integer"),
                        "description": .string("Context lines before and after each match. Defaults to 0, max 5.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum matching lines to return. Defaults to 100, max 500.")
                    ])
                ]),
                "required": .array([.string("pattern")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context toolContext: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            let pattern: String
            let path: String?
            let glob: String?
            let ignoreCase: Bool?
            let literal: Bool?
            let context: Int?
            let limit: Int?

            enum CodingKeys: String, CodingKey {
                case pattern
                case path
                case glob
                case ignoreCase = "ignore_case"
                case literal
                case context
                case limit
            }
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        guard !arguments.pattern.isEmpty else {
            throw ToolError.invalidInput("pattern must not be empty.")
        }

        let limit = min(max(1, arguments.limit ?? 100), 500)
        let contextLines = min(max(0, arguments.context ?? 0), 5)

        let globMatcher: GlobMatcher?
        let globText = arguments.glob?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if globText.isEmpty {
            globMatcher = nil
        } else {
            do {
                globMatcher = try GlobMatcher(pattern: globText)
            } catch {
                throw ToolError.invalidInput(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }

        let regex: NSRegularExpression
        do {
            let pattern = arguments.literal == true
                ? NSRegularExpression.escapedPattern(for: arguments.pattern)
                : arguments.pattern
            regex = try NSRegularExpression(
                pattern: pattern,
                options: arguments.ignoreCase == true ? [.caseInsensitive] : []
            )
        } catch {
            throw ToolError.invalidInput("Invalid regex: \(error.localizedDescription)")
        }

        let searchPath = arguments.path ?? ""
        let files: [String]
        let listWasTruncated: Bool

        do {
            let entries = try toolContext.workspace.list(
                searchPath,
                recursive: true,
                maxEntries: maxFiles
            )
            listWasTruncated = entries.count >= maxFiles
            files = entries
                .filter { !$0.isDirectory }
                .filter { globMatcher?.matches($0.path) ?? true }
                .map(\.path)
        } catch WorkspaceError.notADirectory {
            guard toolContext.workspace.exists(searchPath) else {
                throw ToolError.workspace("Path not found: \(searchPath.isEmpty ? "." : searchPath)")
            }
            files = (globMatcher?.matches(searchPath) ?? true) ? [searchPath] : []
            listWasTruncated = false
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        var outputLines: [String] = []
        var matchCount = 0
        var limitReached = false

        for file in files {
            if limitReached {
                break
            }

            let text: String
            do {
                text = try toolContext.workspace.read(file, maxBytes: maxFileBytes)
            } catch {
                continue
            }

            let lines = text.components(separatedBy: "\n")
            var matchIndices: [Int] = []

            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    matchIndices.append(index)
                    matchCount += 1
                    if matchCount >= limit {
                        limitReached = true
                        break
                    }
                }
            }

            guard !matchIndices.isEmpty else { continue }

            var displayIndices = IndexSet()
            for matchIndex in matchIndices {
                let lower = max(0, matchIndex - contextLines)
                let upper = min(lines.count - 1, matchIndex + contextLines)
                if lower <= upper {
                    displayIndices.insert(integersIn: lower...upper)
                }
            }

            let matchSet = Set(matchIndices)
            var previousIndex: Int?

            for index in displayIndices {
                if let previousIndex, index > previousIndex + 1 {
                    outputLines.append("--")
                }

                let line = truncatedLine(lines[index])
                if matchSet.contains(index) {
                    outputLines.append("\(file):\(index + 1): \(line)")
                } else {
                    outputLines.append("\(file)-\(index + 1)- \(line)")
                }
                previousIndex = index
            }
        }

        guard !outputLines.isEmpty else {
            return ToolOutput(content: "No matches found.")
        }

        var content = outputLines.joined(separator: "\n")
        if limitReached {
            content += "\n[limit reached: \(limit) matching lines]"
        }
        if listWasTruncated {
            content += "\n[searched first \(maxFiles) files]"
        }
        return ToolOutput(content: content)
    }

    private func truncatedLine(_ line: String) -> String {
        guard line.count > maxLineCharacters else { return line }
        return String(line.prefix(maxLineCharacters)) + "…"
    }
}
