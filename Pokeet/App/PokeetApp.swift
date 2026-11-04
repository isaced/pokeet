import SwiftUI

@main
struct PokeetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .onChange(of: scenePhase) { _, phase in
                    handle(phase)
                }
        }
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            environment.runs.applicationDidBecomeActive()
        case .background:
            // Claim the grace period the system grants before suspending, so a run in flight
            // can finish streaming instead of dying with the process.
            environment.runs.applicationDidEnterBackground()
        default:
            environment.runs.checkpointAll()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Builds the environment now so the notification delegate is installed before a
        // cold-start tap is delivered.
        _ = AppEnvironment.shared
        return true
    }
}
