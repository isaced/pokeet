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

    func create() async -> SessionMetadata? {
        let session = await store.create(projectName: project.name)
        await load()
        return session
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
    @State private var isCreating = false

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
                NavigationLink {
                    ChatView(
                        project: project,
                        session: session,
                        environment: environment
                    )
                } label: {
                    SessionRow(session: session)
                }
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
                .disabled(isCreating)
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
        .onAppear {
            Task { await model.load() }
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
        guard !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            if let session = await model.create() {
                openedSession = session
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.headline)
                .lineLimit(1)

            Text(session.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
