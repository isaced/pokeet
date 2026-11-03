import Foundation

public enum AgentMode: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case plan
    case ask
    case auto
    case bypass

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plan: return "Plan"
        case .ask: return "Ask"
        case .auto: return "Auto"
        case .bypass: return "Bypass"
        }
    }

    public var shortDescription: String {
        switch self {
        case .plan:
            return "Read-only exploration. Submit a structured plan before making changes."
        case .ask:
            return "Review every file change before it is applied."
        case .auto:
            return "Apply edits automatically; review delete and move operations."
        case .bypass:
            return "Apply every file change without review."
        }
    }

    public var allowedCapabilities: Set<ToolCapability> {
        switch self {
        case .plan:
            return [.readFiles, .gitRead, .network, .planning]
        case .ask, .auto, .bypass:
            return Set(ToolCapability.allCases).subtracting([.planning])
        }
    }

    public func allows(_ capabilities: Set<ToolCapability>) -> Bool {
        capabilities.isSubset(of: allowedCapabilities)
    }

    public var approvalPolicy: ProposalApprovalPolicy {
        switch self {
        case .plan: return .deny
        case .ask: return .review
        case .auto: return .autoApplySafe
        case .bypass: return .autoApplyAll
        }
    }

    public var promptGuidance: String {
        switch self {
        case .ask:
            return ""
        case .plan:
            return """


            Current mode: Plan (read-only).
            You can inspect the repository and fetch public HTTPS URLs, but you cannot change files.
            write_file, edit_file, delete_file, move_file and run_script are disabled in this mode.
            http_request is limited to GET and HEAD in this mode.
            Use the read-only tools to investigate. When your investigation is complete, call
            submit_plan with a title, summary, and concrete steps (title/detail/files).
            Do not claim that changes were made. The user reviews the plan and approves execution.
            """
        case .auto:
            return """


            Current mode: Auto.
            write_file and edit_file changes are applied immediately without a review step.
            delete_file and move_file still require user review.
            Network write requests also require user review.
            Keep edits minimal, verify each result, and report exactly what changed.
            If you are executing an approved plan, output [DONE:n] after completing step n.
            You still cannot commit or push.
            """
        case .bypass:
            return """


            Current mode: Bypass.
            All file changes, including delete and move, are applied immediately without review.
            Network write requests are also sent without approval.
            Be deliberate, keep changes minimal, and report every change.
            You still cannot commit or push.
            """
        }
    }
}

public enum ProposalApprovalPolicy: Sendable, Equatable {
    case review
    case autoApplySafe
    case autoApplyAll
    case deny
}
