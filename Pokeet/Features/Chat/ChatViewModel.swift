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

/// Draft and presentation state for one chat screen.
///
/// The run itself lives in `SessionRuntime`, which the app owns: this model only carries what
/// belongs to the screen (composer draft, attached files, open sheets) and forwards everything
/// else. Leaving the screen detaches, it does not cancel.
@MainActor
@Observable
final class ChatViewModel {
    typealias Bubble = SessionRuntime.Bubble
    typealias PendingEdit = SessionRuntime.PendingEdit

    static let maxImages = 4
    static let maxContextFiles = 5

    let project: Project
    let sessionID: UUID
    let runtime: SessionRuntime

    var input = ""

    /// Skills the session can load, offered while the composer holds a `/skill` command.
    var skillSuggestions: [Skill] {
        guard !isRunning, let query = SkillCommand.query(in: input) else { return [] }
        return SkillCommand.matching(runtime.loadedSkills, query: query)
    }

    func insertSkill(_ skill: Skill) {
        input = SkillCommand.apply(skill, to: input)
    }
    var pendingImages: [ChatImage] = []
    var pendingFiles: [ContextFile] = []
    var commitMessage = ""
    var isShowingCommitPrompt = false

    private let environment: AppEnvironment
    private var attachment: SessionRuntime.Attachment?
    private(set) var pendingEdit: PendingEdit?

    init(project: Project, environment: AppEnvironment, session: SessionMetadata) {
        self.project = project
        self.environment = environment
        self.sessionID = session.id
        self.runtime = environment.runs.runtime(
            for: project,
            session: session,
            environment: environment
        )
    }

    // MARK: - Runtime state, forwarded

    var title: String { runtime.title }
    var bubbles: [Bubble] { runtime.bubbles }
    var visibleBubbles: ArraySlice<Bubble> { runtime.visibleBubbles }
    var hasOlderBubbles: Bool { runtime.hasOlderBubbles }
    var isRestoringSession: Bool { runtime.isRestoringSession }
    var isRunning: Bool { runtime.isRunning }
    var status: String? { runtime.status }
    var pendingProposals: [FileProposal] { runtime.pendingProposals }
    var pendingAction: ActionRequest? { runtime.pendingAction }
    var hasChanges: Bool { runtime.hasChanges }
    var isCommitting: Bool { runtime.isCommitting }
    var cacheStats: CacheStats { runtime.cacheStats }
    var cacheSummary: String? { runtime.cacheSummary }
    var mode: AgentMode { runtime.mode }
    var pendingPlan: AgentPlan? { runtime.pendingPlan }
    var currentPlan: AgentPlan? { runtime.currentPlan }
    var planIsExecuting: Bool { runtime.planIsExecuting }
    var planOutcome: PlanOutcome? { runtime.planOutcome }
    var planForReview: AgentPlan? { runtime.planForReview }
    var planPhase: PlanPhase? { runtime.planPhase }
    var showsPlanBar: Bool { runtime.showsPlanBar }
    var appliedChanges: [AppliedChange] { runtime.appliedChanges }
    var streamRevision: Int { runtime.streamRevision }
    var canCommit: Bool { runtime.canCommit }
    var activeModelLabel: String? { runtime.activeModelLabel }
    var needsContinuation: Bool { runtime.needsContinuation }

    var errorMessage: String? {
        get { runtime.errorMessage }
        set { runtime.errorMessage = newValue }
    }

    var banner: String? {
        get { runtime.banner }
        set { runtime.banner = newValue }
    }

    var isShowingReview: Bool {
        get { runtime.isShowingReview }
        set { runtime.isShowingReview = newValue }
    }

    var isShowingActionReview: Bool {
        get { runtime.isShowingActionReview }
        set { runtime.isShowingActionReview = newValue }
    }

    var isShowingPlan: Bool {
        get { runtime.isShowingPlan }
        set { runtime.isShowingPlan = newValue }
    }

    // MARK: - Lifecycle

    func attach() {
        guard attachment == nil else { return }
        attachment = runtime.attach()
    }

    func detach() {
        guard let attachment else { return }
        self.attachment = nil
        runtime.detach(attachment)
    }

    func loadInitialState() async {
        await runtime.loadInitialState()
    }

    func checkpointNow() {
        runtime.checkpointNow()
    }

    // MARK: - Composer

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

    /// Puts a sent message back in the composer. Nothing is removed until `send()` runs,
    /// so backing out of an edit costs nothing.
    func edit(_ bubble: Bubble) {
        guard !runtime.isRunning, bubble.role == .user,
              let index = runtime.bubbles.firstIndex(where: { $0.id == bubble.id })
        else { return }

        pendingEdit = PendingEdit(
            bubbleID: bubble.id,
            ordinal: runtime.bubbles[..<index].count { $0.role == .user }
        )
        input = bubble.text
        pendingImages = bubble.images
        let workspace = FileWorkspace(root: project.directory)
        pendingFiles = bubble.filePaths.compactMap { path in
            guard let content = try? workspace.read(path, maxBytes: 200_000) else { return nil }
            return ContextFile(path: path, content: content)
        }
    }

    func send() {
        guard !runtime.isRunning else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let files = pendingFiles
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else { return }

        let sent = runtime.send(
            text: text,
            images: images,
            files: files,
            replacing: pendingEdit
        )
        guard sent else { return }

        input = ""
        pendingImages = []
        pendingFiles = []
        pendingEdit = nil
    }

    func cancelRun() {
        runtime.stop()
    }

    func resume() {
        guard runtime.resume() else { return }
        checkpointNow()
    }

    func dismissContinuation() {
        runtime.dismissContinuation()
    }

    @discardableResult
    func loadOlderBubbles() -> UUID? {
        runtime.loadOlderBubbles()
    }

    // MARK: - Plans

    func setMode(_ newMode: AgentMode) {
        runtime.setMode(newMode)
    }

    func executePlan() {
        runtime.executePlan()
    }

    func stayInPlan() {
        runtime.stayInPlan()
    }

    func refinePlan(_ notes: String) {
        runtime.refinePlan(notes)
    }

    func showPlan() {
        runtime.showPlan()
    }

    // MARK: - Approvals

    func resolve(_ decisions: [ProposalDecision]) {
        runtime.resolve(decisions)
    }

    func resolveAction(allow: Bool) {
        runtime.resolveAction(allow: allow)
    }

    // MARK: - Notices

    func clearErrorMessage() {
        runtime.clearErrorMessage()
    }

    func dismissBanner() {
        runtime.dismissBanner()
    }

    // MARK: - Commit

    func prepareCommit() {
        guard runtime.canCommit else { return }
        commitMessage = "Pokeet: \(runtime.suggestedCommitMessage)"
        isShowingCommitPrompt = true
    }

    func commitAndPush() async {
        await runtime.commitAndPush(
            message: commitMessage.isEmpty ? "Pokeet changes" : commitMessage
        )
    }
}
