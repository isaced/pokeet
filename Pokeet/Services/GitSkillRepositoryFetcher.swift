import Foundation
import PokeetCore
import libgit2

/// Shallow clone for the skill importer.
///
/// SwiftGitX's `CloneOptions` has no depth knob, so this drops to libgit2 directly — the same
/// layer the git service already uses for index work. Depth 1 keeps a skills repository from
/// pulling its whole history onto a phone, and the transfer callback turns cancellation into
/// an abort between objects instead of a download that has to finish first.
actor GitSkillRepositoryFetcher: SkillRepositoryFetching {
    private typealias ProgressHandler = @Sendable (Double) -> Void

    /// libgit2 refuses every call until it has been initialised. SwiftGitX does this for its
    /// own entry points; going to the C API directly means doing it ourselves.
    private static let libgit2Ready: Bool = {
        git_libgit2_init()
        return true
    }()

    func clone(
        _ source: SkillSourceURL,
        token: String?,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = Self.libgit2Ready
        let remote = Self.authenticatedURL(source.url, token: token)
        let ref = source.ref

        let work = Task.detached(priority: .userInitiated) {
            try Self.performClone(remote: remote, ref: ref, into: directory, progress: progress)
        }
        let result = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }

        do {
            try result.get()
        } catch let error as SkillFetchError {
            throw error
        } catch {
            throw SkillFetchError.cloneFailed(error.localizedDescription)
        }
    }

    func commitSHA(at directory: URL) async throws -> String? {
        _ = Self.libgit2Ready
        var repository: OpaquePointer?
        guard git_repository_open(&repository, directory.path) == GIT_OK.rawValue,
              let repository
        else { return nil }
        defer { git_repository_free(repository) }

        var oid = git_oid()
        guard git_reference_name_to_id(&oid, repository, "HEAD") == GIT_OK.rawValue else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: 41)
        guard git_oid_tostr(&buffer, 41, &oid) != nil else { return nil }
        return String(cString: buffer)
    }

    /// `git ls-remote`: one connect, no objects downloaded, so a "check for updates" on ten
    /// imported skills costs ten handshakes instead of ten clones.
    func latestCommit(_ source: SkillSourceURL, token: String?) async throws -> String? {
        _ = Self.libgit2Ready
        let remote = Self.authenticatedURL(source.url, token: token)
        let ref = source.ref

        return try await Task.detached(priority: .utility) {
            try Self.performRemoteHead(remote: remote, ref: ref)
        }.value
    }

    // MARK: - libgit2

    private static func performClone(
        remote: URL,
        ref: String?,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        var options = git_clone_options()
        git_clone_init_options(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        options.fetch_opts.depth = 1
        options.fetch_opts.callbacks.transfer_progress = transferProgressCallback

        var refStorage: UnsafeMutablePointer<CChar>?
        defer { if let refStorage { free(refStorage) } }
        if let ref {
            refStorage = strdup(ref)
            options.checkout_branch = UnsafePointer(refStorage)
        }

        var handler = progress
        var repository: OpaquePointer?
        let status = withUnsafeMutablePointer(to: &handler) { handlerPointer -> Int32 in
            options.fetch_opts.callbacks.payload = UnsafeMutableRawPointer(handlerPointer)
            return git_clone(&repository, remote.absoluteString, directory.path, &options)
        }
        if let repository { git_repository_free(repository) }

        guard status == GIT_OK.rawValue else {
            throw error(for: status, remote: remote)
        }
    }

    private static func performRemoteHead(remote: URL, ref: String?) throws -> String? {
        var pointer: OpaquePointer?
        guard git_remote_create_detached(&pointer, remote.absoluteString) == GIT_OK.rawValue,
              let pointer
        else {
            throw SkillFetchError.cloneFailed("Could not create a remote for that URL.")
        }
        defer { git_remote_free(pointer) }

        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))

        let connectStatus = git_remote_connect(pointer, GIT_DIRECTION_FETCH, &callbacks, nil, nil)
        guard connectStatus == GIT_OK.rawValue else {
            throw error(for: connectStatus, remote: remote)
        }
        defer { git_remote_disconnect(pointer) }

        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        guard git_remote_ls(&heads, &count, pointer) == GIT_OK.rawValue, let heads else {
            return nil
        }

        // The array belongs to the remote; `git_remote_free` above releases it.
        var head: (sha: String, symref: String?)?
        var named: String?
        let wanted = ref.map { $0.hasPrefix("refs/") ? $0 : "refs/heads/\($0)" }

        for index in 0..<count {
            guard let entry = heads[index]?.pointee else { continue }
            guard let namePointer = entry.name else { continue }
            let name = String(cString: namePointer)

            if name == wanted || (ref.map { name == "refs/tags/\($0)" } ?? false) {
                named = oidString(entry.oid)
            }
            if name == "HEAD" {
                head = (
                    oidString(entry.oid),
                    entry.symref_target.map { String(cString: $0) }
                )
            }
        }

        if ref != nil { return named }
        guard let head else { return nil }

        // HEAD is usually a symref; resolve it so a moved default branch still compares right.
        if let symref = head.symref {
            for index in 0..<count {
                guard let entry = heads[index]?.pointee,
                      let namePointer = entry.name,
                      String(cString: namePointer) == symref
                else { continue }
                return oidString(entry.oid)
            }
        }
        return head.sha
    }

    private static func oidString(_ oid: git_oid) -> String {
        var oid = oid
        var buffer = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buffer, 41, &oid)
        return String(cString: buffer)
    }

    private static let transferProgressCallback: git_indexer_progress_cb = { stats, payload in
        // libgit2 aborts the transfer when the callback returns non-zero.
        guard Task.isCancelled == false else { return 1 }
        guard let stats = stats?.pointee, let payload else { return 0 }

        let handler = payload.assumingMemoryBound(to: ProgressHandler.self).pointee
        let total = Double(max(1, stats.total_objects))
        handler(min(1, Double(stats.received_objects) / total))
        return 0
    }

    private static func error(for status: Int32, remote: URL) -> SkillFetchError {
        if Task.isCancelled { return .cancelled }

        let message = git_error_last().flatMap { $0.pointee.message }
            .map { String(cString: $0) } ?? "git error \(status)"

        switch status {
        case GIT_ENOTFOUND.rawValue, GIT_EAUTH.rawValue, GIT_EEXISTS.rawValue:
            return .repositoryNotFound(sanitized(remote))
        default:
            return .cloneFailed(message)
        }
    }

    /// The token must never reach a message the user can copy somewhere.
    private static func sanitized(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        return components?.string ?? url.absoluteString
    }

    private static func authenticatedURL(_ url: URL, token: String?) -> URL {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.user = "x-access-token"
        components.password = token
        return components.url ?? url
    }
}
