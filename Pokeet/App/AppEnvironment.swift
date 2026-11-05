import Foundation
import Observation
import PokeetCore
import PokeetPython
import PokeetScripting

@MainActor
@Observable
final class AppEnvironment {
    /// One environment for the process: the run registry outlives every screen, so it cannot
    /// be owned by a view.
    static let shared = AppEnvironment()

    let settings: AppSettings
    let projects: ProjectStore
    let sessions: SessionStore
    let git: any GitServicing & GitInspecting
    let scripting: ScriptRuntimes
    /// App-level skills shared by every project. Project skills live in the repo;
    /// this directory is the one the user keeps across clones. It is inside the
    /// container, so nothing outside the app can drop files here yet.
    let skillsDirectory: URL
    let skills: SkillsStore
    let runs = AgentRunRegistry()
    let notifier = SessionNotifier.shared
    /// Set when a notification is tapped; the session list consumes it and pushes the chat.
    private(set) var pendingSessionLink: SessionDeepLink?

    init(
        settings: AppSettings = AppSettings(),
        projects: ProjectStore = ProjectStore(),
        sessions: SessionStore? = nil,
        git: (any GitServicing & GitInspecting)? = nil,
        scripting: ScriptRuntimes? = nil,
        skillsDirectory: URL? = nil
    ) {
        self.settings = settings
        self.projects = projects
        self.sessions = sessions ?? SessionStore(directory: Self.defaultSessionsDirectory)
        self.git = git ?? SwiftGitXGitService()
        self.scripting = scripting ?? Self.makeScriptRuntimes()

        // Discovery treats a missing root as "no skills", which would make the global
        // folder impossible to find and impossible to fill: create it up front.
        let skillsDirectory = skillsDirectory ?? Self.defaultSkillsDirectory
        try? FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        self.skillsDirectory = skillsDirectory
        self.skills = SkillsStore(
            directory: skillsDirectory,
            projects: { [projects] in projects.projects }
        )

        // Taps arrive through the shared delegate, so wire it before anything can run.
        notifier.configure()
        notifier.onOpen = { [weak self] link in
            self?.pendingSessionLink = link
        }
    }

    /// Called after a skill is imported or deleted, so open chats rescan instead of waiting
    /// for the next session.
    func reloadSkillsInOpenChats() {
        runs.reloadSkills()
    }

    func consumeSessionLink(for project: Project) -> UUID? {
        guard let link = pendingSessionLink,
              link.projectDirectory.standardizedFileURL.path
                == project.directory.standardizedFileURL.path
        else {
            return nil
        }
        pendingSessionLink = nil
        return link.sessionID
    }

    static var defaultSkillsDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Pokeet/Skills", isDirectory: true)
    }

    private static var defaultSessionsDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Pokeet/Sessions", isDirectory: true)
    }

    // QuickJS runs on-device with interrupt and memory limits; see RunScriptTool.
    // CPython is registered only when its stdlib made it into the bundle: without it
    // the interpreter cannot start, and run_script should say so rather than crash.
    private static func makeScriptRuntimes() -> ScriptRuntimes {
        var runtimes: [any ScriptRuntime] = [QuickJSRuntime()]
        if let home = PythonRuntime.bundledHome() {
            runtimes.append(PythonRuntime(home: home))
        }
        return ScriptRuntimes(runtimes)
    }
}
