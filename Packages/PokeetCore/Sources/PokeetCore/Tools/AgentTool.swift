import Foundation

public struct ToolOutput: Sendable {
    public var content: String
    public var proposals: [FileProposal]
    public var plan: AgentPlan?
    public var tasks: [TaskItem]?
    /// Images the tool wants the model to see, delivered in the next request.
    public var images: [ChatImage]

    public init(
        content: String,
        proposals: [FileProposal] = [],
        plan: AgentPlan? = nil,
        tasks: [TaskItem]? = nil,
        images: [ChatImage] = []
    ) {
        self.content = content
        self.proposals = proposals
        self.plan = plan
        self.tasks = tasks
        self.images = images
    }
}

public struct ToolContext: Sendable {
    public let workspace: any Workspace
    public let git: (any GitInspecting)?
    public let networkPolicy: NetworkAccessPolicy
    public let scripting: ScriptRuntimes?
    public let webSearch: (any WebSearchProviding)?
    public let webSearchBudget: WebSearchBudget?

    public init(
        workspace: any Workspace,
        git: (any GitInspecting)? = nil,
        networkPolicy: NetworkAccessPolicy = .init(),
        scripting: ScriptRuntimes? = nil,
        webSearch: (any WebSearchProviding)? = nil,
        webSearchBudget: WebSearchBudget? = nil
    ) {
        self.workspace = workspace
        self.git = git
        self.networkPolicy = networkPolicy
        self.scripting = scripting
        self.webSearch = webSearch
        self.webSearchBudget = webSearchBudget
    }
}

public enum ToolCapability: String, Sendable, Hashable, CaseIterable {
    case readFiles
    case writeFiles
    case gitRead
    case network
    case planning
    case tasks
    case runScript
}

public protocol AgentTool: Sendable {
    var schema: ToolSchema { get }
    var capabilities: Set<ToolCapability> { get }
    func review(arguments: Data, context: ToolContext) async throws -> ActionRequest?
    func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput
}

public extension AgentTool {
    func review(arguments: Data, context: ToolContext) async throws -> ActionRequest? {
        nil
    }
}

public struct ToolRegistry: Sendable {
    public let tools: [any AgentTool]

    public init(_ tools: [any AgentTool]) {
        self.tools = tools
    }

    public static var standard: ToolRegistry {
        ToolRegistry([
            ListFilesTool(),
            ReadFileTool(),
            WriteFileTool(),
            EditFileTool(),
            DeleteFileTool(),
            MoveFileTool(),
            GrepTool(),
            FindTool(),
            FileInfoTool(),
            ReadImageTool(),
            TodoWriteTool(),
            RunScriptTool(),
            GitStatusTool(),
            GitDiffTool(),
            GitLogTool(),
            GitShowTool(),
            HTTPRequestTool(),
            WebSearchTool(),
            SubmitPlanTool()
        ])
    }

    public var schemas: [ToolSchema] {
        tools.map { $0.schema }
    }

    public func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.schema.name == name }
    }

    public func filtered(for mode: AgentMode) -> ToolRegistry {
        ToolRegistry(tools.filter { $0.capabilities.isSubset(of: mode.allowedCapabilities) })
    }
}

public enum ToolError: Error, Sendable, Equatable, LocalizedError {
    case invalidArguments(String)
    case invalidInput(String)
    case workspace(String)
    case network(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            "Invalid tool arguments: \(message)"
        case .invalidInput(let message):
            message
        case .workspace(let message):
            message
        case .network(let message):
            message
        case .timedOut(let name):
            "Tool '\(name)' timed out."
        }
    }
}

func decodeToolArguments<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
    let payload = data.isEmpty ? Data("{}".utf8) : data
    do {
        return try JSONDecoder().decode(type, from: payload)
    } catch {
        throw ToolError.invalidArguments(error.localizedDescription)
    }
}
