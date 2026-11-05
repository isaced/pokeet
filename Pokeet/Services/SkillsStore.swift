import Foundation
import Observation
import PokeetCore

public enum SkillImportError: Error, Equatable, LocalizedError {
    case invalid([SkillIssue])
    case nameTaken(String)
    case nameMismatch(expected: String, found: String)
    case notImported(String)
    case notEditable(String)
    case notRemovable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let issues):
            issues.first?.message ?? "That folder is not a usable skill."
        case .nameTaken(let name):
            "There is already a skill named \"\(name)\". Delete it first, or import under a different name."
        case .nameMismatch(let expected, let found):
            "The picked skill is named \"\(found)\", not \"\(expected)\". Open it and check the name in its SKILL.md."
        case .notImported(let name):
            "\"\(name)\" was not imported from a repository, so there is nothing to update."
        case .notEditable(let name):
            "\"\(name)\" is not one Pokeet can edit. Only skills in the app's own folder are writable."
        case .notRemovable(let location):
            "\"\(location)\" lives in a repository, so Pokeet will not delete it. Remove it from the project instead."
        case .failed(let message):
            message
        }
    }
}

/// Owns the app-level skills folder: what is installed, what a picked folder would become,
/// and the two operations that change it. Project skills are listed read-only, because a
/// repository is the only thing that should edit them.
@MainActor
@Observable
final class SkillsStore {
    /// A procedure is a handful of Markdown files, not a media package. These caps keep a
    /// picked folder from filling the container by accident.
    nonisolated static let maxFiles = 200
    nonisolated static let maxBytes = 2_000_000

    /// Where a skill came from, when it came from a repository. Kept out of the skill folder
    /// in a dot-file so discovery ignores it and an "update available" check can compare commits.
    struct Provenance: Codable, Equatable, Sendable {
        var repository: String
        var ref: String?
        var commit: String?
        var path: String
        var importedAt: Date
    }

    struct Update: Identifiable, Equatable, Sendable {
        let name: String
        let currentCommit: String?
        let latestCommit: String

        var id: String { name }
    }

    struct ProjectSkills: Identifiable {
        let project: Project
        let catalog: SkillCatalog

        var id: URL { project.directory }
    }

    let directory: URL
    private let projectsProvider: @MainActor () -> [Project]
    private let fetcher: any SkillRepositoryFetching
    private let tokenProvider: @MainActor () -> String?
    private let policyProvider: @MainActor () -> NetworkAccessPolicy
    private let workingRoot: URL

    private(set) var global: SkillCatalog
    private(set) var projects: [ProjectSkills] = []
    private(set) var provenance: [String: Provenance] = [:]
    private(set) var updates: [String: Update] = [:]
    private(set) var updateErrors: [String: String] = [:]
    private(set) var lastRefreshed: Date?
    private(set) var lastUpdateCheck: Date?

    init(
        directory: URL,
        projects: @escaping @MainActor () -> [Project] = { [] },
        catalog: SkillCatalog? = nil,
        fetcher: any SkillRepositoryFetching = GitSkillRepositoryFetcher(),
        token: @escaping @MainActor () -> String? = { nil },
        policy: @escaping @MainActor () -> NetworkAccessPolicy = { NetworkAccessPolicy() },
        workingRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PokeetSkillFetches", isDirectory: true)
    ) {
        self.directory = directory
        self.projectsProvider = projects
        self.fetcher = fetcher
        self.tokenProvider = token
        self.policyProvider = policy
        self.workingRoot = workingRoot
        self.global = catalog ?? SkillCatalog(skills: [])
    }

    var globalIssues: [SkillIssue] { global.issues }

