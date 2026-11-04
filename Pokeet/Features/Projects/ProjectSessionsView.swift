import Observation
import SwiftUI

@MainActor
@Observable
final class SessionsListModel {
    let project: Project
    let store: SessionStore

    private(set) var sessions: [SessionMetadata] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(project: Project, store: SessionStore) {
        self.project = project
        self.store = store
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        sessions = await store.list(projectName: project.name)
    }

    func rename(_ session: SessionMetadata, to title: String) async {
        _ = await store.rename(
            projectName: project.name,
            sessionID: session.id,
            title: title
        )
        await load()
    }

    func delete(_ session: SessionMetadata) async {
        await store.delete(projectName: project.name, sessionID: session.id)
        await load()
    }
}

struct ProjectSessionsView: View {
    let project: Project
    let onToggleSidebar: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @State private var model: SessionsListModel
    @State private var openedSession: SessionMetadata?
    @State private var pendingDelete: SessionMetadata?
    @State private var renamingSession: SessionMetadata?
    @State private var renameDraft = ""

    init(
        project: Project,
        store: SessionStore,
        onToggleSidebar: (() -> Void)? = nil
    ) {
        self.project = project
        self.onToggleSidebar = onToggleSidebar
        _model = State(initialValue: SessionsListModel(project: project, store: store))
    }

    var body: some View {
        List {
            ForEach(model.sessions) { session in
                Button {
                    openedSession = session
                } label: {
                    SessionRow(
                        session: session,
                        runtime: environment.runs.existing(for: project, sessionID: session.id)
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = session
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        renamingSession = session
                        renameDraft = session.title
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onToggleSidebar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "line.3.horizontal")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createSession()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New session")
            }
        }
        .overlay {
            if model.isLoading && model.sessions.isEmpty {
                ProgressView("Loading sessions…")
            } else if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No sessions", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a conversation for this project.")
                } actions: {
                    Button("New session") {
                        createSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
        }
        .navigationDestination(item: $openedSession) { session in
            ChatView(
                project: project,
                session: session,
                environment: environment
            )
        }
        .task {
            await model.load()
            openLinkedSession()
        }
        .onChange(of: environment.pendingSessionLink) { _, _ in
            openLinkedSession()
        }
        .confirmationDialog(
            "Delete session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { session in
            Button("Delete \(session.title)", role: .destructive) {
                Task {
                    // Stop and forget the run first: deleting the folder under a live agent
                    // would leave it writing into a path that no longer exists.
                    environment.runs.discard(for: project, sessionID: session.id)
                    await model.delete(session)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { _ in
            Text("This conversation will be removed from this device.")
        }
        .alert(
            "Rename session",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )
        ) {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                guard let session = renamingSession else { return }
                let sessionTitle = renameDraft
                renamingSession = nil
                Task { await model.rename(session, to: sessionTitle) }
            }
            Button("Cancel", role: .cancel) {
                renamingSession = nil
            }
        }
    }

    private func createSession() {
        openedSession = SessionMetadata()
    }

    /// A notification tap lands here; open the conversation it named.
    private func openLinkedSession() {
        guard let sessionID = environment.consumeSessionLink(for: project) else { return }
        if let existing = model.sessions.first(where: { $0.id == sessionID }) {
            openedSession = existing
        } else {
            openedSession = SessionMetadata(id: sessionID)
        }
    }
}

private struct SessionRow: View {
    let session: SessionMetadata
    let runtime: SessionRuntime?

    /// A session whose last run was cut short says so even before the chat is opened, so the
    /// row reads the flag the store keeps next to the title.
    private var isInterrupted: Bool {
        runtime?.needsContinuation ?? (session.runInFlight == true)
    }

    private var activityLabel: String? {
        if let label = runtime?.activityLabel {
            return label
        }
        return isInterrupted ? "Interrupted" : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(session.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let mode = session.mode, mode != .ask {
                        HStack(spacing: 3) {
                            Image(systemName: mode.systemImage)
                            Text(mode.displayName)
                        }
                        .font(.caption2)
                        .foregroundStyle(mode.tint)
                    }

                    if let label = activityLabel {
                        HStack(spacing: 4) {
                            if runtime?.isRunning == true {
                                ProgressView()
                                    .controlSize(.mini)
                            } else if isInterrupted {
                                Image(systemName: "pause.circle")
                            }
                            Text(label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.caption2)
                        .foregroundStyle(
                            isInterrupted || runtime?.isAwaitingApproval == true
                                ? Color.orange
                                : Color.accentColor
                        )
                    }
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
