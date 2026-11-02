import SwiftUI

struct ChatView: View {
    let project: Project
    let onToggleSidebar: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatViewModel
    @State private var isShowingSettings = false
    @State private var isShowingProjectInfo = false
    @State private var isConfirmingNewSession = false

    @MainActor
    init(
        project: Project,
        environment: AppEnvironment,
        onToggleSidebar: (() -> Void)? = nil
    ) {
        self.project = project
        self.onToggleSidebar = onToggleSidebar
        _model = State(initialValue: ChatViewModel(project: project, environment: environment))
    }

    private var isSplitDetail: Bool {
        onToggleSidebar != nil
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            messageList
            statusArea
            composer(bindable: $model)
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $model.isShowingReview) {
            DiffReviewView(proposals: model.pendingProposals) { decisions in
                model.resolve(decisions)
            }
        }
        .alert("Commit & Push", isPresented: $model.isShowingCommitPrompt) {
            TextField("Commit message", text: $model.commitMessage)
            Button("Commit & Push") {
                Task { await model.commitAndPush() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Commits approved changes and pushes the current branch to origin.")
        }
        .task {
            await model.loadInitialState()
        }
        .onDisappear {
            model.cancelRun()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                leadingAction()
            } label: {
                headerIcon(isSplitDetail ? "line.3.horizontal" : "chevron.left")
                    .frame(width: 40, height: 40)
                    .background(Color(.systemBackground), in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.06), lineWidth: 1))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            VStack(spacing: 1) {
                Text(project.name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let cacheSummary = model.cacheSummary {
                    Text(cacheSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Button {
                    requestNewSession()
                } label: {
                    headerIcon("pencil")
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(height: 20)

                Menu {
                    projectMenu
                } label: {
                    headerIcon("ellipsis")
                }
                .buttonStyle(.plain)
            }
            .frame(height: 40)
            .background(Color(.systemBackground), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .alert("Project", isPresented: $isShowingProjectInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(projectInfo)
        }
        .confirmationDialog(
            "Start a new session?",
            isPresented: $isConfirmingNewSession,
            titleVisibility: .visible
        ) {
            Button("Start new session", role: .destructive) {
                Task { await model.startNewSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the conversation. Files on disk stay unchanged.")
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.bubbles.isEmpty {
                        emptyState
                            .padding(.top, 64)
                    }

                    ForEach(model.bubbles) { bubble in
                        MessageBubble(bubble: bubble)
                            .id(bubble.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.bubbles.count) { _, _ in
                guard let last = model.bubbles.last else { return }
                withAnimation {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: model.bubbles.last?.text) { _, _ in
                guard let last = model.bubbles.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text("What should we build?")
                .font(.title3.weight(.semibold))
            Text("Pokeet reads the project, proposes a diff, and waits for your review.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusArea: some View {
        if let status = model.status {
            statusCapsule(status)
        }

        if model.isCommitting {
            statusCapsule("Committing and pushing…")
        }

        if let error = model.errorMessage {
            notice(error, color: .red, icon: "exclamationmark.triangle.fill") {
                model.clearErrorMessage()
            }
        }

        if let banner = model.banner {
            notice(banner, color: .green, icon: "checkmark.circle.fill") {
                model.dismissBanner()
            }
        }
    }

    private func statusCapsule(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground).opacity(0.7), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func composer(bindable: Bindable<ChatViewModel>) -> some View {
        HStack(spacing: 10) {
            Menu {
                composerMenu
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .tint(.primary)

            TextField("Ask Pokeet", text: bindable.input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .disabled(model.isRunning)

            if model.isRunning {
                Button {
                    model.cancelRun()
                } label: {
                    sendButton(icon: "stop.fill", enabled: true)
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    model.send()
                } label: {
                    sendButton(icon: "arrow.up", enabled: canSend)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            Color(.systemBackground),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendButton(icon: String, enabled: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(
                enabled ? Color.accentColor : Color.gray.opacity(0.35),
                in: Circle()
            )
    }

    @ViewBuilder
    private var projectMenu: some View {
        if project.isGitRepository {
            Button {
                model.prepareCommit()
            } label: {
                Label("Commit & Push", systemImage: "arrow.up.circle")
            }
            .disabled(!model.canCommit)

            Divider()
        }

        Button {
            isShowingProjectInfo = true
        } label: {
            Label("Project info", systemImage: "info.circle")
        }

        Button {
            isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    @ViewBuilder
    private var composerMenu: some View {
        Button {
            requestNewSession()
        } label: {
            Label("New session", systemImage: "square.and.pencil")
        }

        if project.isGitRepository {
            Button {
                model.prepareCommit()
            } label: {
                Label("Commit & Push", systemImage: "arrow.up.circle")
            }
            .disabled(!model.canCommit)
        }

        Button {
            isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func leadingAction() {
        if let onToggleSidebar {
            onToggleSidebar()
        } else {
            dismiss()
        }
    }

    private func requestNewSession() {
        if model.bubbles.isEmpty && !model.isRunning {
            Task { await model.startNewSession() }
        } else {
            isConfirmingNewSession = true
        }
    }

    private var projectInfo: String {
        var lines = [
            "Name: \(project.name)",
            "Folder: \(project.directory.lastPathComponent)"
        ]
        if project.isGitRepository {
            lines.append("Git: \(project.remoteHost ?? "repository")")
        } else {
            lines.append("Git: none (local project)")
        }

        if model.cacheStats.hasData {
            lines.append(
                "Cache: \(model.cacheStats.cachedTokens) read / "
                    + "\(model.cacheStats.promptTokens) prompt, "
                    + "\(model.cacheStats.missedTokens) missed"
            )
        }

        return lines.joined(separator: "\n")
    }

    private func notice(
        _ text: String,
        color: Color,
        icon: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
