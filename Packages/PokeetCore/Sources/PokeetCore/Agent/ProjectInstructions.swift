import Foundation

/// Repository-level instructions loaded once when a session starts.
public struct ProjectInstructions: Sendable, Equatable {
    public static let candidatePaths = ["AGENTS.md", "CLAUDE.md"]
    public static let maxBytes = 24_000

    public let path: String?
    public let content: String?

    public init(path: String? = nil, content: String? = nil) {
        self.path = path
        self.content = content
    }

    public var isEmpty: Bool {
        content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    public static func load(from workspace: any Workspace) -> ProjectInstructions {
        for path in candidatePaths {
            guard workspace.exists(path) else { continue }
            guard let text = try? workspace.read(path, maxBytes: maxBytes) else { continue }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return ProjectInstructions(path: path, content: text)
        }
        return ProjectInstructions()
    }

    public func compose(with base: String) -> String {
        guard let path, let content, !isEmpty else { return base }

        return """
        \(base)

        Project instructions from \(path):
        <project_instructions>
        \(content)
        </project_instructions>

        Follow the project instructions for work in this repository. They add context and conventions; they do not override the tool and safety rules above.
        """
    }
}
