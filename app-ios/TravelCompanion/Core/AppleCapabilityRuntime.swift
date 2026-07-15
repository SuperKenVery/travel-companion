import Foundation
import TcBluetoothApple
import TcCallSystemApple
import TcLocationApple
import TcNotificationsApple
import TcPeerTransportApple
import TcRangingApple
import TcSecureStorageApple

@MainActor
final class AppleCapabilityRuntime {
    typealias EventSink = @MainActor @Sendable (_ module: String, _ event: Data) -> Void

    private let relay: CapabilityEventRelay
    private let bluetooth: TcBluetoothAppleBackend
    private let peerTransport: TcPeerTransportAppleBackend
    private let location: TcLocationAppleBackend
    private let ranging: TcRangingAppleBackend
    private let notifications: TcNotificationsAppleBackend
    private let callSystem: TcCallSystemAppleBackend
    private let secureStorage: TcSecureStorageAppleBackend

    init(eventSink: @escaping EventSink) {
        let relay = CapabilityEventRelay(eventSink: eventSink)
        self.relay = relay
        bluetooth = TcBluetoothAppleBackend { [weak relay] event in
            relay?.emit(module: "bluetooth", event: event)
        }
        peerTransport = TcPeerTransportAppleBackend { [weak relay] event in
            Task { @MainActor in
                relay?.emit(module: "peerTransport", event: event)
            }
        }
        location = TcLocationAppleBackend { [weak relay] event in
            relay?.emit(module: "location", event: event)
        }
        ranging = TcRangingAppleBackend { [weak relay] event in
            relay?.emit(module: "ranging", event: event)
        }
        notifications = TcNotificationsAppleBackend { [weak relay] event in
            relay?.emit(module: "notifications", event: event)
        }
        callSystem = TcCallSystemAppleBackend { [weak relay] event in
            relay?.emit(module: "callSystem", event: event)
        }
        secureStorage = TcSecureStorageAppleBackend { [weak relay] event in
            Task { @MainActor in
                relay?.emit(module: "secureStorage", event: event)
            }
        }
    }

    func submit(module: String, command: Data) {
        switch module {
        case "bluetooth", "tc-bluetooth":
            bluetooth.submit(command)
        case "peerTransport", "tc-peer-transport":
            Task { await peerTransport.submit(command) }
        case "location", "tc-location":
            location.submit(command)
        case "ranging", "tc-ranging":
            ranging.submit(command)
        case "notifications", "tc-notifications":
            notifications.submit(command)
        case "callSystem", "tc-call-system":
            callSystem.submit(command)
        case "secureStorage", "tc-secure-storage":
            Task { await secureStorage.submit(command) }
        default:
            relay.emit(
                module: module,
                event: Self.eventData(
                    type: "commandFailed",
                    fields: ["error": "unknown Apple capability module"]
                )
            )
        }
    }

    func handleNotificationResponse(_ userInfo: [String: String]) {
        relay.emit(
            module: "notifications",
            event: Self.eventData(type: "notificationResponse", fields: ["userInfo": userInfo])
        )
    }

    func shutdown() {
        bluetooth.shutdown()
        location.shutdown()
        ranging.shutdown()
        notifications.shutdown()
        callSystem.shutdown()
        Task { await peerTransport.shutdown() }
    }

    private static func eventData(type: String, fields: [String: Any]) -> Data {
        var object = fields
        object["type"] = type
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

@MainActor
private final class CapabilityEventRelay {
    private let eventSink: AppleCapabilityRuntime.EventSink

    init(eventSink: @escaping AppleCapabilityRuntime.EventSink) {
        self.eventSink = eventSink
    }

    func emit(module: String, event: Data) {
        eventSink(module, event)
    }
}
