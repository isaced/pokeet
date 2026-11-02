import Foundation

public enum AgentEvent: Sendable, Equatable {
    case assistantMessage(String)
    case toolStarted(String)
    case toolFinished(name: String, summary: String)
    case proposalsPending([FileProposal])
    case finished
    case failed(String)
}

public enum AgentError: Error, Sendable, Equatable, LocalizedError {
    case model(String)
    case iterationLimit
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .model(let message):
            message
        case .iterationLimit:
            "The agent reached its iteration limit without finishing."
        case .cancelled:
            "The agent run was cancelled."
        }
    }
}

public struct AgentConfiguration: Sendable {
    public var maxIterations: Int
    public var maxToolOutputBytes: Int

    public init(maxIterations: Int = 20, maxToolOutputBytes: Int = 24_000) {
        self.maxIterations = maxIterations
        self.maxToolOutputBytes = maxToolOutputBytes
    }
}

public typealias ApprovalHandler = @Sendable ([FileProposal]) async -> [ProposalDecision]
public typealias EventHandler = @Sendable (AgentEvent) async -> Void

public enum AgentPrompts {
    public static let system = """
    You are Pokeet, a coding agent working inside a git repository on an iPhone.

    Tools:
    - list_files: list files and directories.
    - read_file: read a text file with line numbers.
    - write_file: propose a complete file write. The user reviews a diff and approves or rejects it.

    Rules:
    - All paths are relative to the repository root. Never use absolute paths, "~", "..", or .git paths.
    - Read before you write. Keep changes focused and minimal.
    - write_file only proposes a change. Do not claim a file changed until the tool result says it was applied.
    - If a change is rejected, read the user's note and address it before proposing again.
    - Do not commit or push. The user does that from the app.
    - When the task is complete, summarize what changed in a short message.
    """
}
