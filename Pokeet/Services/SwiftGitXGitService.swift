import Foundation
import PokeetCore
import SwiftGitX
import libgit2

actor SwiftGitXGitService: GitServicing, GitInspecting {
    nonisolated func isRepository(at root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = root.appendingPathComponent(".git").path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    }

    func workingTreeStatus(at root: URL) async throws -> [GitFileStatus] {
        let repository = try open(root)
        do {
            return try repository.status().compactMap(inspectFileStatus(from:))
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: nil))
        }
    }

    func diff(at root: URL, path: String?, staged: Bool) async throws -> String {
        let repository = try open(root)
        do {
            let diff = try repository.diff(to: staged ? .index : .workingTree)
            let patches = diff.patches.filter { patch in
                guard let path, !path.isEmpty else { return true }
                return matches(patch: patch, path: path)
            }
            return render(patches: patches)
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: nil))
        }
    }

    /// Line counts per path for everything that differs from `HEAD`.
    ///
    /// A single tree-to-worktree diff keeps a path that is staged and then
    /// edited again from being counted twice; adding the staged and unstaged
    /// diffs together would report those lines twice. Untracked files never
    /// appear in a libgit2 diff, so they are counted from disk instead.
    func diffStat(at root: URL) async throws -> [GitFileDiffStat] {
        let repository = try open(root)
        do {
            // A failing diff should not wipe out the untracked counts below.
            let pending = try? repository.diff(to: [.workingTree, .index])
            var stats = pending.map { counts(in: $0.patches) } ?? [:]

            for entry in try repository.status() {
                guard let file = inspectFileStatus(from: entry),
                      file.state == "new",
                      stats[file.path] == nil,
                      let added = untrackedLineCount(root: root, path: file.path)
                else { continue }
                stats[file.path] = (added, 0)
            }

            return stats
                .map { GitFileDiffStat(
                    path: $0.key,
                    added: $0.value.added,
                    removed: $0.value.removed
                ) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: nil))
        }
    }

    private func counts(in patches: [Patch]) -> [String: (added: Int, removed: Int)] {
        var stats: [String: (added: Int, removed: Int)] = [:]

        for patch in patches {
            let path = patch.delta.newFile.path.isEmpty
                ? patch.delta.oldFile.path
                : patch.delta.newFile.path
            guard !path.isEmpty else { continue }

            var added = 0
            var removed = 0
            for hunk in patch.hunks {
                for line in hunk.lines {
                    switch line.type {
                    case .addition, .additionEOF:
                        added += 1
                    case .deletion, .deletionEOF:
                        removed += 1
                    default:
                        break
                    }
                }
            }

            let current = stats[path] ?? (0, 0)
            stats[path] = (current.added + added, current.removed + removed)
        }

        return stats
    }

    private func untrackedLineCount(root: URL, path: String) -> Int? {
        let url = root.appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= 1_000_000,
              let data = try? Data(contentsOf: url),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        var lines = text.components(separatedBy: "\n").count
        if text.hasSuffix("\n") {
            lines -= 1
        }
        return max(0, lines)
    }

    func log(at root: URL, limit: Int) async throws -> [GitCommitInfo] {
        let repository = try open(root)
        do {
            guard !repository.isHEADUnborn else { return [] }
            return try repository.log()
                .prefix(max(1, limit))
                .map { commit in
                    GitCommitInfo(
                        hash: commit.id.hex,
                        author: commit.author.name,
                        date: commit.date,
                        subject: commit.summary
                    )
                }
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: nil))
        }
    }

    private func inspectFileStatus(from entry: StatusEntry) -> GitFileStatus? {
        let delta = entry.workingTree ?? entry.index
        let path = delta?.newFile.path.isEmpty == false
            ? delta?.newFile.path
            : delta?.oldFile.path
        guard let path, !path.isEmpty else { return nil }

        var state = "modified"
        for status in entry.status {
            switch status {
            case .workingTreeDeleted, .indexDeleted:
                state = "deleted"
            case .workingTreeNew, .indexNew:
                state = "new"
            case .workingTreeRenamed, .indexRenamed:
                state = "renamed"
            case .conflicted:
                state = "conflicted"
            case .workingTreeTypeChange, .indexTypeChange:
                state = "modified"
            default:
                break
            }
        }

        return GitFileStatus(path: path, state: state)
    }

    private func matches(patch: Patch, path: String) -> Bool {
        let candidates = [patch.delta.oldFile.path, patch.delta.newFile.path]
        return candidates.contains { candidate in
            candidate == path || candidate.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }
    }

    private func render(patches: [Patch]) -> String {
        var lines: [String] = []

        for patch in patches {
            let oldPath = patch.delta.oldFile.path
            let newPath = patch.delta.newFile.path
            let displayPath = newPath.isEmpty ? oldPath : newPath

            lines.append("diff --git a/\(oldPath.isEmpty ? displayPath : oldPath) b/\(newPath.isEmpty ? displayPath : newPath)")
            lines.append("--- \(patch.delta.type == .added || oldPath.isEmpty ? "/dev/null" : "a/" + oldPath)")
            lines.append("+++ \(patch.delta.type == .deleted || newPath.isEmpty ? "/dev/null" : "b/" + newPath)")

            if patch.hunks.isEmpty {
                lines.append("Binary or metadata-only change.")
                continue
            }

            for hunk in patch.hunks {
                lines.append(hunk.header.trimmingCharacters(in: .newlines))
                for line in hunk.lines {
                    let prefix: String
                    switch line.type {
                    case .context, .contextEOF:
                        prefix = " "
                    case .addition, .additionEOF:
                        prefix = "+"
                    case .deletion, .deletionEOF:
                        prefix = "-"
                    }

                    var text = line.content
                    if text.hasSuffix("\n") {
                        text.removeLast()
                    }
                    lines.append(prefix + text)
                }
            }
        }

        return lines.joined(separator: "\n")
    }
    func clone(
        _ spec: GitRemoteSpec,
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let cleanURL = stripCredentials(spec.url)
        guard cleanURL.scheme?.lowercased() == "https", cleanURL.host != nil else {
            throw GitServiceError.invalidRemote(spec.url.absoluteString)
        }
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw GitServiceError.destinationExists(directory.lastPathComponent)
        }

        let token = spec.token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = token.flatMap { $0.isEmpty ? nil : authenticatedURL(cleanURL, token: $0) } ?? cleanURL
        let targetDirectory = directory
        let progressSink = progress

        do {
            try await Task.detached(priority: .userInitiated) {
                let repository = try await Repository.clone(
                    from: remoteURL,
                    to: targetDirectory,
                    transferProgressHandler: { transfer in
                        guard transfer.totalObjects > 0 else { return }
                        let value = Double(transfer.receivedObjects) / Double(transfer.totalObjects)
                        progressSink(min(1, max(0, value)))
                    }
                )
                _ = repository
            }.value
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw mapCloneError(error, token: token)
        }

        do {
            let repository = try Repository(at: directory, createIfNotExists: false)
            try repository.config.set("remote.origin.url", to: cleanURL.absoluteString)
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: token))
        }

        progress(1)
    }

    func status(at root: URL) async throws -> [GitFileStatus] {
        let repository = try open(root)
        do {
            return try repository.status().compactMap(fileStatus(from:))
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: nil))
        }
    }

    func commitAll(at root: URL, message: String, author: GitAuthor) async throws -> String {
        let repository = try open(root)
        do {
            try repository.config.set("user.name", to: author.name)
            try repository.config.set("user.email", to: author.email)

            let entries = try repository.status()
            let paths = Set(entries.compactMap(fileStatus(from:)).map(\.path))
            let deletions = Set(entries.compactMap(deletedPath(from:)))
            guard !paths.isEmpty || !deletions.isEmpty else {
                throw GitServiceError.noChanges
            }

            if !paths.isEmpty {
                try repository.add(paths: paths.sorted())
            }
            // SwiftGitX does not expose index removal, so stage deletions with libgit2 directly.
            try stageDeletions(deletions, at: root)

            // Reopen so the commit sees the index written by the libgit2 handle.
            let commit = try open(root).commit(message: message)
            return commit.id.hex
        } catch let error as GitServiceError {
            throw error
        } catch {
            throw GitServiceError.commitFailed(sanitizedMessage(error, token: nil))
        }
    }

    func push(at root: URL, token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitServiceError.authenticationRequired
        }

        let repository = try open(root)
        do {
            guard !repository.isHEADUnborn else {
                throw GitServiceError.noChanges
            }
            guard !repository.isHEADDetached else {
                throw GitServiceError.detachedHead
            }
            guard let cleanURLString = try repository.config.string(forKey: "remote.origin.url"),
                  let cleanURL = URL(string: cleanURLString)
            else {
                throw GitServiceError.invalidRemote("origin")
            }
            guard let authenticatedURL = authenticatedURL(cleanURL, token: token) else {
                throw GitServiceError.invalidRemote(cleanURLString)
            }

            try repository.config.set("remote.origin.url", to: authenticatedURL.absoluteString)
            defer {
                try? repository.config.set("remote.origin.url", to: cleanURL.absoluteString)
            }

            try await repository.push()
        } catch let error as GitServiceError {
            throw error
        } catch {
            throw GitServiceError.pushFailed(sanitizedMessage(error, token: token))
        }
    }

    func currentBranch(at root: URL) async throws -> String {
        let repository = try open(root)
        do {
            return try repository.branch.current.name
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: nil))
        }
    }

    private func open(_ root: URL) throws -> Repository {
        do {
            return try Repository(at: root, createIfNotExists: false)
        } catch {
            throw GitServiceError.openFailed(sanitizedMessage(error, token: nil))
        }
    }

    private func fileStatus(from entry: StatusEntry) -> GitFileStatus? {
        var state = "modified"
        for status in entry.status {
            switch status {
            case .workingTreeDeleted, .indexDeleted:
                return nil
            case .workingTreeNew, .indexNew:
                state = "new"
            case .workingTreeRenamed, .indexRenamed:
                state = "renamed"
            case .conflicted:
                state = "conflicted"
            default:
                break
            }
        }

        guard let path = (entry.workingTree ?? entry.index)?.newFile.path, !path.isEmpty else {
            return nil
        }
        return GitFileStatus(path: path, state: state)
    }

    private func deletedPath(from entry: StatusEntry) -> String? {
        let isDeleted = entry.status.contains { status in
            switch status {
            case .workingTreeDeleted, .indexDeleted:
                return true
            default:
                return false
            }
        }
        guard isDeleted else { return nil }

        let delta = entry.workingTree ?? entry.index
        let path = delta?.oldFile.path.isEmpty == false
            ? delta?.oldFile.path
            : delta?.newFile.path
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    private func stageDeletions(_ paths: Set<String>, at root: URL) throws {
        guard !paths.isEmpty else { return }

        var repositoryPointer: OpaquePointer?
        guard git_repository_open(&repositoryPointer, root.path) == GIT_OK.rawValue,
              let repositoryPointer
        else {
            throw GitServiceError.commitFailed("Could not open the repository index.")
        }
        defer { git_repository_free(repositoryPointer) }

        var indexPointer: OpaquePointer?
        guard git_repository_index(&indexPointer, repositoryPointer) == GIT_OK.rawValue,
              let indexPointer
        else {
            throw GitServiceError.commitFailed("Could not open the repository index.")
        }
        defer { git_index_free(indexPointer) }

        for path in paths {
            let status = git_index_remove_bypath(indexPointer, path)
            guard status == GIT_OK.rawValue || status == GIT_ENOTFOUND.rawValue else {
                throw GitServiceError.commitFailed("Could not stage deletion of \(path).")
            }
        }

        guard git_index_write(indexPointer) == GIT_OK.rawValue else {
            throw GitServiceError.commitFailed("Could not write the repository index.")
        }
    }

    private func authenticatedURL(_ url: URL, token: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = "x-access-token"
        components.password = token
        return components.url
    }

    private func stripCredentials(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    private func mapCloneError(_ error: Error, token: String?) -> GitServiceError {
        let message = sanitizedMessage(error, token: token)
        if message.localizedCaseInsensitiveContains("authentication")
            || message.contains("401")
            || message.localizedCaseInsensitiveContains("credentials") {
            return .authenticationRequired
        }
        return .cloneFailed(message)
    }

    private func sanitizedMessage(_ error: Error, token: String?) -> String {
        var message = (error as? SwiftGitXError)?.message ?? error.localizedDescription
        if let token, !token.isEmpty {
            message = message.replacingOccurrences(of: token, with: "***")
        }
        return message
    }
}
