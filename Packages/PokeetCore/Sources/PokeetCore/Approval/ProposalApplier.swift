public struct ProposalApplication: Sendable, Equatable {
    public let acceptedHunkIDs: Set<DiffHunk.ID>
    public let totalHunkCount: Int
    public let didWrite: Bool

    public var acceptedHunkCount: Int {
        acceptedHunkIDs.count
    }

    public var isPartial: Bool {
        didWrite && acceptedHunkCount > 0 && acceptedHunkCount < totalHunkCount
    }

    public init(
        acceptedHunkIDs: Set<DiffHunk.ID>,
        totalHunkCount: Int,
        didWrite: Bool
    ) {
        self.acceptedHunkIDs = acceptedHunkIDs
        self.totalHunkCount = totalHunkCount
        self.didWrite = didWrite
    }
}

public enum ProposalApplier {
    public static func apply(
        _ proposal: FileProposal,
        decision: ProposalDecision,
        in workspace: any Workspace
    ) throws -> ProposalApplication {
        let allHunkIDs = Set(proposal.diff.hunks.map(\.id))

        let acceptedHunkIDs: Set<DiffHunk.ID> = switch decision.selection {
        case .all:
            allHunkIDs
        case .none:
            []
        case .hunks(let selected):
            selected.intersection(allHunkIDs)
        }

        let shouldWrite = proposal.diff.hunks.isEmpty
            ? decision.selection == .all
            : !acceptedHunkIDs.isEmpty

        guard shouldWrite else {
            return ProposalApplication(
                acceptedHunkIDs: acceptedHunkIDs,
                totalHunkCount: allHunkIDs.count,
                didWrite: false
            )
        }

        try verifyBase(proposal, in: workspace)

        let content: String
        if proposal.diff.hunks.isEmpty || acceptedHunkIDs == allHunkIDs {
            content = proposal.newContent
        } else {
            content = try LineDiff.applying(
                base: proposal.baseContent ?? "",
                diff: proposal.diff,
                acceptedHunkIDs: acceptedHunkIDs,
                newContent: proposal.newContent
            )
        }

        try workspace.write(proposal.path, content: content)

        return ProposalApplication(
            acceptedHunkIDs: acceptedHunkIDs,
            totalHunkCount: allHunkIDs.count,
            didWrite: true
        )
    }

    private static func verifyBase(
        _ proposal: FileProposal,
        in workspace: any Workspace
    ) throws {
        switch proposal.kind {
        case .create:
            guard !workspace.exists(proposal.path) else {
                throw WorkspaceError.staleContent(proposal.path)
            }
        case .update:
            guard let baseContent = proposal.baseContent,
                  workspace.exists(proposal.path)
            else {
                throw WorkspaceError.staleContent(proposal.path)
            }

            let current = try workspace.read(
                proposal.path,
                maxBytes: WorkspaceLimits.maxReadBytes
            )
            guard current == baseContent else {
                throw WorkspaceError.staleContent(proposal.path)
            }
        }
    }
}
