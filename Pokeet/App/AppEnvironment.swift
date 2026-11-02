import Foundation
import Observation
import PokeetCore

@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let projects: ProjectStore
    let sessions: SessionStore
    let git: any GitServicing

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
    }
}
