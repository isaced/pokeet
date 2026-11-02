import Foundation
import Observation
import PokeetCore

@MainActor
@Observable
final class ChatViewModel {
    struct Bubble: Identifiable, Equatable, Sendable {
        enum Role: Sendable, Equatable {
            case user
            case assistant
            case tool
            case error
        }

        let id = UUID()
        let role: Role
        var text: String
    }

    let project: Project

    var bubbles: [Bubble] = []
    var input = ""
    private(set) var isRunning = false
    private(set) var status: String?
    var errorMessage: String?
    private(set) var pendingProposals: [FileProposal] = []
    var isShowingReview = false
    private(set) var hasChanges = false
    private(set) var isCommitting = false
    var commitMessage = ""
    var isShowingCommitPrompt = false
    var banner: String?

    private let environment: AppEnvironment
    private let session: AgentSession
    private let coordinator = ProposalCoordinator()
    private var runTask: Task<Void, Never>?
    private var lastRequest = ""
    private var streamingBubbleID: UUID?

    init(project: Project, environment: AppEnvironment) {
        self.project = project
        self.environment = environment

        let client: any ModelClient = MockModelSupport.makeClient()
            ?? OpenAIChatClient(
                baseURL: environment.settings.baseURL,
                model: environment.settings.model,
                apiKey: environment.settings.apiKey
            )
        self.session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: project.directory)
        )

        coordinator.onPending = { [weak self] proposals in
            self?.present(proposals)
        }
        coordinator.onCleared = { [weak self] in
            self?.pendingProposals = []
            self?.isShowingReview = false
        }
    }

    var canCommit: Bool {
        project.isGitRepository
            && hasChanges
            && pendingProposals.isEmpty
            && !isRunning
            && !isCommitting
    }

    func loadInitialState() async {
        await refreshStatus()
    }

    func send() {
        guard !isRunning else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        input = ""
        lastRequest = text
        errorMessage = nil
        banner = nil
        bubbles.append(Bubble(role: .user, text: text))

        runTask = Task { [weak self] in
            await self?.run(text)
        }
    }

    func cancelRun() {
        streamingBubbleID = nil
        pendingProposals = []
        isShowingReview = false
        coordinator.cancelPending()
        runTask?.cancel()
    }

    func resolve(_ decisions: [ProposalDecision]) {
        pendingProposals = []
        isShowingReview = false
        coordinator.resolve(decisions)
    }

    func clearErrorMessage() {
        errorMessage = nil
    }

    func startNewSession() async {
        let task = runTask
        cancelRun()
        await task?.value

        await session.reset()

        bubbles = []
        input = ""
        streamingBubbleID = nil
        errorMessage = nil
        banner = nil
        pendingProposals = []
        isShowingReview = false
        lastRequest = ""
        await refreshStatus()
    }

    func dismissBanner() {
        banner = nil
    }

    func prepareCommit() {
        guard canCommit else { return }
        let summary = lastRequest.isEmpty ? "Pokeet changes" : String(lastRequest.prefix(60))
        commitMessage = "Pokeet: \(summary)"
        isShowingCommitPrompt = true
    }

    func commitAndPush() async {
        guard canCommit else { return }

        isCommitting = true
        banner = nil
        errorMessage = nil
        defer { isCommitting = false }

        do {
            let hash = try await environment.git.commitAll(
                at: project.directory,
                message: commitMessage.isEmpty ? "Pokeet changes" : commitMessage,
                author: environment.settings.gitAuthor
            )
            bubbles.append(Bubble(role: .tool, text: "Committed \(hash.prefix(8))."))

            do {
                try await environment.git.push(
                    at: project.directory,
                    token: environment.settings.gitToken
                )
                banner = "Committed and pushed."
            } catch {
                banner = "Committed locally, but push failed: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        await refreshStatus()
    }

    private func run(_ text: String) async {
        coordinator.reset()
        isRunning = true
        errorMessage = nil
        status = "Thinking…"
        defer {
            isRunning = false
            status = nil
            runTask = nil
            streamingBubbleID = nil
        }

        do {
            try await session.send(
                text,
                approval: { [coordinator] proposals in
                    await coordinator.request(proposals)
                },
                onEvent: { [weak self] event in
                    await MainActor.run {
                        self?.handle(event)
                    }
                }
            )
        } catch is CancellationError {
        } catch let error as AgentError {
            if case .cancelled = error {
                // User stopped the run.
            } else if errorMessage == nil {
                errorMessage = error.errorDescription
            }
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }

        await refreshStatus()
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .assistantTextDelta(let delta):
            appendAssistantDelta(delta)
            status = nil
        case .assistantMessage(let text):
            finalizeAssistantMessage(text)
            status = "Thinking…"
        case .toolStarted(let name):
            status = "Running \(name)…"
        case .toolFinished:
            status = "Thinking…"
        case .proposalsPending(let proposals):
            present(proposals)
        case .finished:
            streamingBubbleID = nil
            status = nil
        case .failed(let message):
            streamingBubbleID = nil
            errorMessage = message
            status = nil
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        if let id = streamingBubbleID,
           let index = bubbles.firstIndex(where: { $0.id == id }) {
            var bubble = bubbles[index]
            bubble.text += delta
            bubbles[index] = bubble
            return
        }

        let bubble = Bubble(role: .assistant, text: delta)
        bubbles.append(bubble)
        streamingBubbleID = bubble.id
    }

    private func finalizeAssistantMessage(_ text: String) {
        guard let id = streamingBubbleID else {
            if !text.isEmpty {
                bubbles.append(Bubble(role: .assistant, text: text))
            }
            return
        }

        streamingBubbleID = nil
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else {
            return
        }

        if text.isEmpty {
            bubbles.remove(at: index)
        } else {
            var bubble = bubbles[index]
            bubble.text = text
            bubbles[index] = bubble
        }
    }

    private func present(_ proposals: [FileProposal]) {
        pendingProposals = proposals
        isShowingReview = true
        status = nil
    }

    private func refreshStatus() async {
        guard project.isGitRepository else {
            hasChanges = false
            return
        }
        do {
            hasChanges = try await environment.git.status(at: project.directory).isEmpty == false
        } catch {
            hasChanges = false
        }
    }
}
