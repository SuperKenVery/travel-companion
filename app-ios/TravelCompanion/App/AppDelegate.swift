import OSLog
import UIKit
@preconcurrency import UserNotifications

private let lifecycleLogger = Logger(
    subsystem: "com.ken.TravelCompanion",
    category: "Lifecycle"
)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        lifecycleLogger.notice("Application launched")
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        await MainActor.run {
            NotificationCenter.default.post(
                name: .travelCompanionNotificationResponse,
                object: nil,
                userInfo: content.userInfo
            )
        }
    }
}

extension Notification.Name {
    static let travelCompanionNotificationResponse = Notification.Name(
        "TravelCompanionNotificationResponse"
    )
}
