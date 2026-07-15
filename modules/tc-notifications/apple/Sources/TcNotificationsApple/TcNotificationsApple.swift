import Foundation
@preconcurrency import UserNotifications

public typealias TcNotificationsEventSink = @MainActor @Sendable (Data) -> Void

@MainActor
public final class TcNotificationsAppleBackend: NSObject {
    private struct Command: Decodable {
        var type: String
        var requestID: String?
        var identifier: String?
        var title: String?
        var subtitle: String?
        var body: String?
        var categoryIdentifier: String?
        var threadIdentifier: String?
        var sound: Bool?
        var badge: Int?
        var delayMillis: UInt64?
        var repeats: Bool?
        var userInfo: [String: String]?
        var identifiers: [String]?
    }

    private struct Event: Encodable {
        var type: String
        var requestID: String?
        var identifier: String?
        var actionIdentifier: String?
        var userInfo: [String: String]?
        var fields: [String: String]?
        var error: String?
    }

    private let eventSink: TcNotificationsEventSink
    private let center = UNUserNotificationCenter.current()
    private weak var previousDelegate: (any UNUserNotificationCenterDelegate)?
    private var started = false
    private var scheduledIdentifierBySemanticID: [String: String] = [:]

    public init(eventSink: @escaping TcNotificationsEventSink) {
        self.eventSink = eventSink
        super.init()
        previousDelegate = center.delegate
        center.delegate = self
        started = true
    }

    public func submit(_ json: Data) {
        let command: Command
        do {
            command = try JSONDecoder().decode(Command.self, from: json)
        } catch {
            emit(.init(type: "commandFailed", error: String(describing: error)))
            return
        }
        do {
            switch command.type {
            case "start": start(requestID: command.requestID)
            case "requestAuthorization": requestAuthorization(requestID: command.requestID)
            case "settings": settings(requestID: command.requestID)
            case "schedule": try schedule(command)
            case "remove": remove(command)
            case "removeAll": removeAll(requestID: command.requestID)
            default: emit(.init(type: "commandFailed", requestID: command.requestID, error: "unknown command: \(command.type)"))
            }
        } catch {
            emit(.init(type: "commandFailed", requestID: command.requestID, identifier: command.identifier, error: String(describing: error)))
        }
    }

    public func shutdown() {
        if center.delegate === self { center.delegate = previousDelegate }
        started = false
    }

    private func start(requestID: String?) {
        if center.delegate !== self {
            previousDelegate = center.delegate
            center.delegate = self
        }
        started = true
        emit(.init(type: "commandCompleted", requestID: requestID, fields: ["command": "start"]))
        settings(requestID: nil)
    }

