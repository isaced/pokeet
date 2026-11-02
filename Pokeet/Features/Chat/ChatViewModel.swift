import Foundation
import Observation
import PokeetCore

@MainActor
@Observable
final class ChatViewModel {
    struct Bubble: Identifiable, Equatable, Sendable {
        enum Role: String, Sendable, Equatable {
            case user
            case assistant
            case reasoning
            case tool
            case error
        }

        let id: UUID
        let role: Role
        var text: String
        var isStreaming: Bool

        init(
            id: UUID = UUID(),
            role: Role,
            text: String,
            isStreaming: Bool = false
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.isStreaming = isStreaming
        }
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
    private var reasoningBubbleID: UUID?
    private var didLoadSession = false

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
        if !didLoadSession {
            didLoadSession = true
            await restoreSession()
        }
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
        finalizeReasoningBubble()
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
        reasoningBubbleID = nil
        errorMessage = nil
        banner = nil
        pendingProposals = []
        isShowingReview = false
        lastRequest = ""
        await saveSession()
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
        await saveSession()
    }

    private func run(_ text: String) async {
        coordinator.reset()
        reasoningBubbleID = nil
        isRunning = true
        errorMessage = nil
        status = "Thinking…"
        defer {
            finalizeReasoningBubble()
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
            await saveSession()
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
        case .contextCompactionStarted:
            status = "Compacting context…"
        case .contextCompactionFinished(let success):
            status = "Thinking…"
            bubbles.append(Bubble(
                role: .tool,
                text: success
                    ? "Context summarized to fit the model window."
                    : "Context summary failed; using truncation."
            ))
        case .assistantReasoningDelta(let delta):
            appendReasoningDelta(delta)
            status = nil
        case .assistantTextDelta(let delta):
            finalizeReasoningBubble()
            appendAssistantDelta(delta)
            status = nil
        case .assistantMessage(let text):
            finalizeReasoningBubble()
            finalizeAssistantMessage(text)
            status = "Thinking…"
        case .toolStarted(let name):
            finalizeReasoningBubble()
            status = "Running \(name)…"
        case .toolFinished:
            status = "Thinking…"
        case .proposalsPending(let proposals):
            present(proposals)
        case .finished:
            finalizeReasoningBubble()
            streamingBubbleID = nil
            status = nil
        case .failed(let message):
            finalizeReasoningBubble()
            streamingBubbleID = nil
            errorMessage = message
            status = nil
        }
    }

    private func appendReasoningDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        if let id = reasoningBubbleID,
           let index = bubbles.firstIndex(where: { $0.id == id }) {
            var bubble = bubbles[index]
            bubble.text += delta
            bubbles[index] = bubble
            return
        }

        var bubble = Bubble(role: .reasoning, text: delta)
        bubble.isStreaming = true
        bubbles.append(bubble)
        reasoningBubbleID = bubble.id
    }

    private func finalizeReasoningBubble() {
        guard let id = reasoningBubbleID else { return }
        reasoningBubbleID = nil

        guard let index = bubbles.firstIndex(where: { $0.id == id }) else {
            return
        }

        var bubble = bubbles[index]
        bubble.isStreaming = false
        bubbles[index] = bubble
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

    private func restoreSession() async {
        guard let snapshot = await environment.sessions.load(projectName: project.name) else {
            return
        }

        bubbles = snapshot.bubbles.compactMap { stored in
            guard let role = Bubble.Role(rawValue: stored.role) else { return nil }
            return Bubble(id: stored.id, role: role, text: stored.text)
        }
        lastRequest = bubbles.last(where: { $0.role == .user })?.text ?? ""
        await session.restore(snapshot.restoredMessages)
    }

    private func saveSession() async {
        let history = await session.history
        let storedBubbles = bubbles.map {
            StoredBubble(id: $0.id, role: $0.role.rawValue, text: $0.text)
        }

        await environment.sessions.save(
            SessionSnapshot(messages: history, bubbles: storedBubbles),
            projectName: project.name
        )
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
