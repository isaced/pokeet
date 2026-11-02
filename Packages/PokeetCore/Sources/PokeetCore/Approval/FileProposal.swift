import Foundation

public struct FileProposal: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case create
        case update
        case delete
        case move
    }

    public let id: UUID
    public let path: String
    public let kind: Kind
    public let destinationPath: String?
    public let baseContent: String?
    public let newContent: String
    public let diff: FileDiff

    public var addedLines: Int { diff.addedLines }
    public var removedLines: Int { diff.removedLines }

    public init(
        id: UUID = UUID(),
        path: String,
        kind: Kind,
        destinationPath: String? = nil,
        baseContent: String?,
        newContent: String,
        diff: FileDiff
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.destinationPath = destinationPath
        self.baseContent = baseContent
        self.newContent = newContent
        self.diff = diff
    }
}

public enum HunkSelection: Sendable, Equatable {
    case all
    case none
    case hunks(Set<DiffHunk.ID>)
}

public struct ProposalDecision: Sendable, Equatable {
    public let proposalID: UUID
    public let selection: HunkSelection
    public let note: String?

    public init(proposalID: UUID, selection: HunkSelection, note: String? = nil) {
        self.proposalID = proposalID
        self.selection = selection
        self.note = note
    }

    public static func acceptAll(proposalID: UUID) -> ProposalDecision {
        ProposalDecision(proposalID: proposalID, selection: .all)
    }

    public static func reject(proposalID: UUID, note: String? = nil) -> ProposalDecision {
        ProposalDecision(proposalID: proposalID, selection: .none, note: note)
    }

    public static func acceptHunks(
        proposalID: UUID,
        hunkIDs: Set<DiffHunk.ID>,
        note: String? = nil
    ) -> ProposalDecision {
        ProposalDecision(proposalID: proposalID, selection: .hunks(hunkIDs), note: note)
    }
}
