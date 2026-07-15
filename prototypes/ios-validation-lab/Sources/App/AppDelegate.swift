import OSLog
import UIKit
@preconcurrency import UserNotifications

private let appLifecycleLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "AppLifecycle"
)

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        appLifecycleLogger.notice("didFinishLaunching begin")
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // iOS 26 reports restoration through the manager/session callbacks instead of deprecated launch keys.
        UserDefaults.standard.set("launch; inspect BLE/Core Location restoration records", forKey: "lastLaunchReason")
        appLifecycleLogger.notice("didFinishLaunching end")
        return true
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        appLifecycleLogger.notice("willPresent begin id=\(identifier, privacy: .public)")
        appLifecycleLogger.notice("willPresent end id=\(identifier, privacy: .public)")
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        let type = request.content.userInfo["type"] as? String ?? "none"
        appLifecycleLogger.notice(
            "notificationResponse begin id=\(request.identifier, privacy: .public) type=\(type, privacy: .public)"
        )
        appLifecycleLogger.debug("notificationResponse post begin")
        NotificationCenter.default.post(
            name: .precisionNotificationOpened,
            object: nil,
            userInfo: request.content.userInfo
        )
        appLifecycleLogger.debug("notificationResponse post end")
        appLifecycleLogger.notice("notificationResponse end id=\(request.identifier, privacy: .public)")
    }
}

extension Notification.Name {
    static let precisionNotificationOpened = Notification.Name("precisionNotificationOpened")
}
