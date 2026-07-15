@preconcurrency import NearbyInteraction
import Foundation
@preconcurrency import UIKit

public typealias TcRangingEventSink = @MainActor @Sendable (Data) -> Void

@MainActor
public final class TcRangingAppleBackend: NSObject {
    private struct Command: Decodable {
        var type: String
        var requestID: String?
        var peerID: String?
        var tokenBase64: String?
        var foreground: Bool?
        var reason: String?
    }

    private struct Event: Encodable {
        var type: String
        var requestID: String?
        var peerID: String?
        var tokenBase64: String?
        var distanceMeters: Float?
        var direction: Direction?
        var fields: [String: String]?
        var error: String?
    }

    private struct Direction: Encodable {
        var x: Float
        var y: Float
        var z: Float
    }

    private struct Context {
        var peerID: UUID
        var requestID: UUID
        var session: NISession
        var configuration: NINearbyPeerConfiguration?
    }

    private let eventSink: TcRangingEventSink
    private var contextsByPeer: [UUID: Context] = [:]
    private var peerBySession: [ObjectIdentifier: UUID] = [:]
    private var isForeground = false

    public init(eventSink: @escaping TcRangingEventSink) {
        self.eventSink = eventSink
        super.init()
        isForeground = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

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
            case "capability": emitCapability(requestID: command.requestID)
            case "begin": try begin(command)
            case "receiveToken": try receiveToken(command)
            case "cancel": try cancel(command)
            case "setForeground": setForeground(command.foreground ?? false, requestID: command.requestID)
            case "stopAll": stopAll(reason: command.reason ?? "requested", requestID: command.requestID)
            default: emit(.init(type: "commandFailed", requestID: command.requestID, error: "unknown command: \(command.type)"))
            }
        } catch {
            emit(.init(type: "commandFailed", requestID: command.requestID, peerID: command.peerID, error: String(describing: error)))
        }
    }

    public func shutdown() { stopAll(reason: "backendDestroyed", requestID: nil) }

    private func emitCapability(requestID: String?) {
        emit(.init(type: "capabilitySnapshot", requestID: requestID, fields: [
            "preciseDistance": String(NISession.deviceCapabilities.supportsPreciseDistanceMeasurement),
            "direction": String(NISession.deviceCapabilities.supportsDirectionMeasurement),
            "activePeerCount": String(contextsByPeer.count),
            "foreground": String(isForeground),
        ]))
    }

    private func begin(_ command: Command) throws {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else { throw BackendError.unsupported }
        guard isForeground else { throw BackendError.background }
        let (peerID, requestID) = try identifiers(command)

        if let existing = contextsByPeer[peerID], existing.requestID == requestID {
            emit(.init(type: "commandCompleted", requestID: requestID.uuidString, peerID: peerID.uuidString, fields: ["command": "begin", "reused": "true"]))
            return
        }
        if let old = contextsByPeer.removeValue(forKey: peerID) {
            peerBySession.removeValue(forKey: ObjectIdentifier(old.session))
            old.session.invalidate()
        }

        let session = NISession()
        session.delegate = self
        session.delegateQueue = .main
        let context = Context(peerID: peerID, requestID: requestID, session: session)
        contextsByPeer[peerID] = context
        peerBySession[ObjectIdentifier(session)] = peerID
        guard let token = session.discoveryToken else {
            contextsByPeer.removeValue(forKey: peerID)
            peerBySession.removeValue(forKey: ObjectIdentifier(session))
            session.invalidate()
            throw BackendError.tokenUnavailable
        }
        let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        emit(.init(
            type: "localToken",
            requestID: requestID.uuidString,
            peerID: peerID.uuidString,
            tokenBase64: tokenData.base64EncodedString(),
            fields: ["activePeerCount": String(contextsByPeer.count)]
        ))
    }

    private func receiveToken(_ command: Command) throws {
        guard isForeground else { throw BackendError.background }
        let (peerID, requestID) = try identifiers(command)
        if contextsByPeer[peerID]?.requestID != requestID {
            var beginCommand = command
            beginCommand.type = "begin"
            try begin(beginCommand)
        }
        guard var context = contextsByPeer[peerID], context.requestID == requestID else { throw BackendError.contextUnavailable }
        guard let text = command.tokenBase64, let data = Data(base64Encoded: text) else { throw BackendError.invalidToken }
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else { throw BackendError.invalidToken }
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        context.configuration = configuration
        contextsByPeer[peerID] = context
        context.session.run(configuration)
        emit(.init(type: "rangingStarted", requestID: requestID.uuidString, peerID: peerID.uuidString))
    }

    private func cancel(_ command: Command) throws {
        guard let peerText = command.peerID, let peerID = UUID(uuidString: peerText) else { throw BackendError.invalidPeerID }
        guard let context = contextsByPeer.removeValue(forKey: peerID) else {
            emit(.init(type: "commandCompleted", requestID: command.requestID, peerID: peerID.uuidString, fields: ["command": "cancel", "active": "false"]))
            return
        }
        peerBySession.removeValue(forKey: ObjectIdentifier(context.session))
        context.session.invalidate()
        emit(.init(type: "rangingStopped", requestID: command.requestID, peerID: peerID.uuidString, fields: ["reason": command.reason ?? "requested"]))
    }

    private func setForeground(_ foreground: Bool, requestID: String?) {
        isForeground = foreground
        if !foreground { stopAll(reason: "applicationBackgrounded", requestID: requestID) }
        else { emit(.init(type: "foregroundStateChanged", requestID: requestID, fields: ["foreground": "true"])) }
    }

    private func stopAll(reason: String, requestID: String?) {
        let contexts = contextsByPeer.values
        contextsByPeer.removeAll()
        peerBySession.removeAll()
        for context in contexts { context.session.invalidate() }
        emit(.init(type: "allRangingStopped", requestID: requestID, fields: ["reason": reason, "peerCount": String(contexts.count)]))
    }

    private func identifiers(_ command: Command) throws -> (UUID, UUID) {
        guard let peerText = command.peerID, let peerID = UUID(uuidString: peerText) else { throw BackendError.invalidPeerID }
        guard let requestText = command.requestID, let requestID = UUID(uuidString: requestText) else { throw BackendError.invalidRequestID }
        return (peerID, requestID)
    }

    private func context(for session: NISession) -> Context? {
        guard let peerID = peerBySession[ObjectIdentifier(session)] else { return nil }
        return contextsByPeer[peerID]
    }

    private func emit(_ event: Event) {
        if let data = try? JSONEncoder().encode(event) { eventSink(data) }
    }

    @objc private func applicationDidEnterBackground() {
        setForeground(false, requestID: nil)
    }

    @objc private func applicationDidBecomeActive() {
        setForeground(true, requestID: nil)
    }

    private enum BackendError: Error, CustomStringConvertible {
        case unsupported, background, invalidPeerID, invalidRequestID, tokenUnavailable, invalidToken, contextUnavailable
        var description: String {
            switch self {
            case .unsupported: "UWB precise distance is unsupported"
            case .background: "Nearby Interaction is foreground-only"
            case .invalidPeerID: "invalid peerID"
            case .invalidRequestID: "requestID must be a UUID"
            case .tokenUnavailable: "NISession did not provide a discovery token"
            case .invalidToken: "invalid Nearby Interaction discovery token"
            case .contextUnavailable: "ranging request context unavailable"
            }
        }
    }
}