    private func requestAuthorization(requestID: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                self.emit(.init(type: "authorizationResult", requestID: requestID, fields: ["granted": String(granted)]))
                self.settings(requestID: nil)
            } catch {
                self.emit(.init(type: "commandFailed", requestID: requestID, error: String(describing: error)))
            }
        }
    }

    private func settings(requestID: String?) {
        Task { [weak self] in
            guard let self else { return }
            let value = await center.notificationSettings()
            self.emit(.init(type: "capabilitySnapshot", requestID: requestID, fields: [
                "authorizationStatus": String(describing: value.authorizationStatus),
                "alertSetting": String(describing: value.alertSetting),
                "soundSetting": String(describing: value.soundSetting),
                "badgeSetting": String(describing: value.badgeSetting),
                "notificationCenterSetting": String(describing: value.notificationCenterSetting),
                "lockScreenSetting": String(describing: value.lockScreenSetting),
                "started": String(self.started),
            ]))
        }
    }

    private func schedule(_ command: Command) throws {
        guard let identifier = command.identifier, !identifier.isEmpty else { throw BackendError.invalidIdentifier }
        let content = UNMutableNotificationContent()
        content.title = command.title ?? ""
        content.subtitle = command.subtitle ?? ""
        content.body = command.body ?? ""
        content.categoryIdentifier = command.categoryIdentifier ?? ""
        content.threadIdentifier = command.threadIdentifier ?? ""
        if command.sound ?? true { content.sound = .default }
        if let badge = command.badge { content.badge = NSNumber(value: badge) }
        if let info = command.userInfo { content.userInfo = info }
        if command.userInfo?["timeSensitive"]?.lowercased() == "true" {
            content.interruptionLevel = .timeSensitive
        }

        let trigger: UNNotificationTrigger?
        if let delay = command.delayMillis, delay > 0 {
            let seconds = TimeInterval(delay) / 1_000
            if command.repeats == true, seconds < 60 { throw BackendError.repeatingIntervalTooShort }
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: command.repeats ?? false)
        } else {
            trigger = nil
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        Task { [weak self] in
            guard let self else { return }
            do {
                // Reusing an identifier intentionally coalesces/replaces the pending notification.
                try await center.add(request)
                let semanticIdentifier = command.userInfo?["semanticIdentifier"] ?? identifier
                self.scheduledIdentifierBySemanticID[semanticIdentifier] = identifier
                self.emit(.init(type: "notificationScheduled", requestID: command.requestID, identifier: semanticIdentifier, fields: [
                    "coalescingKey": identifier,
                    "immediate": String(trigger == nil),
                ]))
            } catch {
                self.emit(.init(type: "commandFailed", requestID: command.requestID, identifier: identifier, error: String(describing: error)))
            }
        }
    }

    private func remove(_ command: Command) {
        let semanticIdentifiers = command.identifiers ?? command.identifier.map { [$0] } ?? []
        let identifiers = semanticIdentifiers.map { scheduledIdentifierBySemanticID[$0] ?? $0 }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        for identifier in semanticIdentifiers { scheduledIdentifierBySemanticID.removeValue(forKey: identifier) }
        emit(.init(
            type: "notificationsRemoved",
            requestID: command.requestID,
            identifier: semanticIdentifiers.count == 1 ? semanticIdentifiers[0] : nil,
            fields: ["count": String(semanticIdentifiers.count)]
        ))
    }

    private func removeAll(requestID: String?) {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        scheduledIdentifierBySemanticID.removeAll()
        emit(.init(type: "notificationsRemoved", requestID: requestID, fields: ["all": "true"]))
    }

    private func emit(_ event: Event) {
        if let data = try? JSONEncoder().encode(event) { eventSink(data) }
    }

    private static func stringUserInfo(_ values: [AnyHashable: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            guard let key = key as? String else { return nil }
            if let string = value as? String { return (key, string) }
            if let number = value as? NSNumber { return (key, number.stringValue) }
            return nil
        })
    }

    private enum BackendError: Error, CustomStringConvertible {
        case invalidIdentifier, repeatingIntervalTooShort
        var description: String {
            switch self {
            case .invalidIdentifier: "notification identifier is required"
            case .repeatingIntervalTooShort: "repeating notification interval must be at least 60 seconds"
            }
        }
    }
}

extension TcNotificationsAppleBackend: @preconcurrency UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        emit(.init(
            type: "notificationPresented",
            identifier: notification.request.identifier,
            userInfo: Self.stringUserInfo(notification.request.content.userInfo)
        ))
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        emit(.init(
            type: "notificationResponse",
            identifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: Self.stringUserInfo(response.notification.request.content.userInfo)
        ))
        completionHandler()
    }
}

// MARK: - Module-private C ABI

public typealias NotificationsCEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UInt) -> Void
private final class NotificationsCallbackBox: @unchecked Sendable {
    let callback: NotificationsCEventCallback
    let context: UInt
    init(callback: @escaping NotificationsCEventCallback, context: UInt) { self.callback = callback; self.context = context }
    @MainActor func send(_ data: Data) { data.withUnsafeBytes { callback($0.bindMemory(to: UInt8.self).baseAddress, data.count, context) } }
}
private final class NotificationsHandleSource: @unchecked Sendable {
    static let shared = NotificationsHandleSource()
    private let lock = NSLock()
    private var next: UInt64 = 1
    func allocate() -> UInt64 { lock.withLock { defer { next &+= 1 }; return next } }
}
@MainActor private enum NotificationsRuntime {
    static var backends: [UInt64: TcNotificationsAppleBackend] = [:]
}

@_cdecl("tc_notifications_apple_create")
public func tc_notifications_apple_create(_ callback: NotificationsCEventCallback?, _ context: UInt) -> UInt64 {
    guard let callback else { return 0 }
    let handle = NotificationsHandleSource.shared.allocate()
    let box = NotificationsCallbackBox(callback: callback, context: context)
    Task { @MainActor in NotificationsRuntime.backends[handle] = TcNotificationsAppleBackend(eventSink: box.send) }
    return handle
}

@_cdecl("tc_notifications_apple_submit")
public func tc_notifications_apple_submit(_ handle: UInt64, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard length >= 0, length == 0 || bytes != nil else { return false }
    let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
    Task { @MainActor in NotificationsRuntime.backends[handle]?.submit(data) }
    return true
}

@_cdecl("tc_notifications_apple_destroy")
public func tc_notifications_apple_destroy(_ handle: UInt64) {
    Task { @MainActor in NotificationsRuntime.backends.removeValue(forKey: handle)?.shutdown() }
}
