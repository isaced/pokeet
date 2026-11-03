import PhotosUI
import PokeetCore
import SwiftUI
import UIKit

struct ChatView: View {
    let project: Project

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatViewModel
    @State private var isShowingProjectInfo = false
    @State private var isShowingFiles = false
    @State private var isShowingChanges = false
    @State private var isShowingFilePicker = false
    @State private var isShowingModelPicker = false
    @State private var isShowingModePicker = false
    @State private var isShowingAppliedChanges = false
    @State private var isShowingPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var pendingAnchorID: String?
    @State private var traceOverrides: [UUID: Bool] = [:]
    @State private var isPinnedToBottom = true
    private let git: any GitInspecting

    @MainActor
    init(
        project: Project,
        session: SessionMetadata,
        environment: AppEnvironment
    ) {
        self.project = project
        self.git = environment.git
        _model = State(initialValue: ChatViewModel(
            project: project,
            environment: environment,
            session: session
        ))
    }

    private var subtitle: String {
        if let cacheSummary = model.cacheSummary {
            return "\(project.name) · \(cacheSummary)"
        }
        return project.name
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if model.isRestoringSession {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messageList
            }
            statusArea
            pendingAttachments
            if let plan = model.currentPlan {
                PlanProgressView(plan: plan, isExecuting: model.planIsExecuting) {
                    model.showPlan()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            composer(bindable: $model)
        }
        .background(Color(.systemBackground))
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NavigationSubtitleModifier(subtitle: subtitle))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    projectMenu
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .alert("Project", isPresented: $isShowingProjectInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(projectInfo)
        }
        .sheet(isPresented: $isShowingFiles) {
            FileBrowserView(project: project)
        }
        .sheet(isPresented: $isShowingChanges) {
            ChangesView(
                project: project,
                git: git,
                canCommit: model.canCommit,
                onCommit: {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        model.prepareCommit()
                    }
                }
            )
        }
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
        .sheet(isPresented: $isShowingFilePicker) {
            ProjectFilePickerView(project: project) { path in
                loadContextFile(path)
            }
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerView()
        }
        .sheet(isPresented: $isShowingModePicker) {
            ModePickerView(selected: model.mode) { mode in
                model.setMode(mode)
                isShowingModePicker = false
            }
        }
        .sheet(isPresented: $model.isShowingPlan) {
            PlanReviewView(
                plan: model.planForReview ?? AgentPlan(title: "Plan", steps: []),
                onExecute: model.executePlan,
                onStay: model.stayInPlan,
                onRefine: model.refinePlan
            )
        }
        .sheet(isPresented: $model.isShowingActionReview) {
            if let action = model.pendingAction {
                ActionReviewView(action: action) { allow in
                    model.resolveAction(allow: allow)
                }
            }
        }
        .sheet(isPresented: $isShowingAppliedChanges) {
            AppliedChangesView(changes: model.appliedChanges)
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $photoPickerItems,
            maxSelectionCount: ChatViewModel.maxImages,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            photoPickerItems = []
            Task { await loadImages(items) }
        }
        .task {
            await model.loadInitialState()
        }
        .onDisappear {
            model.cancelRun()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.checkpointNow()
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.bubbles.isEmpty {
                        emptyState
                            .padding(.top, 64)
                    }

                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: rows.last?.id) { _, _ in
                guard let last = rows.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onChange(of: model.streamRevision) { _, _ in
                guard isPinnedToBottom, let last = rows.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: rows.first?.id) { _, _ in
                restorePendingAnchor(using: proxy)
            }
            .onChange(of: model.isRunning) { _, running in
                guard !running, isPinnedToBottom, let last = rows.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < 2
            } action: { _, isAtTop in
                guard isAtTop, model.hasOlderBubbles else { return }
                pendingAnchorID = rows.first?.id
                model.loadOlderBubbles()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            } action: { _, pinned in
                isPinnedToBottom = pinned
            }
        }
    }

    private var rows: [ChatRow] {
        ChatTranscriptBuilder.rows(
            from: model.visibleBubbles,
            isRunning: model.isRunning,
            overrides: traceOverrides
        )
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .turnHeader(let header):
            TurnHeaderRow(header: header) {
                withAnimation(.snappy(duration: 0.22)) {
                    traceOverrides[header.id] = !header.isExpanded
                }
            }
        case .bubble(let bubble, let presentation):
            switch presentation {
            case .normal:
                MessageBubble(bubble: bubble)
                    .equatable()
            case .trace:
                if bubble.role == .reasoning {
                    ReasoningBubble(
                        text: bubble.text,
                        isStreaming: bubble.isStreaming,
                        duration: bubble.reasoningDuration
                    )
                } else {
                    TraceStepRow(bubble: bubble, isNotice: false)
                }
            case .traceText:
                TraceAssistantText(bubble: bubble)
            case .notice:
                TraceStepRow(bubble: bubble, isNotice: true)
            }
        }
    }

    private func restorePendingAnchor(using proxy: ScrollViewProxy) {
        guard let anchor = pendingAnchorID else { return }
        pendingAnchorID = nil

        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(anchor, anchor: .top)
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

    @ViewBuilder
    private var pendingAttachments: some View {
        if !model.pendingImages.isEmpty || !model.pendingFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.pendingFiles, id: \.path) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                            Text("@\(file.path)")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                model.removeContextFile(path: file.path)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(file.path)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: 240)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }

                    ForEach(Array(model.pendingImages.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            if let uiImage = DecodedImageCache.image(for: image.data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                                    .frame(width: 64, height: 64)
                            }

                            Button {
                                model.removePendingImage(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove image")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    private func composer(bindable: Bindable<ChatViewModel>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Message", text: bindable.input, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .disabled(model.isRunning)
                .padding(.horizontal, 16)
                .padding(.top, 14)

            HStack(spacing: 14) {
                Menu {
                    composerMenu
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .tint(.primary)
                .accessibilityLabel("Add")

                Button {
                    isShowingModePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.mode.systemImage)
                            .font(.caption2)
                        Text(model.mode.displayName)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(model.mode == .bypass ? Color.red : Color.secondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .accessibilityLabel("Choose agent mode")

                Button {
                    isShowingModelPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(model.activeModelLabel ?? "Model")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .accessibilityLabel("Choose model")

                Spacer(minLength: 8)

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
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(
            Color(.systemBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.pendingImages.isEmpty
            || !model.pendingFiles.isEmpty
    }

    @MainActor
    private func loadContextFile(_ path: String) {
        Task {
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    try FileWorkspace(root: project.directory)
                        .read(path, maxBytes: 120_000)
                }.value
                model.addContextFile(ContextFile(path: path, content: content))
            } catch {
                model.errorMessage = "Could not read \(path): "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    @MainActor
    private func loadImages(_ items: [PhotosPickerItem]) async {
        var images: [ChatImage] = []

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let image = await Task.detached(priority: .userInitiated) {
                ChatImageProcessor.makeChatImage(from: data)
            }.value
            if let image {
                images.append(image)
            }
        }

        if images.isEmpty {
            model.errorMessage = "Could not load the selected image."
        } else {
            model.addPendingImages(images)
        }
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
                isShowingChanges = true
            } label: {
                Label("Changes", systemImage: "plusminus.circle")
            }
        }

        Button {
            isShowingFiles = true
        } label: {
            Label("Files", systemImage: "folder")
        }

        Button {
            isShowingAppliedChanges = true
        } label: {
            Label("Applied changes", systemImage: "clock.arrow.circlepath")
        }

        Button {
            isShowingProjectInfo = true
        } label: {
            Label("Project Info", systemImage: "info.circle")
        }
    }

    @ViewBuilder
    private var composerMenu: some View {
        Button {
            isShowingPhotoPicker = true
        } label: {
            Label("Upload image", systemImage: "photo")
        }

        Button {
            isShowingFilePicker = true
        } label: {
            Label("At file", systemImage: "at")
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

private struct NavigationSubtitleModifier: ViewModifier {
    let subtitle: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}
