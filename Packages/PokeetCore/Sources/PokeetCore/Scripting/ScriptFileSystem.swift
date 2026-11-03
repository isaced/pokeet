import Foundation

/// The only filesystem a sandboxed script can see.
///
/// Reads fall through to the workspace; writes are buffered and surface as
/// `FileProposal` diffs so the normal review flow still applies.
public protocol ScriptFileSystem: AnyObject, Sendable {
    func read(_ path: String) throws -> String
    func write(_ path: String, content: String) throws
    func list(_ path: String, recursive: Bool) throws -> [WorkspaceEntry]
    func exists(_ path: String) -> Bool
    func info(_ path: String) throws -> FileInfo
    func proposals() -> [FileProposal]
}

public final class OverlayScriptFileSystem: ScriptFileSystem, @unchecked Sendable {
    private let workspace: any Workspace
    private let sandbox: PathSandbox
    private let limits: ScriptLimits
    private let lock = NSLock()

    /// Buffered writes, in first-write order.
    private var writeOrder: [String] = []
    private var writes: [String: String] = [:]
    /// Content of each touched file before the script ran. Absent means "did not exist".
    private var bases: [String: String] = [:]
    private var created: Set<String> = []
    private var bufferedBytes = 0

    public init(workspace: any Workspace, limits: ScriptLimits = ScriptLimits()) {
        self.workspace = workspace
        self.sandbox = PathSandbox(root: workspace.root)
        self.limits = limits
    }

    public func read(_ path: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let normalized = try normalize(path, allowRoot: false)
        if let content = writes[normalized] {
            return content
        }
        return try workspace.read(normalized, maxBytes: limits.maxReadBytes)
    }

    public func write(_ path: String, content: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let normalized = try normalize(path, allowRoot: false)
        let byteCount = content.utf8.count
        guard byteCount <= limits.maxWriteBytes else {
            throw ScriptRuntimeError.startup(
                "Refusing to write \(normalized): \(byteCount) bytes exceeds the \(limits.maxWriteBytes) byte per-file limit."
            )
        }

        if writes[normalized] == nil {
            guard writeOrder.count < limits.maxWriteFiles else {
                throw ScriptRuntimeError.startup(
                    "Refusing to write \(normalized): a run may touch at most \(limits.maxWriteFiles) files."
                )
            }
            let existed = workspace.exists(normalized)
            if existed {
                do {
                    bases[normalized] = try workspace.read(
                        normalized,
                        maxBytes: WorkspaceLimits.maxReadBytes
                    )
                } catch {
                    throw ScriptRuntimeError.startup(
                        "Cannot stage a change to \(normalized): "
                            + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    )
                }
            } else {
                created.insert(normalized)
            }
            writeOrder.append(normalized)
        }

        let previous = writes[normalized]?.utf8.count ?? 0
        let nextTotal = bufferedBytes - previous + byteCount
        guard nextTotal <= limits.maxWriteBytes * limits.maxWriteFiles else {
            throw ScriptRuntimeError.startup(
                "Refusing to write \(normalized): buffered output exceeds \(limits.maxWriteBytes * limits.maxWriteFiles) bytes."
            )
        }

        writes[normalized] = content
        bufferedBytes = nextTotal
    }

    public func list(_ path: String, recursive: Bool) throws -> [WorkspaceEntry] {
        lock.lock()
        defer { lock.unlock() }

        let normalized = try normalize(path, allowRoot: true)
        let entries = try workspace.list(normalized, recursive: recursive, maxEntries: 2_000)

        var seen = Set(entries.map(\.path))
        var merged = entries
        let prefix = normalized.isEmpty ? "" : normalized + "/"
        for staged in writeOrder where staged.hasPrefix(prefix) {
            if seen.insert(staged).inserted {
                merged.append(WorkspaceEntry(path: staged, isDirectory: false))
            }
        }
        return merged.sorted { $0.path < $1.path }
    }

    public func exists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let normalized = try? normalize(path, allowRoot: false) else { return false }
        if writes[normalized] != nil { return true }
        if created.contains(normalized) { return true }
        return workspace.exists(normalized)
    }

    public func info(_ path: String) throws -> FileInfo {
        lock.lock()
        defer { lock.unlock() }

        let normalized = try normalize(path, allowRoot: true)
        if let staged = writes[normalized] {
            return FileInfo(
                path: normalized,
                exists: true,
                sizeBytes: staged.utf8.count,
                lineCount: FileProbe.lineCount(of: staged),
                isText: true
            )
        }
        return try FileProbe.probe(
            normalized,
            in: workspace,
            lineCountLimit: limits.maxReadBytes
        )
    }

    /// Diffs produced by the script, in the order the files were first touched.
    public func proposals() -> [FileProposal] {
        lock.lock()
        defer { lock.unlock() }

        var result: [FileProposal] = []
        for path in writeOrder {
            guard let content = writes[path] else { continue }
            let base = created.contains(path) ? nil : bases[path]
            if let base, base == content { continue }
            let diff = LineDiff.compare(old: base, new: content)
            result.append(
                FileProposal(
                    path: path,
                    kind: base == nil ? .create : .update,
                    baseContent: base,
                    newContent: content,
                    diff: diff
                )
            )
        }
        return result
    }

    private func normalize(_ path: String, allowRoot: Bool) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try sandbox.resolve(trimmed, allowRoot: allowRoot)
        } catch {
            throw ScriptRuntimeError.startup(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        if trimmed.isEmpty || trimmed == "." {
            return ""
        }
        return trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
    }
}
