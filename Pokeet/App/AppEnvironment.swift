import Observation
import PokeetCore

@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let projects: ProjectStore
    let git: any GitServicing

    init() {
        settings = AppSettings()
        projects = ProjectStore()
        git = SwiftGitXGitService()
    }
}
