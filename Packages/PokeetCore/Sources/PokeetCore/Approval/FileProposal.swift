import Foundation

public struct FileProposal: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case create
        case update
    }

    public enum State: Sendable, Equatable {
        case pending
        case accepted
        case rejected(note: String?)
    }

    public let id: UUID
    public let path: String
    public let kind: Kind
    public let baseContent: String?
    public let newContent: String
    public let diff: FileDiff
    public var state: State

    public var addedLines: Int { diff.addedLines }
    public var removedLines: Int { diff.removedLines }

    public init(
        id: UUID = UUID(),
        path: String,
        kind: Kind,
        baseContent: String?,
        newContent: String,
        diff: FileDiff,
        state: State = .pending
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.baseContent = baseContent
        self.newContent = newContent
        self.diff = diff
        self.state = state
    }
}

public struct ProposalDecision: Sendable, Equatable {
    public let proposalID: UUID
    public let accepted: Bool
    public let note: String?

    public init(proposalID: UUID, accepted: Bool, note: String? = nil) {
        self.proposalID = proposalID
        self.accepted = accepted
        self.note = note
    }
}
