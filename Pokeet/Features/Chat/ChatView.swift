import PhotosUI
import PokeetCore
import SwiftUI
import UIKit

struct ChatView: View {
    let project: Project
    let onToggleSidebar: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatViewModel
    @State private var isShowingProjectInfo = false
    @State private var isShowingFiles = false
    @State private var isShowingChanges = false
    @State private var isShowingFilePicker = false
    @State private var isShowingPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    private let git: any GitInspecting

    @MainActor
    init(
        project: Project,
        session: SessionMetadata,
        environment: AppEnvironment,
        onToggleSidebar: (() -> Void)? = nil
    ) {
        self.project = project
        self.onToggleSidebar = onToggleSidebar
        self.git = environment.git
        _model = State(initialValue: ChatViewModel(
            project: project,
            environment: environment,
            session: session
        ))
    }

    private var isSplitDetail: Bool {
        onToggleSidebar != nil
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
            header
            messageList
            statusArea
            pendingAttachments
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
        .sheet(isPresented: $isShowingFilePicker) {
            ProjectFilePickerView(project: project) { path in
                loadContextFile(path)
            }
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
                Text(model.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Menu {
                projectMenu
            } label: {
                headerIcon("ellipsis")
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
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
                            if let uiImage = UIImage(data: image.data) {
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
