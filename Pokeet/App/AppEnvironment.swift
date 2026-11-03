import Foundation
import Observation
import PokeetCore
import PokeetScripting

@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let projects: ProjectStore
    let sessions: SessionStore
    let git: any GitServicing & GitInspecting
    let scripting: ScriptRuntimes

    init() {
        settings = AppSettings()
        projects = ProjectStore()

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        sessions = SessionStore(
            directory: support.appendingPathComponent("Pokeet/Sessions", isDirectory: true)
        )

        git = SwiftGitXGitService()
        // QuickJS runs on-device with interrupt and memory limits; see RunScriptTool.
        scripting = ScriptRuntimes([QuickJSRuntime()])
    }
}
