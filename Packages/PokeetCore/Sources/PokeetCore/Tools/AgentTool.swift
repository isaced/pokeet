import Foundation

public struct ToolOutput: Sendable {
    public var content: String
    public var proposals: [FileProposal]

    public init(content: String, proposals: [FileProposal] = []) {
        self.content = content
        self.proposals = proposals
    }
}

public struct ToolContext: Sendable {
    public let workspace: any Workspace

    public init(workspace: any Workspace) {
        self.workspace = workspace
    }
}

public protocol AgentTool: Sendable {
    var schema: ToolSchema { get }
    func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput
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
            GrepTool(),
            FindTool()
        ])
    }

    public var schemas: [ToolSchema] {
        tools.map { $0.schema }
    }

    public func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.schema.name == name }
    }
}

public enum ToolError: Error, Sendable, Equatable, LocalizedError {
    case invalidArguments(String)
    case invalidInput(String)
    case workspace(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            "Invalid tool arguments: \(message)"
        case .invalidInput(let message):
            message
        case .workspace(let message):
            message
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
