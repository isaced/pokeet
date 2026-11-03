import Foundation
import Observation

struct Project: Identifiable, Hashable, Sendable {
    let directory: URL
    let remoteHost: String?
    let isGitRepository: Bool

    var id: URL { directory }
    var name: String { directory.lastPathComponent }
}

enum ProjectError: Error, Sendable, Equatable, LocalizedError {
    case invalidName
    case reservedName(String)
    case creationFailed(String)
    case deletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Enter a project name."
        case .reservedName(let name):
            "\"\(name)\" is reserved. Pick another name."
        case .creationFailed(let message):
            "Could not create the project: \(message)"
        case .deletionFailed(let message):
            "Could not delete the project: \(message)"
        }
    }
}

private let excludedDirectoryNames: Set<String> = ["inbox", ".trash", ".pokeet"]
private let reservedProjectNames: Set<String> = ["inbox", ".trash", ".pokeet"]

@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private(set) var isLoading = false

    let documentsURL: URL

    init(documentsURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.documentsURL = documentsURL
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let root = documentsURL
        projects = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root)
        }.value
    }

    @discardableResult
    func projectDestination(named rawName: String) throws -> URL {
        let name = Self.sanitizedName(rawName)
        guard !name.isEmpty else {
            throw ProjectError.invalidName
        }
        guard !reservedProjectNames.contains(name.lowercased()) else {
            throw ProjectError.reservedName(name)
        }
        return uniqueDirectory(for: name)
    }

    @discardableResult
    func createEmptyProject(named rawName: String) async throws -> Project {
        let destination = try projectDestination(named: rawName)
        return try await createEmptyProject(at: destination)
    }

    @discardableResult
    func createEmptyProject(at destination: URL) async throws -> Project {
        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
        } catch {
            throw ProjectError.creationFailed(error.localizedDescription)
        }

        await refresh()

        return project(at: destination)
            ?? Project(directory: destination, remoteHost: nil, isGitRepository: false)
    }

    @discardableResult
    func createProject(named rawName: String) async throws -> Project {
        try await createEmptyProject(named: rawName)
    }

    func delete(_ project: Project) async throws {
        let directory = project.directory.standardizedFileURL
        let parent = directory.deletingLastPathComponent().standardizedFileURL
        let root = documentsURL.standardizedFileURL
        let name = directory.lastPathComponent

        guard parent == root,
              !reservedProjectNames.contains(name.lowercased())
        else {
            throw ProjectError.deletionFailed("The project is outside the projects folder.")
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            }.value
        } catch {
            throw ProjectError.deletionFailed(error.localizedDescription)
        }

        await refresh()
    }

    func project(at destination: URL) -> Project? {
        let target = destination.standardizedFileURL
        return projects.first { $0.directory.standardizedFileURL == target }
    }

    private func uniqueDirectory(for name: String) -> URL {
        var candidate = documentsURL.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = documentsURL.appendingPathComponent("\(name)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    nonisolated private static func sanitizedName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(name.prefix(80))
    }

    nonisolated private static func scan(root: URL) -> [Project] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.compactMap { url -> Project? in
            let name = url.lastPathComponent
            guard !excludedDirectoryNames.contains(name.lowercased()),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }

            let isGitRepository = fileManager.fileExists(
                atPath: url.appendingPathComponent(".git").path
            )

            return Project(
                directory: url,
                remoteHost: isGitRepository ? remoteHost(in: url) : nil,
                isGitRepository: isGitRepository
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func remoteHost(in repository: URL) -> String? {
        let configURL = repository.appendingPathComponent(".git/config")
        guard let data = try? Data(contentsOf: configURL, options: .mappedIfSafe),
              data.count < 1_000_000,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var inOrigin = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
                continue
            }
            guard inOrigin, line.hasPrefix("url = ") else { continue }

            let value = String(line.dropFirst("url = ".count))
            if value.hasPrefix("file://") || value.hasPrefix("/") {
                return "local"
            }
            return URLComponents(string: value)?.host ?? "remote"
        }
        return nil
    }
}
