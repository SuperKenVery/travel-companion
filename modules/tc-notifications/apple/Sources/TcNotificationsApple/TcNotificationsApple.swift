import Foundation
@preconcurrency import UserNotifications

public enum TcNotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

public enum TcNotificationsEvent: Sendable, Equatable {
    case authorizationChanged(status: TcNotificationAuthorization)
    case scheduled(requestID: String, identifier: String)
    case cancelled(requestID: String, identifier: String)
    case opened(identifier: String, deepLink: String?, action: String?)
    case failed(requestID: String?, code: String, message: String)
}

public typealias TcNotificationsEventSink = @MainActor @Sendable (TcNotificationsEvent) -> Void

/// Platform capability values exposed without leaking UserNotifications objects.
public struct TcNotificationsCapabilitySnapshot: Sendable, Equatable {
    public let localNotifications: Bool
    public let actions: Bool
    public let timeSensitive: Bool

    public init(localNotifications: Bool, actions: Bool, timeSensitive: Bool) {
        self.localNotifications = localNotifications
        self.actions = actions
        self.timeSensitive = timeSensitive
    }
}

/// Typed UserNotifications backend; framework objects remain MainActor-isolated.
@MainActor
public final class TcNotificationsAppleBackend: NSObject {
    public nonisolated static var capabilitySnapshot: TcNotificationsCapabilitySnapshot {
        TcNotificationsCapabilitySnapshot(
            localNotifications: true,
            actions: true,
            timeSensitive: true
        )
    }

    private let eventSink: TcNotificationsEventSink
    private let center = UNUserNotificationCenter.current()
    private weak var previousDelegate: (any UNUserNotificationCenterDelegate)?
    private var scheduledIdentifierBySemanticID: [String: String] = [:]

    public init(eventSink: @escaping TcNotificationsEventSink) {
        self.eventSink = eventSink
        super.init()
        previousDelegate = center.delegate
        center.delegate = self
    }

    public func shutdown() {
        if center.delegate === self { center.delegate = previousDelegate }
    }

    public func requestAuthorization(requestID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let settings = await center.notificationSettings()
                emit(.authorizationChanged(
                    status: Self.semanticAuthorizationStatus(settings.authorizationStatus)
                ))
            } catch {
                emitFailure(requestID: requestID, message: String(describing: error))
            }
        }
    }

    public func schedule(
        requestID: String,
        identifier: String,
        title: String,
        body: String,
        deepLink: String?,
        mergeKey: String?,
        timeSensitive: Bool
    ) {
        guard !identifier.isEmpty else {
            emitFailure(requestID: requestID, message: "identifier is required")
            return
        }
        let platformIdentifier = mergeKey ?? identifier

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = mergeKey ?? ""
        content.sound = .default
        var userInfo = [
            "semanticIdentifier": identifier,
            "timeSensitive": String(timeSensitive),
        ]
        if let deepLink { userInfo["deepLink"] = deepLink }
        content.userInfo = userInfo
        if timeSensitive { content.interruptionLevel = .timeSensitive }

        let request = UNNotificationRequest(identifier: platformIdentifier, content: content, trigger: nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                // A reused merge key intentionally replaces/coalesces the pending notification.
                try await center.add(request)
                scheduledIdentifierBySemanticID[identifier] = platformIdentifier
                emit(.scheduled(requestID: requestID, identifier: identifier))
            } catch {
                emitFailure(requestID: requestID, message: String(describing: error))
            }
        }
    }

    public func cancel(requestID: String, identifier: String) {
        guard !identifier.isEmpty else {
            emitFailure(requestID: requestID, message: "identifier is required")
            return
        }
        let platformIdentifier = scheduledIdentifierBySemanticID.removeValue(forKey: identifier) ?? identifier
        center.removePendingNotificationRequests(withIdentifiers: [platformIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [platformIdentifier])
        emit(.cancelled(requestID: requestID, identifier: identifier))
    }

    /// Cold-start/app-lifecycle response entry for callers that already extracted string userInfo.
    public func handleNotificationResponse(
        userInfo: [String: String],
        fallbackIdentifier: String? = nil,
        action: String? = nil
    ) {
        guard let identifier = userInfo["semanticIdentifier"] ?? fallbackIdentifier else { return }
        emit(.opened(identifier: identifier, deepLink: userInfo["deepLink"], action: action))
    }

    public func handleNotificationResponse(
        identifier: String,
        deepLink: String?,
        action: String?
    ) {
        emit(.opened(identifier: identifier, deepLink: deepLink, action: action))
    }

    private func emit(_ event: TcNotificationsEvent) {
        eventSink(event)
    }

    private func emitFailure(requestID: String? = nil, message: String) {
        emit(.failed(requestID: requestID, code: "commandFailed", message: message))
    }

    private nonisolated static func stringUserInfo(_ values: [AnyHashable: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            guard let key = key as? String else { return nil }
            if let string = value as? String { return (key, string) }
            if let number = value as? NSNumber { return (key, number.stringValue) }
            return nil
        })
    }

    private nonisolated static func semanticAuthorizationStatus(
        _ status: UNAuthorizationStatus
    ) -> TcNotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .authorized
        @unknown default: .notDetermined
        }
    }
}

extension TcNotificationsAppleBackend: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let fallbackIdentifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let userInfo = Self.stringUserInfo(response.notification.request.content.userInfo)
        let completion = NotificationResponseCompletion(completionHandler)
        Task { @MainActor [weak self] in
            self?.handleNotificationResponse(
                userInfo: userInfo,
                fallbackIdentifier: fallbackIdentifier,
                action: action
            )
            completion.call()
        }
    }
}

/// Delegate completion handlers are Objective-C closures without a Sendable annotation.
/// The framework owns their thread-safety; this box only transfers one handler to MainActor.
private final class NotificationResponseCompletion: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        handler()
    }
}
