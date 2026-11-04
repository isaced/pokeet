import Foundation
import UserNotifications

/// Where a tapped notification points. The app has no server, so the session is identified
/// by the two things that survive a relaunch: the project folder and the session id.
struct SessionDeepLink: Equatable, Sendable {
    let projectDirectory: URL
    let sessionID: UUID
}

/// Local notifications for the one thing a background run cannot do on its own: ask a human
/// for approval. Everything stays on the device.
@MainActor
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotifier()

    var onOpen: (@MainActor (SessionDeepLink) -> Void)?

    private var didRequestAuthorization = false

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked for on the first run rather than at launch: the prompt only makes sense once
    /// there is a reason to leave a session working in the background.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func postApproval(project: Project, sessionID: UUID, title: String, body: String) {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = project.name
        content.userInfo = [
            "project": project.directory.path,
            "session": sessionID.uuidString
        ]
        let request = UNNotificationRequest(
            identifier: "pokeet.approval.\(sessionID.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let path = info["project"] as? String,
              let rawSession = info["session"] as? String,
              let sessionID = UUID(uuidString: rawSession)
        else { return }

        let link = SessionDeepLink(
            projectDirectory: URL(fileURLWithPath: path),
            sessionID: sessionID
        )
        Task { @MainActor in
            self.onOpen?(link)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