    func refresh() async {
        let directory = self.directory
        let projectDirectories = projectsProvider().map { (project: $0, root: $0.directory) }

        let scanned = await Task.detached(priority: .utility) {
            (
                global: SkillCatalog.load(userSkillsDirectory: directory),
                provenance: Self.loadProvenance(in: directory),
                projects: projectDirectories.map { entry in
                    (
                        project: entry.project,
                        catalog: SkillCatalog.load(projectRoot: entry.root, userSkillsDirectory: nil)
                    )
                }
            )
        }.value

        global = scanned.global
        projects = scanned.projects.map { ProjectSkills(project: $0.project, catalog: $0.catalog) }
        provenance = scanned.provenance
        lastRefreshed = Date()
    }

    // MARK: - Import

    /// Validates a picked folder without copying it, so the sheet can say what will land
    /// before anything is written.
    func preview(of url: URL) async -> SkillCatalog.Inspection {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            return SkillCatalog.inspect(url, source: .user)
        }.value
    }

    @discardableResult
    func importSkill(from url: URL, replacing: String? = nil) async throws -> Skill {
        let directory = self.directory
        let existing = Set(global.skills.map(\.name))

        let installed = try await Task.detached(priority: .userInitiated) {
            try Self.install(from: url, into: directory, replacing: replacing, existing: existing)
        }.value

        await refresh()
        return installed
    }

    /// The whole import, off the main actor: validate into a staging folder, inspect it with
    /// the same rules discovery uses, then swap it into place. Nothing touches the live tree
    /// until every check has passed.
    nonisolated private static func install(
        from url: URL,
        into directory: URL,
        replacing: String?,
        existing: Set<String>
    ) throws -> Skill {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SkillImportError.failed("That item is no longer there. Pick it again.")
        }

        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let staged: URL
        if isDirectory.boolValue {
            try validate(url)
            staged = staging.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            do {
                try FileManager.default.copyItem(at: url, to: staged)
            } catch {
                throw SkillImportError.failed("Could not copy the picked folder: \(error.localizedDescription)")
            }
        } else {
            guard url.pathExtension.lowercased() == "md" else {
                throw SkillImportError.invalid([SkillIssue(
                    path: url.lastPathComponent,
                    message: "Only a folder with a SKILL.md, or a single .md file, can be imported"
                )])
            }
            try validateSingleFile(url)
            let folder = staging.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            staged = folder
            do {
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("SKILL.md"))
            } catch {
                throw SkillImportError.failed("Could not copy the picked file: \(error.localizedDescription)")
            }
        }

        let inspection = SkillCatalog.inspect(staged, source: .user)
        guard let skill = inspection.skill else {
            throw SkillImportError.invalid(inspection.issues)
        }

        if let replacing {
            guard replacing == skill.name else {
                throw SkillImportError.nameMismatch(expected: replacing, found: skill.name)
            }
        } else if existing.contains(skill.name) || FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(skill.name).path
        ) {
            throw SkillImportError.nameTaken(skill.name)
        }

        // The folder name always follows the skill name, so `skill://<name>/` and the
        // directory can never disagree.
        let named = staging.appendingPathComponent(skill.name, isDirectory: true)
        if staged.standardizedFileURL != named.standardizedFileURL {
            try FileManager.default.moveItem(at: staged, to: named)
        }

        let target = directory.appendingPathComponent(skill.name, isDirectory: true)
        let backup = directory.appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = FileManager.default.fileExists(atPath: target.path)
        if hadPrevious {
            try FileManager.default.moveItem(at: target, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: named, to: target)
        } catch {
            if hadPrevious {
                try? FileManager.default.moveItem(at: backup, to: target)
            }
            throw SkillImportError.failed("Could not install the skill: \(error.localizedDescription)")
        }
        if hadPrevious {
            try? FileManager.default.removeItem(at: backup)
        }

        guard let installed = SkillCatalog.inspect(target, source: .user).skill else {
            throw SkillImportError.failed("The skill was copied but could not be read back. Try importing it again.")
        }
        return installed
    }

    nonisolated private static func validate(_ directory: URL) throws {
        var issues: [SkillIssue] = []
        var fileCount = 0
        var totalBytes = 0

        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw SkillImportError.failed("Could not read the picked folder.")
        }

        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                issues.append(SkillIssue(
                    path: item.lastPathComponent,
                    message: "Contains a symbolic link, which cannot be imported"
                ))
                continue
            }
            guard values?.isRegularFile == true else { continue }
            fileCount += 1
            totalBytes += values?.fileSize ?? 0
        }

        if fileCount > maxFiles {
            issues.append(SkillIssue(
                path: directory.lastPathComponent,
                message: "Too many files (\(fileCount)); a skill should have at most \(maxFiles)"
            ))
        }
        if totalBytes > maxBytes {
            issues.append(SkillIssue(
                path: directory.lastPathComponent,
                message: "Too large (\(totalBytes) bytes); a skill should be under \(maxBytes)"
            ))
        }
        guard issues.isEmpty else { throw SkillImportError.invalid(issues) }
    }

    nonisolated private static func validateSingleFile(_ file: URL) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxBytes else {
            throw SkillImportError.invalid([SkillIssue(
                path: file.lastPathComponent,
                message: "Too large (\(size) bytes); a skill should be under \(maxBytes)"
            )])
        }
    }

    // MARK: - Repository import

    func fetchRepository(
        _ raw: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RemoteSkillRepository {
        try await SkillRepositoryImport.fetch(
            raw,
            policy: policyProvider(),
            using: fetcher,
            token: tokenProvider(),
            in: workingRoot,
            progress: progress
        )
    }

    /// Installs the picked skills from a fetched clone. All or nothing: a clash anywhere in
    /// the selection refuses the batch, so a half-imported repository is not a state anyone
    /// has to reason about.
    @discardableResult
    func importSkills(
        from repository: RemoteSkillRepository,
        names: [String],
        replacingExisting: Bool = false
    ) async throws -> [Skill] {
        let selected = names.compactMap { repository.skill(named: $0) }
        guard !selected.isEmpty else {
            throw SkillImportError.failed("Pick at least one skill to import.")
        }

        if !replacingExisting {
            let existing = Set(global.skills.map(\.name))
            let clash = selected.first { skill in
                existing.contains(skill.name)
                    || FileManager.default.fileExists(atPath: directory.appendingPathComponent(skill.name).path)
            }
            if let clash {
                throw SkillImportError.nameTaken(clash.name)
            }
        }

        var installed: [Skill] = []
        do {
            for skill in selected {
                let copy = try await importSkill(
                    from: skill.fileURL.deletingLastPathComponent(),
                    replacing: replacingExisting ? skill.name : nil
                )
                installed.append(copy)
                var updated = provenance
                updated[copy.name] = Provenance(
                    repository: repository.source.url.absoluteString,
                    ref: repository.source.ref,
                    commit: repository.commit,
                    path: skill.location,
                    importedAt: Date()
                )
                provenance = updated
                saveProvenance()
            }
        } catch {
            for skill in installed {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(skill.name, isDirectory: true)
                )
                provenance.removeValue(forKey: skill.name)
            }
            saveProvenance()
            await refresh()
            throw error
        }

        await refresh()
        return installed
    }

    func provenance(for name: String) -> Provenance? {
        provenance[name]
    }

    // MARK: - Updates

    /// One remote handshake per repository, not per skill: a repo that ships five skills is
    /// asked once. Failures are collected, never thrown — a check is a nicety, not an action.
    func checkForUpdates() async {
        guard !provenance.isEmpty else {
            updates = [:]
            updateErrors = [:]
            lastUpdateCheck = Date()
            return
        }

        let groups = Dictionary(grouping: provenance) { name, entry in
            Self.sourceKey(entry)
        }

        var found: [String: Update] = [:]
        var failures: [String: String] = [:]
        for (key, entries) in groups {
            guard let entry = entries.first?.value else { continue }
            do {
                let source = try SkillSourceURL.parse(Self.rawSource(entry))
                let latest = try await SkillRepositoryImport.latestCommit(
                    source,
                    policy: policyProvider(),
                    using: fetcher,
                    token: tokenProvider()
                )
                guard let latest else { continue }
                for (name, provenance) in entries where provenance.commit != latest {
                    found[name] = Update(
                        name: name,
                        currentCommit: provenance.commit,
                        latestCommit: latest
                    )
                }
            } catch {
                failures[key] = error.localizedDescription
            }
        }

        updates = found
        updateErrors = failures
        lastUpdateCheck = Date()
    }

    /// Re-fetches the repository and installs just this skill again, keeping its provenance
    /// current so the next check is quiet.
    @discardableResult
    func update(_ name: String) async throws -> Skill {
        guard let entry = provenance[name] else {
            throw SkillImportError.notImported(name)
        }

        let repository = try await fetchRepository(Self.rawSource(entry))
        defer { repository.remove() }

        guard repository.skill(named: name) != nil else {
            throw SkillImportError.failed(
                "The repository no longer contains \"\(name)\". Delete the local copy if it is gone for good."
            )
        }

        let imported = try await importSkills(
            from: repository,
            names: [name],
            replacingExisting: true
        )
        updates.removeValue(forKey: name)
        guard let skill = imported.first else {
            throw SkillImportError.failed("Could not install the update.")
        }
        return skill
    }

    private static func rawSource(_ entry: Provenance) -> String {
        guard let ref = entry.ref, !ref.isEmpty else { return entry.repository }
        return "\(entry.repository)#\(ref)"
    }

    private static func sourceKey(_ entry: Provenance) -> String {
        "\(entry.repository)#\(entry.ref ?? "")"
    }

    /// Replaces a global skill's `SKILL.md` with edited text. The whole folder is copied first,
    /// so bundled references survive, and the copy is validated before the live folder is
    /// swapped — an edit that would break the skill cannot land.
    @discardableResult
    func saveSkill(_ name: String, text: String) async throws -> Skill {
        guard let existing = global.skill(named: name), existing.source == .user else {
            throw SkillImportError.notEditable(name)
        }

        let directory = self.directory
        let source = directory.appendingPathComponent(name, isDirectory: true)
        let staged = try await Task.detached(priority: .userInitiated) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("skill-edit-\(UUID().uuidString)", isDirectory: true)
            let copy = root.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: copy)
                try text.write(
                    to: copy.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw SkillImportError.failed("Could not stage the edit: \(error.localizedDescription)")
            }
            return copy
        }.value
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

        let inspection = SkillCatalog.inspect(staged, source: .user)
        guard let skill = inspection.skill else {
            throw SkillImportError.invalid(inspection.issues)
        }
        guard skill.name == name else {
            throw SkillImportError.nameMismatch(expected: name, found: skill.name)
        }

        return try await importSkill(from: staged, replacing: name)
    }

    // MARK: - Delete

    func delete(_ skill: Skill) async throws {
        guard skill.source == .user else {
            throw SkillImportError.notRemovable(skill.location)
        }
        try await delete(named: skill.name)
    }

    func delete(named name: String) async throws {
        guard global.skill(named: name) != nil else {
            throw SkillImportError.notRemovable(name)
        }
        let target = directory.appendingPathComponent(name, isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                throw SkillImportError.failed("Could not delete \"\(name)\": \(error.localizedDescription)")
            }
        }.value
        if provenance.removeValue(forKey: name) != nil {
            saveProvenance()
        }
        await refresh()
    }

    // MARK: - Provenance storage

    nonisolated private static var provenanceFileName: String { ".sources.json" }

    nonisolated private static func loadProvenance(in directory: URL) -> [String: Provenance] {
        let url = directory.appendingPathComponent(provenanceFileName)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: Provenance].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveProvenance() {
        let url = directory.appendingPathComponent(Self.provenanceFileName)
        guard !provenance.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(provenance) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
