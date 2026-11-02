import Foundation
import PokeetCore
import SwiftGitX

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

            let paths = Set(try repository.status().compactMap(fileStatus(from:)).map(\.path))
            guard !paths.isEmpty else {
                throw GitServiceError.noChanges
            }

            try repository.add(paths: paths.sorted())
            let commit = try repository.commit(message: message)
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