extension TcRangingAppleBackend: @preconcurrency NISessionDelegate {
    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let context = context(for: session), let object = nearbyObjects.first else { return }
        let direction = object.direction.map { Direction(x: $0.x, y: $0.y, z: $0.z) }
        emit(.init(
            type: "measurement",
            requestID: context.requestID.uuidString,
            peerID: context.peerID.uuidString,
            distanceMeters: object.distance,
            direction: direction,
            fields: [
                "distanceAvailable": String(object.distance != nil),
                "directionAvailable": String(direction != nil),
            ]
        ))
    }

    public func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let context = context(for: session) else { return }
        emit(.init(type: "measurementUnavailable", requestID: context.requestID.uuidString, peerID: context.peerID.uuidString, fields: [
            "reason": String(describing: reason),
            "distanceAvailable": "false",
            "directionAvailable": "false",
        ]))
    }

    public func sessionWasSuspended(_ session: NISession) {
        guard let context = context(for: session) else { return }
        emit(.init(type: "rangingSuspended", requestID: context.requestID.uuidString, peerID: context.peerID.uuidString, fields: [
            "distanceAvailable": "false",
            "directionAvailable": "false",
        ]))
    }

    public func sessionSuspensionEnded(_ session: NISession) {
        guard let context = context(for: session), isForeground, let configuration = context.configuration else { return }
        session.run(configuration)
        emit(.init(type: "rangingResumed", requestID: context.requestID.uuidString, peerID: context.peerID.uuidString))
    }

    public func session(_ session: NISession, didInvalidateWith error: any Error) {
        guard let context = context(for: session) else { return }
        contextsByPeer.removeValue(forKey: context.peerID)
        peerBySession.removeValue(forKey: ObjectIdentifier(session))
        emit(.init(type: "rangingFailed", requestID: context.requestID.uuidString, peerID: context.peerID.uuidString, fields: [
            "distanceAvailable": "false",
            "directionAvailable": "false",
        ], error: String(describing: error)))
    }
}

// MARK: - Module-private C ABI

public typealias RangingCEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UInt) -> Void
private final class RangingCallbackBox: @unchecked Sendable {
    let callback: RangingCEventCallback
    let context: UInt
    init(callback: @escaping RangingCEventCallback, context: UInt) { self.callback = callback; self.context = context }
    @MainActor func send(_ data: Data) { data.withUnsafeBytes { callback($0.bindMemory(to: UInt8.self).baseAddress, data.count, context) } }
}
private final class RangingHandleSource: @unchecked Sendable {
    static let shared = RangingHandleSource()
    private let lock = NSLock()
    private var next: UInt64 = 1
    func allocate() -> UInt64 { lock.withLock { defer { next &+= 1 }; return next } }
}
@MainActor private enum RangingRuntime {
    static var backends: [UInt64: TcRangingAppleBackend] = [:]
}

@_cdecl("tc_ranging_apple_create")
public func tc_ranging_apple_create(_ callback: RangingCEventCallback?, _ context: UInt) -> UInt64 {
    guard let callback else { return 0 }
    let handle = RangingHandleSource.shared.allocate()
    let box = RangingCallbackBox(callback: callback, context: context)
    Task { @MainActor in RangingRuntime.backends[handle] = TcRangingAppleBackend(eventSink: box.send) }
    return handle
}

@_cdecl("tc_ranging_apple_submit")
public func tc_ranging_apple_submit(_ handle: UInt64, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard length >= 0, length == 0 || bytes != nil else { return false }
    let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
    Task { @MainActor in RangingRuntime.backends[handle]?.submit(data) }
    return true
}

@_cdecl("tc_ranging_apple_destroy")
public func tc_ranging_apple_destroy(_ handle: UInt64) {
    Task { @MainActor in RangingRuntime.backends.removeValue(forKey: handle)?.shutdown() }
}
