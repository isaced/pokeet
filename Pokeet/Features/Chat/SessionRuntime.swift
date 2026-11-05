import Foundation
import Observation
import PokeetCore
import UIKit

/// The agent run for one conversation, owned by `AgentRunRegistry` rather than by a screen.
///
/// A `ChatView` can come and go: the run keeps streaming into `bubbles`, keeps writing
/// checkpoints, and re-renders wherever a view attaches again. Only `stop()` cancels it.
@MainActor
@Observable
final class SessionRuntime {
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

    /// A message waiting to be replaced: its text goes back to the composer, and the turn
    /// it came from is only cut when the replacement is actually sent.
    struct PendingEdit: Sendable, Equatable {
        let bubbleID: UUID
        let ordinal: Int
    }

    /// Handed out by `attach()` so a departing view releases its claim without stopping work.
    struct Attachment: Hashable, Sendable {
        let id: UUID

        init() {
            id = UUID()
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

    let project: Project
    let sessionID: UUID
    private(set) var title: String

    private(set) var bubbles: [Bubble] = []
    private(set) var pager = BubblePager()
    private(set) var isRestoringSession = true
    private(set) var isRunning = false
    private(set) var status: String?
    var errorMessage: String?
    var banner: String?
    private(set) var pendingProposals: [FileProposal] = []
    var isShowingReview = false
    private(set) var pendingAction: ActionRequest?
    var isShowingActionReview = false
    private(set) var hasChanges = false
    private(set) var isCommitting = false
    private(set) var cacheStats = CacheStats()
    private(set) var mode: AgentMode
    private var modeSnapshot: AgentMode
    private(set) var pendingPlan: AgentPlan?
    private(set) var currentPlan: AgentPlan?
    private(set) var planIsExecuting = false
    private(set) var planOutcome: PlanOutcome?
    private(set) var appliedChanges: [AppliedChange] = []
    var isShowingPlan = false
    /// True when the process died mid-run, as opposed to the user pressing Stop.
    private(set) var needsContinuation = false
    private(set) var streamRevision = 0

    // The environment owns the registry that owns this runtime, so a strong reference here
    // would just keep the whole graph alive for the life of the process.
    private unowned let environment: AppEnvironment
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
    private var didLoadSession = false
    private var needsHistoryRestore = false
    private var attachments: Set<Attachment> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastAssistantText = ""
    private(set) var lastActivity = Date()

    init(
        project: Project,
        session: SessionMetadata,
        environment: AppEnvironment,
        client: (any ModelClient)? = nil
    ) {
        let initialMode = session.mode ?? environment.settings.defaultAgentMode
        self.project = project
        self.environment = environment
        self.sessionID = session.id
        self.title = session.title
        self.mode = initialMode
        self.modeSnapshot = initialMode

        let fallback = client == nil ? MockModelSupport.makeClient() : nil
        self.usesMockModel = client != nil || fallback != nil
        if let supplied = client ?? fallback {
            router.setClient(supplied)
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
            webSearch: environment.settings.makeWebSearchProvider(),
            skills: SkillLocations(
                projectRoot: project.directory,
                userSkillsDirectory: environment.skillsDirectory
            )
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
            self?.notifyApprovalNeeded("A network action is waiting for your approval.")
        }
        actionCoordinator.onCleared = { [weak self] in
            self?.pendingAction = nil
            self?.isShowingActionReview = false
        }

        _ = applyActiveConfiguration(reportErrors: false)
    }

    // MARK: - Observation

    /// Views call this while they are on screen; the registry only releases runtimes nobody
    /// is watching.
    func attach() -> Attachment {
        let attachment = Attachment()
        attachments.insert(attachment)
        touch()
        return attachment
    }

    func detach(_ attachment: Attachment) {
        attachments.remove(attachment)
        touch()
        // Persist the visible transcript now: the next attach may be after a crash.
        checkpointNow()
    }

    var isDetached: Bool {
        attachments.isEmpty
    }

    private func touch() {
        lastActivity = Date()
    }

    // MARK: - Configuration

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

    // MARK: - Derived state

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

    var isAwaitingApproval: Bool {
        !pendingProposals.isEmpty || pendingAction != nil
    }

    /// One line for the session list, where the run is visible without opening it.
    var activityLabel: String? {
        if isRunning {
            return status ?? "Working…"
        }
        if isAwaitingApproval {
            return "Waiting for you"
        }
        if needsContinuation {
            return "Interrupted"
        }
        return nil
    }

    var suggestedCommitMessage: String {
        lastRequest.isEmpty ? "Pokeet changes" : String(lastRequest.prefix(60))
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

    var visibleBubbles: ArraySlice<Bubble> {
        bubbles[pager.window(total: bubbles.count)]
    }

    var hasOlderBubbles: Bool {
        pager.window(total: bubbles.count).lowerBound > 0
    }

    // MARK: - Lifecycle

    func loadInitialState() async {
        if !didLoadSession {
            didLoadSession = true
            await restoreSession()
        }
        isRestoringSession = false
        await refreshStatus()
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

    // MARK: - Sending

    @discardableResult
    func send(
        text: String,
        images: [ChatImage] = [],
        files: [ContextFile] = [],
        replacing pending: PendingEdit? = nil
    ) -> Bool {
        guard !isRunning else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty || !files.isEmpty else { return false }

        errorMessage = nil
        banner = nil
        guard applyActiveConfiguration() else { return false }

        needsContinuation = false

        // Moving on to a new request retires a plan that already ended.
        if planOutcome != nil {
            currentPlan = nil
            planOutcome = nil
        }

        if bubbles.isEmpty, title == "New chat" {
            title = Self.derivedTitle(text: trimmed, files: files, images: images)
        }

        lastRequest = trimmed.isEmpty
            ? (files.isEmpty ? "Image" : files.map(\.path).joined(separator: ", "))
            : trimmed

        modeSnapshot = mode
        isRunning = true
        status = "Thinking…"
        touch()

        let sessionText = Self.composedText(trimmed, files: files)
        // Strong self: the registry must not be able to drop a live run, and `run` clears
        // `runTask` on its way out, which breaks the cycle.
        runTask = Task { [self] in
            await beginRun(
                sessionText,
                text: trimmed,
                images: images,
                files: files,
                replacing: pending
            )
        }
        return true
    }

    /// Re-opens a turn the process cut short. The history already holds the user message and
    /// whatever the agent managed to say, so a nudge is enough to pick the thread back up.
    @discardableResult
    func resume() -> Bool {
        guard !isRunning, needsContinuation else { return false }
        return send(text: Self.continuationPrompt)
    }

    func dismissContinuation() {
        needsContinuation = false
        checkpointNow()
    }

    private static let continuationPrompt = "Continue from where you stopped."

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
        send(text: Self.executionPrompt(for: plan))
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
        send(text: trimmed.isEmpty
            ? "Refine the plan."
            : "Refine the plan with this feedback:\n\n\(trimmed)")
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

    func stop() {
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
        needsContinuation = false
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

    func commitAndPush(message: String) async {
        guard canCommit else { return }

        isCommitting = true
        banner = nil
        errorMessage = nil
        defer { isCommitting = false }

        do {
            let hash = try await environment.git.commitAll(
                at: project.directory,
                message: message.isEmpty ? "Pokeet changes" : message,
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

    private func beginRun(
        _ sessionText: String,
        text: String,
        images: [ChatImage],
        files: [ContextFile],
        replacing pending: PendingEdit?
    ) async {
        if let pending, await ensureHistoryRestored(),
           await session.rewind(toUserMessage: pending.ordinal),
           let index = bubbles.firstIndex(where: { $0.id == pending.bubbleID }) {
            bubbles.removeSubrange(index...)
            pager.reset(total: bubbles.count)
        }

        bubbles.append(Bubble(
            role: .user,
            text: text,
            images: images,
            filePaths: files.map(\.path)
        ))
        pager.reset(total: bubbles.count)
        touch()

        await run(sessionText, images: images)
    }

    private func run(_ text: String, images: [ChatImage]) async {
        coordinator.reset()
        actionCoordinator.reset()
        reasoningBubbleID = nil
        reasoningStartedAt = nil
        runStartedAt = Date()
        errorMessage = nil
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
            endBackgroundTask()
            touch()
        }

        await environment.sessions.ensureSession(
            projectName: project.name,
            sessionID: sessionID,
            title: title,
            mode: modeSnapshot
        )
        // Write the turn down before the first token: if the process dies at any point after
        // this, the next launch knows the session was interrupted rather than finished.
        scheduleCheckpoint(immediate: true)

        guard await ensureHistoryRestored() else { return }

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

        needsContinuation = false
        // The turn is over: the next cold start must not offer to continue it.
        await saveSession(runInFlight: false)
        await refreshStatus()

        if modeSnapshot == .plan, pendingPlan != nil {
            isShowingPlan = true
        }
    }

    // MARK: - Agent events

    private func handle(_ event: AgentEvent) {
        touch()
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
            if isDetached {
                notifyApprovalNeeded("The run stopped: \(message)")
            }
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

    // MARK: - Streaming

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

    // MARK: - Checkpoints

    func checkpointNow() {
        scheduleCheckpoint(immediate: true)
    }

    private func scheduleCheckpoint(immediate: Bool = false) {
        guard !bubbles.isEmpty else { return }

        if immediate {
            checkpointTask?.cancel()
            checkpointTask = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushStreamNow()
                await self.saveCheckpoint()
            }
            return
        }

        // A pending write is good enough: cancelling and restarting on every event would
        // starve the timer for as long as the run keeps streaming, and a busy run is exactly
        // the one worth recovering.
        guard checkpointTask == nil else { return }

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

    private func makeSessionSnapshot(runInFlight: Bool? = nil) -> SessionSnapshot {
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
            appliedChanges: appliedChanges.isEmpty ? nil : appliedChanges,
            runInFlight: runInFlight ?? isRunning
        )
    }

    // MARK: - Bubble bookkeeping

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
        notifyApprovalNeeded(
            proposals.count == 1
                ? "\(proposals[0].path) is waiting for your review."
                : "\(proposals.count) changes are waiting for your review."
        )
    }

    // MARK: - Attention

    /// A run that needs a human and nobody is looking at it: say so through the notification
    /// centre, since the app has no server to push from.
    private func notifyApprovalNeeded(_ body: String) {
        guard isDetached else { return }
        environment.notifier.postApproval(
            project: project,
            sessionID: sessionID,
            title: title,
            body: body
        )
    }

    // MARK: - Background execution

    /// iOS gives a little room after the app leaves the screen; without this the process is
    /// suspended mid-turn and the stream dies with it.
    func applicationDidEnterBackground() {
        guard isRunning else { return }
        beginBackgroundTask()
    }

    func applicationDidBecomeActive() {
        endBackgroundTask()
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Pokeet agent run"
        ) { [weak self] in
            // UIKit calls this on the main thread; hop synchronously so the checkpoint that
            // saves the transcript is scheduled before the process is frozen.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkpointNow()
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Persistence

    /// The transcript is loaded from the snapshot; the model's message history is
    /// restored on first use, which is also what `rewind` needs before it can find a
    /// user message to cut back to.
    private func ensureHistoryRestored() async -> Bool {
        guard needsHistoryRestore else { return true }
        guard let history = await environment.sessions.loadMessages(
            projectName: project.name,
            sessionID: sessionID
        ) else {
            errorMessage = "Could not load this session's history."
            return false
        }
        await session.restore(history)
        // Older builds could leave a tool round unanswered; a provider would reject it.
        await session.repairHistory()
        if let todos = bubbles.last(where: { $0.role == .todo })?.todos, !todos.isEmpty {
            await session.setTasks(todos)
        }
        needsHistoryRestore = false
        return true
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
        // The header only says `true` while a run is writing it, so a cold start that finds it
        // set is looking at a process that died mid-turn.
        needsContinuation = snapshot.runInFlight == true
    }

    private func saveSession(runInFlight: Bool? = nil) async {
        flushStreamNow()
        checkpointTask?.cancel()
        checkpointTask = nil
        let history = await session.history

        await environment.sessions.save(
            makeSessionSnapshot(runInFlight: runInFlight),
            messages: history,
            projectName: project.name,
            sessionID: sessionID,
            title: title,
            mode: mode
        )
    }

    /// Used when the registry drops an idle runtime: the next attach starts from disk.
    func saveBeforeRelease() async {
        guard !bubbles.isEmpty else { return }
        await saveSession(runInFlight: isRunning)
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
