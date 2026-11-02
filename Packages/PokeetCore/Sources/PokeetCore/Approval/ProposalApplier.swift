public enum ProposalApplier {
    public static func apply(_ proposal: FileProposal, in workspace: any Workspace) throws {
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

            let current = try workspace.read(proposal.path, maxBytes: WorkspaceLimits.maxReadBytes)
            guard current == baseContent else {
                throw WorkspaceError.staleContent(proposal.path)
            }
        }

        try workspace.write(proposal.path, content: proposal.newContent)
    }
}
