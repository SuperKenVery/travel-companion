import Foundation
import Observation
import OSLog
@preconcurrency import UserNotifications

private let localNotificationLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "LocalNotifications"
)

@MainActor
@Observable
final class LocalNotificationManager {
    private(set) var authorizationStatus = "not determined"

    func refreshAuthorization() async {
        localNotificationLogger.debug("refreshAuthorization begin")
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = String(describing: settings.authorizationStatus)
        localNotificationLogger.debug("refreshAuthorization end status=\(self.authorizationStatus, privacy: .public)")
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func precisionRequest(_ request: PendingPrecisionRequest) async {
        localNotificationLogger.notice("enqueue precision begin requestID=\(request.id.uuidString, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = "同行成员正在寻找你"
        content.body = "打开 App 后确认是否提供 UWB 精确距离和方向。"
        content.sound = .default
        content.userInfo = [
            "type": "precisionLocateRequest",
            "requestID": request.id.uuidString,
            "senderID": request.senderID.uuidString
        ]
        let notification = UNNotificationRequest(identifier: "precision-\(request.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(notification)
        localNotificationLogger.notice("enqueue precision end requestID=\(request.id.uuidString, privacy: .public)")
    }

    func synchronizedMessage(count: Int) async {
        localNotificationLogger.notice("enqueue synchronizedMessage begin count=\(count)")
        let content = UNMutableNotificationContent()
        content.title = "收到离线旅行消息"
        content.body = count == 1 ? "已通过点对点连接同步 1 条消息。" : "已通过点对点连接同步 \(count) 条消息。"
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "sync-\(UUID())", content: content, trigger: nil)
        )
        localNotificationLogger.notice("enqueue synchronizedMessage end count=\(count)")
    }

    func genericDataAvailableFailure() async {
        localNotificationLogger.notice("enqueue dataAvailableFailure begin")
        let content = UNMutableNotificationContent()
        content.title = "有新的旅行内容"
        content.body = "当前无法建立高速点对点连接，打开 App 后会自动重试同步。"
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "sync-failed-\(UUID())", content: content, trigger: nil)
        )
        localNotificationLogger.notice("enqueue dataAvailableFailure end")
    }
}
