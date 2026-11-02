import Foundation
import Observation
import PokeetCore

struct ContextFile: Sendable, Equatable {
    let path: String
    let content: String
}

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
        var images: [ChatImage]
        var filePaths: [String]

        init(
            id: UUID = UUID(),
            role: Role,
            text: String,
            isStreaming: Bool = false,
            images: [ChatImage] = [],
            filePaths: [String] = []
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.isStreaming = isStreaming
            self.images = images
            self.filePaths = filePaths
        }
    }

    private struct ModelConfigurationSnapshot: Equatable {
        let providerID: UUID
        let wireProtocol: WireProtocol
        let baseURL: String
        let modelID: String
        let apiKey: String
        let maxOutputTokens: Int
    }

    static let maxImages = 4
    static let maxContextFiles = 5

    let project: Project

    var bubbles: [Bubble] = []
    var input = ""
    var pendingImages: [ChatImage] = []
    var pendingFiles: [ContextFile] = []
    private(set) var isRunning = false
    private(set) var status: String?
    var errorMessage: String?
    private(set) var pendingProposals: [FileProposal] = []
    var isShowingReview = false
    private(set) var hasChanges = false
    private(set) var isCommitting = false
    private(set) var cacheStats = CacheStats()
    var commitMessage = ""
    var isShowingCommitPrompt = false
    var banner: String?

    private let environment: AppEnvironment
    private let session: AgentSession
    private let router = ModelClientRouter()
    private let usesMockModel: Bool
    private let coordinator = ProposalCoordinator()
    private var appliedConfiguration: ModelConfigurationSnapshot?
    private var runTask: Task<Void, Never>?
    private var lastRequest = ""
    private var streamingBubbleID: UUID?
    private var reasoningBubbleID: UUID?
    private var didLoadSession = false

    init(project: Project, environment: AppEnvironment) {
        self.project = project
        self.environment = environment

        let mockClient = MockModelSupport.makeClient()
        self.usesMockModel = mockClient != nil
        if let mockClient {
            router.setClient(mockClient)
        }

        self.session = AgentSession(
            client: router,
            workspace: FileWorkspace(root: project.directory),
            git: project.isGitRepository ? environment.git : nil
        )

        coordinator.onPending = { [weak self] proposals in
            self?.present(proposals)
        }
        coordinator.onCleared = { [weak self] in
            self?.pendingProposals = []
            self?.isShowingReview = false
        }

        _ = applyActiveConfiguration(reportErrors: false)
    }

    private func applyActiveConfiguration(reportErrors: Bool = true) -> Bool {
        guard !usesMockModel else { return true }

        let settings = environment.settings
        guard let provider = settings.activeProvider,
              provider.isEnabled,
              let modelID = provider.effectiveModelID,
              !modelID.isEmpty
        else {
            if reportErrors {
                errorMessage = ModelError.notConfigured.errorDescription
            }
            return false
        }

        let apiKey = settings.apiKey(for: provider.id)
        let snapshot = ModelConfigurationSnapshot(
            providerID: provider.id,
            wireProtocol: provider.wireProtocol,
            baseURL: provider.baseURL,
            modelID: modelID,
            apiKey: apiKey,
            maxOutputTokens: provider.maxOutputTokens
        )

        guard snapshot != appliedConfiguration else { return true }

        do {
            let client = try LLMClientFactory.makeClient(
                provider: provider,
                apiKey: apiKey
            )
            router.setClient(client)
            appliedConfiguration = snapshot
            return true
        } catch {
            if reportErrors {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            return false
        }
    }

    var canCommit: Bool {
        project.isGitRepository
            && hasChanges
            && pendingProposals.isEmpty
            && !isRunning
            && !isCommitting
    }

    var cacheSummary: String? {
        guard cacheStats.hasData else { return nil }
        guard cacheStats.cachedTokens > 0, let hitRate = cacheStats.hitRate else {
            return "Cache –"
        }

        let percent = Int((hitRate * 100).rounded())
        return "Cache \(percent)% · \(Self.tokenLabel(cacheStats.missedTokens)) missed"
    }

    private static func tokenLabel(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    func loadInitialState() async {
        _ = applyActiveConfiguration(reportErrors: false)
        if !didLoadSession {
            didLoadSession = true
            await restoreSession()
        }
        await refreshStatus()
    }

    func addPendingImages(_ images: [ChatImage]) {
        guard !images.isEmpty else { return }
        let remaining = Self.maxImages - pendingImages.count
        guard remaining > 0 else {
            errorMessage = "You can attach up to \(Self.maxImages) images."
            return
        }
        pendingImages.append(contentsOf: images.prefix(remaining))
        if images.count > remaining {
            errorMessage = "You can attach up to \(Self.maxImages) images."
        }
    }

    func removePendingImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
    }

    func addContextFile(_ file: ContextFile) {
        if let index = pendingFiles.firstIndex(where: { $0.path == file.path }) {
            pendingFiles[index] = file
            return
        }
        guard pendingFiles.count < Self.maxContextFiles else {
            errorMessage = "You can reference up to \(Self.maxContextFiles) files."
            return
        }
        pendingFiles.append(file)
    }

    func removeContextFile(path: String) {
        pendingFiles.removeAll { $0.path == path }
    }

    func send() {
        guard !isRunning else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let files = pendingFiles
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else { return }

        errorMessage = nil
        banner = nil
        guard applyActiveConfiguration() else { return }

        input = ""
        pendingImages = []
        pendingFiles = []

        lastRequest = text.isEmpty
            ? (files.isEmpty ? "Image" : files.map(\.path).joined(separator: ", "))
            : text

        bubbles.append(Bubble(
            role: .user,
            text: text,
            images: images,
            filePaths: files.map(\.path)
        ))

        let sessionText = Self.composedText(text, files: files)
        runTask = Task { [weak self] in
            await self?.run(sessionText, images: images)
        }
    }

    private static func composedText(_ text: String, files: [ContextFile]) -> String {
        guard !files.isEmpty else { return text }

        let blocks = files.map { file in
            "<file path=\"\(file.path)\">\n\(file.content)\n</file>"
        }.joined(separator: "\n\n")

        if text.isEmpty {
            return blocks + "\n\nUse the referenced files as context."
        }
        return blocks + "\n\n" + text
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
        pendingImages = []
        pendingFiles = []
        streamingBubbleID = nil
        reasoningBubbleID = nil
        cacheStats = CacheStats()
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

    private func run(_ text: String, images: [ChatImage]) async {
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
                images: images,
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
            var stats = cacheStats
            stats.resetWindow()
            cacheStats = stats
            status = "Thinking…"
            bubbles.append(Bubble(
                role: .tool,
                text: success
                    ? "Context summarized to fit the model window."
                    : "Context summary failed; using truncation."
            ))
        case .retryScheduled(let attempt, let maxAttempts, let delayMilliseconds, let reason):
            status = "Retrying \(attempt)/\(maxAttempts) in \(delayMilliseconds)ms…"
            bubbles.append(Bubble(
                role: .tool,
                text: "Retry \(attempt)/\(maxAttempts): \(reason)"
            ))
        case .assistantResponseRestarted:
            discardPartialResponse()
        case .usage(let usage):
            var stats = cacheStats
            stats.record(usage)
            cacheStats = stats
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

    private func discardPartialResponse() {
        finalizeReasoningBubble()
        while let last = bubbles.last, last.role == .assistant || last.role == .reasoning {
            bubbles.removeLast()
        }
        streamingBubbleID = nil
        reasoningBubbleID = nil
        status = "Thinking…"
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
            return Bubble(
                id: stored.id,
                role: role,
                text: stored.text,
                images: stored.images ?? [],
                filePaths: stored.filePaths ?? []
            )
        }
        cacheStats = snapshot.cacheStats ?? CacheStats()
        lastRequest = bubbles.last(where: { $0.role == .user })?.text ?? ""
        await session.restore(snapshot.restoredMessages)
    }

    private func saveSession() async {
        let history = await session.history
        let storedBubbles = bubbles.map {
            StoredBubble(
                id: $0.id,
                role: $0.role.rawValue,
                text: $0.text,
                images: $0.images.isEmpty ? nil : $0.images,
                filePaths: $0.filePaths.isEmpty ? nil : $0.filePaths
            )
        }

        await environment.sessions.save(
            SessionSnapshot(
                messages: history,
                bubbles: storedBubbles,
                cacheStats: cacheStats
            ),
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
