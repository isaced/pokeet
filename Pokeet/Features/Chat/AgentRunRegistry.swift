import Foundation
import Observation

/// Keeps one `SessionRuntime` per conversation for the lifetime of the app.
///
/// The registry is what makes leaving a chat harmless: the screen goes away, the runtime
/// keeps its run and its transcript, and the next `ChatView` for the same session attaches
/// to the same object instead of starting a second agent against the same files.
@MainActor
@Observable
final class AgentRunRegistry {
    struct SessionKey: Hashable, Sendable {
        let project: URL
        let sessionID: UUID
    }

    /// How long an idle, unwatched runtime sticks around before its memory is given back.
    static let idleTimeout: TimeInterval = 10 * 60
    private static let sweepInterval: Duration = .seconds(60)

    private var runtimes: [SessionKey: SessionRuntime] = [:]
    private var sweeper: Task<Void, Never>?

    func runtime(
        for project: Project,
        session: SessionMetadata,
        environment: AppEnvironment
    ) -> SessionRuntime {
        let key = SessionKey(project: project.directory, sessionID: session.id)
        if let existing = runtimes[key] {
            return existing
        }
        let runtime = SessionRuntime(project: project, session: session, environment: environment)
        runtimes[key] = runtime
        startSweeping()
        return runtime
    }

    /// The runtime for a session, without creating one — the session list uses this to show
    /// which conversations are still working.
    func existing(for project: Project, sessionID: UUID) -> SessionRuntime? {
        runtimes[SessionKey(project: project.directory, sessionID: sessionID)]
    }

    func discard(for project: Project, sessionID: UUID) {
        let key = SessionKey(project: project.directory, sessionID: sessionID)
        guard let runtime = runtimes.removeValue(forKey: key) else { return }
        runtime.stop()
    }

    func applicationDidEnterBackground() {
        for runtime in runtimes.values {
            runtime.applicationDidEnterBackground()
        }
    }

    func applicationDidBecomeActive() {
        for runtime in runtimes.values {
            runtime.applicationDidBecomeActive()
        }
    }

    func checkpointAll() {
        for runtime in runtimes.values {
            runtime.checkpointNow()
        }
    }

    private func startSweeping() {
        guard sweeper == nil else { return }
        sweeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AgentRunRegistry.sweepInterval)
                guard !Task.isCancelled else { return }
                guard self != nil else { return }
                await self?.sweep()
            }
        }
    }

    private func sweep() async {
        let now = Date()
        let idle = runtimes.filter { _, runtime in
            runtime.isDetached
                && !runtime.isRunning
                && now.timeIntervalSince(runtime.lastActivity) > Self.idleTimeout
        }
        for (key, runtime) in idle {
            runtimes.removeValue(forKey: key)
            await runtime.saveBeforeRelease()
        }
    }
}
