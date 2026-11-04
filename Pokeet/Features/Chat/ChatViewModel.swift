import Foundation
import Observation
import PokeetCore

struct ContextFile: Sendable, Equatable {
    let path: String
    let content: String
}

/// How a plan ended. A plan without an outcome is still in flight.
enum PlanOutcome: String, Codable, Sendable, Equatable {
    case completed
    case interrupted
}

enum PlanPhase: Sendable, Equatable {
    case reviewing
    case executing
    case finished(PlanOutcome)
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
            case todo
            case notice
            case error
        }

        let id: UUID
        let role: Role
        var text: String
        var isStreaming: Bool
        var images: [ChatImage]
        var filePaths: [String]
        var reasoningDuration: TimeInterval?
        var runDuration: TimeInterval?
        /// Source of a script run, shown when the trace row is expanded.
        var preview: String?
        /// Result text of a script run, shown when the trace row is expanded.
        var output: String?
        /// Running task list shown as a checklist card.
        var todos: [TaskItem]?

        init(
            id: UUID = UUID(),
            role: Role,
            text: String,
            isStreaming: Bool = false,
            images: [ChatImage] = [],
            filePaths: [String] = [],
            reasoningDuration: TimeInterval? = nil,
            runDuration: TimeInterval? = nil,
            preview: String? = nil,
            output: String? = nil,
            todos: [TaskItem]? = nil
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.isStreaming = isStreaming
            self.images = images
            self.filePaths = filePaths
            self.reasoningDuration = reasoningDuration
            self.runDuration = runDuration
            self.preview = preview
            self.output = output
            self.todos = todos
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
    let sessionID: UUID
    private(set) var title: String

    private(set) var bubbles: [Bubble] = []
    private(set) var pager = BubblePager()
    private(set) var isRestoringSession = true
    var input = ""
    var pendingImages: [ChatImage] = []
    var pendingFiles: [ContextFile] = []
    private(set) var isRunning = false
    private(set) var status: String?
    var errorMessage: String?
    private(set) var pendingProposals: [FileProposal] = []
    var isShowingReview = false
    private(set) var pendingAction: ActionRequest?
    var isShowingActionReview = false
    private(set) var hasChanges = false
    private(set) var isCommitting = false
    private(set) var cacheStats = CacheStats()
    var commitMessage = ""
    var isShowingCommitPrompt = false
    var banner: String?
    private(set) var mode: AgentMode
    private var modeSnapshot: AgentMode
    private(set) var pendingPlan: AgentPlan?
    private(set) var currentPlan: AgentPlan?
    private(set) var planIsExecuting = false
    private(set) var planOutcome: PlanOutcome?
    private(set) var appliedChanges: [AppliedChange] = []
    var isShowingPlan = false
    private var lastAssistantText = ""

    var planForReview: AgentPlan? {
        pendingPlan ?? currentPlan
    }

    var planPhase: PlanPhase? {
        guard planForReview != nil else { return nil }
        if planIsExecuting { return .executing }
        if let planOutcome { return .finished(planOutcome) }
        return .reviewing
    }

    /// The strip above the composer is for work in flight; a finished plan belongs to the transcript.
    var showsPlanBar: Bool {
        planForReview != nil && planOutcome == nil
    }

    private let environment: AppEnvironment
    private let session: AgentSession
    private let router = ModelClientRouter()
    private let usesMockModel: Bool
    private let coordinator = ProposalCoordinator()
    private let actionCoordinator = ActionCoordinator()
    private var appliedConfiguration: ModelConfigurationSnapshot?
    private var runTask: Task<Void, Never>?
    private var lastRequest = ""
    private var streamingBubbleID: UUID?
    private var reasoningBubbleID: UUID?
    private var reasoningStartedAt: Date?
    private var runStartedAt: Date?
    private var runningToolCount = 0
    private var toolBubbleIDs: [String: UUID] = [:]
    private var todoBubbleID: UUID?
    private var streamBuffer = StreamBuffer()
    private var streamFlushTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private(set) var streamRevision = 0
    private var didLoadSession = false
    private var needsHistoryRestore = false

    init(project: Project, environment: AppEnvironment, session: SessionMetadata) {
        let initialMode = session.mode ?? environment.settings.defaultAgentMode
        self.project = project
        self.environment = environment
        self.sessionID = session.id
        self.title = session.title
        self.mode = initialMode
        self.modeSnapshot = initialMode

        let mockClient = MockModelSupport.makeClient()
        self.usesMockModel = mockClient != nil
        if let mockClient {
            router.setClient(mockClient)
        }

        self.session = AgentSession(
            client: router,
            workspace: FileWorkspace(root: project.directory),
            git: project.isGitRepository ? environment.git : nil,
            sessionID: sessionID.uuidString,
            tools: ToolRegistry.standard(scriptRuntimes: environment.scripting.names),
            mode: initialMode,
            networkPolicy: NetworkAccessPolicy(
                isEnabled: environment.settings.networkEnabled,
                allowedHosts: Self.parseHosts(environment.settings.networkAllowedHosts)
            ),
            scripting: environment.scripting,
            webSearch: environment.settings.makeWebSearchProvider()
        )

        coordinator.onPending = { [weak self] proposals in
            self?.present(proposals)
        }
        coordinator.onCleared = { [weak self] in
            self?.pendingProposals = []
            self?.isShowingReview = false
        }

        actionCoordinator.onPending = { [weak self] action in
            self?.pendingAction = action
            self?.isShowingActionReview = true
            self?.status = nil
        }
        actionCoordinator.onCleared = { [weak self] in
            self?.pendingAction = nil
            self?.isShowingActionReview = false
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

    private var currentNetworkPolicy: NetworkAccessPolicy {
        NetworkAccessPolicy(
            isEnabled: environment.settings.networkEnabled,
            allowedHosts: Self.parseHosts(environment.settings.networkAllowedHosts)
        )
    }

    private static func parseHosts(_ text: String) -> Set<String> {
        Set(
            text.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    var activeModelLabel: String? {
        guard let provider = environment.settings.activeProvider,
              let modelID = provider.effectiveModelID
        else {
            return nil
        }
        return provider.models.first(where: { $0.id == modelID })?.label ?? modelID
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
        isRestoringSession = false
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

    var visibleBubbles: ArraySlice<Bubble> {
        bubbles[pager.window(total: bubbles.count)]
    }

    var hasOlderBubbles: Bool {
        pager.window(total: bubbles.count).lowerBound > 0
    }

    /// Reveals the previous page and returns the bubble that kept the scroll anchor.
    @discardableResult
    func loadOlderBubbles() -> UUID? {
        let total = bubbles.count
        let window = pager.window(total: total)
        guard !window.isEmpty else { return nil }
        let anchor = bubbles[window].first?.id
        return pager.loadOlder(total: total) ? anchor : nil
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

        // Moving on to a new request retires a plan that already ended.
        if planOutcome != nil {
            currentPlan = nil
            planOutcome = nil
        }

        if bubbles.isEmpty, title == "New chat" {
            title = Self.derivedTitle(text: text, files: files, images: images)
        }

        lastRequest = text.isEmpty
            ? (files.isEmpty ? "Image" : files.map(\.path).joined(separator: ", "))
            : text

        bubbles.append(Bubble(
            role: .user,
            text: text,
            images: images,
            filePaths: files.map(\.path)
        ))
        pager.reset(total: bubbles.count)
        modeSnapshot = mode

        let sessionText = Self.composedText(text, files: files)
        runTask = Task { [weak self] in
            await self?.run(sessionText, images: images)
        }
    }

    private static func derivedTitle(
        text: String,
        files: [ContextFile],
        images: [ChatImage]
    ) -> String {
        if !text.isEmpty {
            return String(text.prefix(60))
        }
        if let file = files.first {
            return "@\((file.path as NSString).lastPathComponent)"
        }
        if !images.isEmpty {
            return "Image"
        }
        return "New chat"
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
        flushStreamNow()
        finalizeReasoningBubble()
        finalizeStreamingAssistantBubble()
        finalizeToolBubbles()
        streamingBubbleID = nil
        cancelStreamFlush()
        pendingProposals = []
        isShowingReview = false
        pendingPlan = nil
        isShowingPlan = false
        if planIsExecuting {
            planIsExecuting = false
            planOutcome = .interrupted
        }
        runningToolCount = 0
        coordinator.cancelPending()
        actionCoordinator.cancelPending()
        pendingAction = nil
        isShowingActionReview = false
        runTask?.cancel()
        scheduleCheckpoint(immediate: true)
    }

    func setMode(_ newMode: AgentMode) {
        guard !isRunning, newMode != mode else { return }
        mode = newMode
        let projectName = project.name
        let sessionID = sessionID
        Task { [weak self] in
            guard let self else { return }
            await self.environment.sessions.setMode(
                projectName: projectName,
                sessionID: sessionID,
                mode: newMode
            )
        }
    }

    func executePlan() {
        guard let plan = pendingPlan ?? currentPlan, !isRunning else { return }
        isShowingPlan = false
        pendingPlan = nil
        currentPlan = plan
        planOutcome = nil
        planIsExecuting = true
        setMode(.auto)
        input = Self.executionPrompt(for: plan)
        send()
    }

    func stayInPlan() {
        isShowingPlan = false
        pendingPlan = nil
    }

    func refinePlan(_ notes: String) {
        guard !isRunning else { return }
        isShowingPlan = false
        pendingPlan = nil
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        input = trimmed.isEmpty
            ? "Refine the plan."
            : "Refine the plan with this feedback:\n\n\(trimmed)"
        send()
    }

    func showPlan() {
        guard planForReview != nil else { return }
        isShowingPlan = true
    }

    private static func executionPrompt(for plan: AgentPlan) -> String {
        guard !plan.steps.isEmpty else {
            return "Execute the plan from the previous message."
        }

        var lines = ["Execute this plan.", "", "Plan: \(plan.title)"]
        if let summary = plan.summary, !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        for (index, step) in plan.steps.enumerated() {
            var line = "\(index + 1). \(step.title)"
            if !step.files.isEmpty {
                line += " (files: \(step.files.joined(separator: ", ")))"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("After completing step n, output [DONE:n] on its own line.")
        return lines.joined(separator: "\n")
    }

    func resolve(_ decisions: [ProposalDecision]) {
        pendingProposals = []
        isShowingReview = false
        coordinator.resolve(decisions)
    }

    func resolveAction(allow: Bool) {
        actionCoordinator.resolve(allow ? .allowed : .denied)
    }

    func clearErrorMessage() {
        errorMessage = nil
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
            bubbles.append(Bubble(role: .notice, text: "Committed \(hash.prefix(8))."))

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
        actionCoordinator.reset()
        reasoningBubbleID = nil
        reasoningStartedAt = nil
        runStartedAt = Date()
        isRunning = true
        errorMessage = nil
        status = "Thinking…"
        lastAssistantText = ""
        pendingPlan = nil
        runningToolCount = 0
        toolBubbleIDs.removeAll()
        cancelStreamFlush()
        checkpointTask?.cancel()
        checkpointTask = nil
        defer {
            flushStreamNow()
            finalizeStreamingAssistantBubble()
            finalizeReasoningBubble()
            finalizeToolBubbles()
            isRunning = false
            status = nil
            runTask = nil
            streamingBubbleID = nil
        }

        await environment.sessions.ensureSession(
            projectName: project.name,
            sessionID: sessionID,
            title: title,
            mode: modeSnapshot
        )

        if needsHistoryRestore {
            guard let history = await environment.sessions.loadMessages(
                projectName: project.name,
                sessionID: sessionID
            ) else {
                errorMessage = "Could not load this session's history."
                return
            }
            await session.restore(history)
            if let todos = bubbles.last(where: { $0.role == .todo })?.todos, !todos.isEmpty {
                await session.setTasks(todos)
            }
            needsHistoryRestore = false
        }

        do {
            await session.setMode(modeSnapshot)
            await session.setNetworkPolicy(currentNetworkPolicy)
            try await session.send(
                text,
                images: images,
                approval: { [coordinator] proposals in
                    await coordinator.request(proposals)
                },
                actionApproval: { [actionCoordinator] action in
                    await actionCoordinator.request(action)
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

        recordRunDuration()

        if planIsExecuting, let plan = currentPlan {
            finishPlan(plan)
        }

        await saveSession()
        await refreshStatus()

        if modeSnapshot == .plan, pendingPlan != nil {
            isShowingPlan = true
        }
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
                role: .notice,
                text: success
                    ? "Context summarized to fit the model window."
                    : "Context summary failed; using truncation."
            ))
        case .retryScheduled(let attempt, let maxAttempts, let delayMilliseconds, let reason):
            status = "Retrying \(attempt)/\(maxAttempts) in \(delayMilliseconds)ms…"
            bubbles.append(Bubble(
                role: .notice,
                text: "Retry \(attempt)/\(maxAttempts): \(reason)"
            ))
        case .assistantResponseRestarted:
            discardPartialResponse()
        case .usage(let usage):
            var stats = cacheStats
            stats.record(usage)
            cacheStats = stats
        case .assistantReasoningDelta(let delta):
            if reasoningStartedAt == nil {
                reasoningStartedAt = Date()
            }
            streamBuffer.appendReasoning(delta)
            scheduleStreamFlush()
        case .assistantTextDelta(let delta):
            consumePlanProgress(from: delta)
            streamBuffer.appendAssistant(PlanProgress.parse(delta).text)
            scheduleStreamFlush()
        case .assistantMessage(let text):
            flushReasoningBuffer()
            streamFlushTask?.cancel()
            streamFlushTask = nil
            streamBuffer.clear()
            consumePlanProgress(from: text)
            let parsed = PlanProgress.parse(text)
            finalizeAssistantMessage(parsed.text)
            lastAssistantText = parsed.text
            status = "Thinking…"
            scheduleCheckpoint()
        case .toolStarted(let name, let callID, let detail, let preview):
            flushStreamNow()
            finalizeReasoningBubble()
            runningToolCount += 1
            status = "Running \(name)…"
            let label = detail.map { "\(name) · \($0)" } ?? name
            let bubble = Bubble(role: .tool, text: label, isStreaming: true, preview: preview)
            bubbles.append(bubble)
            toolBubbleIDs[callID] = bubble.id
            scheduleCheckpoint()
        case .toolFinished(let name, let callID, let summary):
            runningToolCount = max(0, runningToolCount - 1)
            if runningToolCount == 0 {
                status = "Thinking…"
            }
            // The id stays until the next run so a later toolImages event can find the row.
            if let id = toolBubbleIDs[callID],
               let index = bubbleIndex(of: id) {
                bubbles[index].isStreaming = false
                let line = summary
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                    .first.map(String.init) ?? summary
                if name == RunScriptTool.toolName {
                    // Replace the "N lines" placeholder with the outcome line.
                    bubbles[index].text = "\(name) · \(String(line.prefix(120)))"
                    // The row already shows the outcome, so do not repeat it in the details.
                    let body = summary.hasPrefix(line)
                        ? String(summary.dropFirst(line.count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        : summary
                    bubbles[index].output = body.isEmpty ? nil : body
                } else if name == HTTPRequestTool.toolName, summary.hasPrefix("HTTP ") {
                    bubbles[index].text += " · \(String(line.prefix(120)))"
                } else if summary.hasPrefix("Error:") {
                    bubbles[index].text += "\n\(String(line.prefix(160)))"
                }
            }
            scheduleCheckpoint()
        case .toolImages(let callID, let images):
            if let id = toolBubbleIDs[callID], let index = bubbleIndex(of: id) {
                bubbles[index].images = images
                scheduleCheckpoint()
            }
        case .todosUpdated(let items):
            updateTodoBubble(items)
            scheduleCheckpoint()
        case .proposalsPending(let proposals):
            present(proposals)
        case .actionPending:
            status = "Waiting for approval…"
        case .changesApplied(let changes):
            appliedChanges.append(contentsOf: changes)
            if appliedChanges.count > 200 {
                appliedChanges.removeFirst(appliedChanges.count - 200)
            }
            guard modeSnapshot == .auto || modeSnapshot == .bypass else { break }
            for change in changes where change.didWrite {
                bubbles.append(Bubble(role: .notice, text: change.message))
            }
            scheduleCheckpoint(immediate: true)
        case .planSubmitted(let plan):
            pendingPlan = plan
            currentPlan = plan
            planOutcome = nil
            planIsExecuting = false
        case .finished:
            flushStreamNow()
            finalizeReasoningBubble()
            finalizeStreamingAssistantBubble()
            finalizeToolBubbles()
            streamingBubbleID = nil
            runningToolCount = 0
            status = nil
            if modeSnapshot == .plan, pendingPlan == nil {
                let text = lastAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let plan = AgentPlan.fallback(from: text)
                    pendingPlan = plan
                    currentPlan = plan
                    planOutcome = nil
                    planIsExecuting = false
                }
            }
        case .failed(let message):
            flushStreamNow()
            finalizeReasoningBubble()
            finalizeStreamingAssistantBubble()
            finalizeToolBubbles()
            streamingBubbleID = nil
            runningToolCount = 0
            errorMessage = message
            status = nil
        }
    }

    private func finishPlan(_ plan: AgentPlan) {
        planIsExecuting = false
        planOutcome = plan.isComplete ? .completed : .interrupted
        // Leave a record where the work happened; the agent's own checklist already does that.
        if todoBubbleID == nil, !plan.steps.isEmpty {
            var bubble = Bubble(role: .todo, text: TaskListFormatter.statusSummary(plan.steps))
            bubble.todos = plan.steps
            bubbles.append(bubble)
            pager.reset(total: bubbles.count)
            todoBubbleID = bubble.id
        }
    }

    /// A single checklist bubble that is updated in place rather than appended per call.
    private func updateTodoBubble(_ items: [TaskItem]) {
        if let id = todoBubbleID, let index = bubbleIndex(of: id) {
            if items.isEmpty {
                bubbles.remove(at: index)
                todoBubbleID = nil
                pager.reset(total: bubbles.count)
            } else {
                bubbles[index].todos = items
                bubbles[index].text = TaskListFormatter.statusSummary(items)
            }
            return
        }
        guard !items.isEmpty else { return }

        var bubble = Bubble(role: .todo, text: TaskListFormatter.statusSummary(items))
        bubble.todos = items
        bubbles.append(bubble)
        todoBubbleID = bubble.id
        pager.reset(total: bubbles.count)
    }

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: StreamBuffer.flushInterval)
            guard !Task.isCancelled, let self else { return }
            self.streamFlushTask = nil
            self.flushStreamBuffer()
            if !self.streamBuffer.isEmpty {
                self.scheduleStreamFlush()
            }
        }
    }

    private func flushStreamBuffer() {
        let reasoning = streamBuffer.drainReasoning()
        let assistant = streamBuffer.drainAssistant()
        guard !reasoning.isEmpty || !assistant.isEmpty else { return }

        if !reasoning.isEmpty {
            appendReasoningDelta(reasoning)
        }
        if !assistant.isEmpty {
            finalizeReasoningBubble()
            appendAssistantDelta(assistant)
        }
        if runningToolCount == 0 {
            status = nil
        }
        streamRevision &+= 1
    }

    private func flushReasoningBuffer() {
        let reasoning = streamBuffer.drainReasoning()
        if !reasoning.isEmpty {
            appendReasoningDelta(reasoning)
        }
    }

    private func flushStreamNow() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        flushStreamBuffer()
    }

    private func cancelStreamFlush() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        streamBuffer.clear()
    }

    func checkpointNow() {
        scheduleCheckpoint(immediate: true)
    }

    private func scheduleCheckpoint(immediate: Bool = false) {
        guard !bubbles.isEmpty else { return }
        checkpointTask?.cancel()

        if immediate {
            checkpointTask = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushStreamNow()
                await self.saveCheckpoint()
            }
            return
        }

        checkpointTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.checkpointTask = nil
            self.flushStreamNow()
            await self.saveCheckpoint()
        }
    }

    private func saveCheckpoint() async {
        guard !bubbles.isEmpty else { return }
        await environment.sessions.saveCheckpoint(
            makeSessionSnapshot(),
            projectName: project.name,
            sessionID: sessionID
        )
    }

    private func makeSessionSnapshot() -> SessionSnapshot {
        let sessionBubbles = bubbles.map {
            SessionBubble(
                id: $0.id,
                role: $0.role.rawValue,
                text: $0.text,
                images: $0.images,
                filePaths: $0.filePaths,
                reasoningDuration: $0.reasoningDuration,
                runDuration: $0.runDuration,
                preview: $0.preview,
                output: $0.output,
                todos: $0.todos
            )
        }
        return SessionSnapshot(
            bubbles: sessionBubbles,
            cacheStats: cacheStats,
            plan: currentPlan ?? pendingPlan,
            planIsExecuting: planIsExecuting,
            planOutcome: planOutcome?.rawValue,
            appliedChanges: appliedChanges.isEmpty ? nil : appliedChanges
        )
    }

    private func finalizeStreamingAssistantBubble() {
        guard let id = streamingBubbleID, let index = bubbleIndex(of: id) else { return }
        bubbles[index].isStreaming = false
        streamingBubbleID = nil
    }

    private func finalizeToolBubbles() {
        for index in bubbles.indices where bubbles[index].role == .tool && bubbles[index].isStreaming {
            bubbles[index].isStreaming = false
        }
        toolBubbleIDs.removeAll()
    }

    private func recordRunDuration() {
        guard let start = runStartedAt else { return }
        runStartedAt = nil
        guard let lastUser = bubbles.lastIndex(where: { $0.role == .user }),
              lastUser + 1 < bubbles.endIndex
        else { return }
        bubbles[bubbles.endIndex - 1].runDuration = Date().timeIntervalSince(start)
    }

    private func bubbleIndex(of id: UUID) -> Int? {
        if bubbles.last?.id == id {
            return bubbles.index(before: bubbles.endIndex)
        }
        return bubbles.firstIndex(where: { $0.id == id })
    }

    private func consumePlanProgress(from text: String) {
        guard planIsExecuting, var plan = currentPlan else { return }
        let parsed = PlanProgress.parse(text)
        guard !parsed.completedSteps.isEmpty else { return }

        var changed = false
        for stepNumber in parsed.completedSteps where plan.steps.indices.contains(stepNumber - 1) {
            if plan.steps[stepNumber - 1].status != .done {
                plan.steps[stepNumber - 1].status = .done
                changed = true
            }
        }
        if changed {
            currentPlan = plan
        }
    }

    private func discardPartialResponse() {
        cancelStreamFlush()
        finalizeReasoningBubble()
        finalizeToolBubbles()
        while let last = bubbles.last, last.role == .assistant || last.role == .reasoning {
            bubbles.removeLast()
        }
        pager.clamp(total: bubbles.count)
        streamingBubbleID = nil
        reasoningBubbleID = nil
        status = "Thinking…"
    }

    private func appendReasoningDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        if reasoningStartedAt == nil {
            reasoningStartedAt = Date()
        }

        if let id = reasoningBubbleID, let index = bubbleIndex(of: id) {
            bubbles[index].text += delta
            return
        }

        var bubble = Bubble(role: .reasoning, text: delta)
        bubble.isStreaming = true
        bubbles.append(bubble)
        reasoningBubbleID = bubble.id
    }

    private func finalizeReasoningBubble() {
        flushReasoningBuffer()
        let duration = reasoningStartedAt.map { Date().timeIntervalSince($0) }
        reasoningStartedAt = nil
        guard let id = reasoningBubbleID else { return }
        reasoningBubbleID = nil

        guard let index = bubbleIndex(of: id) else {
            return
        }

        if let duration {
            bubbles[index].reasoningDuration = duration
        }
        bubbles[index].isStreaming = false
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        if let id = streamingBubbleID, let index = bubbleIndex(of: id) {
            bubbles[index].text += delta
            bubbles[index].isStreaming = true
            return
        }

        let bubble = Bubble(role: .assistant, text: delta, isStreaming: true)
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
        guard let index = bubbleIndex(of: id) else {
            return
        }

        if text.isEmpty {
            bubbles.remove(at: index)
            pager.clamp(total: bubbles.count)
        } else {
            bubbles[index].text = text
            bubbles[index].isStreaming = false
        }
    }

    private func present(_ proposals: [FileProposal]) {
        pendingProposals = proposals
        isShowingReview = true
        status = nil
    }

    private func restoreSession() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PokeetSyntheticHistory") {
            bubbles = Self.makeSyntheticHistory()
            pager.reset(total: bubbles.count)
            return
        }
        #endif

        guard let snapshot = await environment.sessions.load(
            projectName: project.name,
            sessionID: sessionID
        ) else {
            if await environment.sessions.hasLegacySnapshot(
                projectName: project.name,
                sessionID: sessionID
            ) {
                errorMessage = "This session uses an older storage format and can't be opened."
            }
            return
        }

        bubbles = snapshot.bubbles.compactMap { stored in
            guard let role = Bubble.Role(rawValue: stored.role) else { return nil }
            return Bubble(
                id: stored.id,
                role: role,
                text: stored.text,
                images: stored.images,
                filePaths: stored.filePaths,
                reasoningDuration: stored.reasoningDuration,
                runDuration: stored.runDuration,
                preview: stored.preview,
                output: stored.output,
                todos: stored.todos
            )
        }
        todoBubbleID = bubbles.last(where: { $0.role == .todo })?.id
        pager.reset(total: bubbles.count)
        cacheStats = snapshot.cacheStats ?? CacheStats()
        lastRequest = bubbles.last(where: { $0.role == .user })?.text ?? ""
        currentPlan = snapshot.plan
        planIsExecuting = snapshot.planIsExecuting ?? false
        planOutcome = snapshot.planOutcome.flatMap(PlanOutcome.init(rawValue:))
        appliedChanges = snapshot.appliedChanges ?? []
        pendingPlan = nil
        needsHistoryRestore = true
    }

    private func saveSession() async {
        flushStreamNow()
        checkpointTask?.cancel()
        checkpointTask = nil
        let history = await session.history

        await environment.sessions.save(
            makeSessionSnapshot(),
            messages: history,
            projectName: project.name,
            sessionID: sessionID,
            title: title,
            mode: mode
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

    #if DEBUG
    private static func makeSyntheticHistory(count: Int = 400) -> [Bubble] {
        (0..<count).map { index in
            let role: Bubble.Role = index.isMultiple(of: 2) ? .user : .assistant
            let text = String(
                repeating: "Synthetic **markdown** row \(index) with enough text to fill a line.\n\n",
                count: 4
            )
            return Bubble(role: role, text: text)
        }
    }
    #endif
}
