@preconcurrency import NearbyInteraction
import Foundation
@preconcurrency import UIKit

public enum RangingEvent: Sendable, Equatable {
    case discoveryToken(requestID: String, token: Data)
    case started(requestID: String, peerID: String)
    case measurement(
        peerID: String,
        distanceM: Double?,
        directionRadians: Double?,
        observedAtMs: Int64
    )
    case suspended(peerID: String, reason: String)
    case ended(peerID: String, reason: String)
    case failed(requestID: String?, code: String, message: String, retryable: Bool)
}

public typealias RangingEventSink = @MainActor @Sendable (RangingEvent) -> Void

/// Platform capability values exposed without leaking Nearby Interaction objects.
public struct RangingCapabilitySnapshot: Sendable, Equatable {
    public let distance: Bool
    public let direction: Bool
    public let foregroundOnly: Bool
    public let maxConcurrentSessions: UInt32

    public init(
        distance: Bool,
        direction: Bool,
        foregroundOnly: Bool,
        maxConcurrentSessions: UInt32
    ) {
        self.distance = distance
        self.direction = direction
        self.foregroundOnly = foregroundOnly
        self.maxConcurrentSessions = maxConcurrentSessions
    }
}

@MainActor
public final class RangingAppleBackend: NSObject {
    private nonisolated static let maximumConcurrentSessions: UInt32 = 4

    public nonisolated static var capabilitySnapshot: RangingCapabilitySnapshot {
        let deviceCapabilities = NISession.deviceCapabilities
        let supportsDistance = deviceCapabilities.supportsPreciseDistanceMeasurement
        return RangingCapabilitySnapshot(
            distance: supportsDistance,
            direction: deviceCapabilities.supportsDirectionMeasurement,
            foregroundOnly: true,
            maxConcurrentSessions: supportsDistance ? maximumConcurrentSessions : 0
        )
    }

    private struct Context {
        var peerID: UUID
        var semanticPeerID: String
        var requestID: String
        var session: NISession
        var configuration: NINearbyPeerConfiguration?
        var localToken: Data
    }

    private let eventSink: RangingEventSink
    private var contextsByPeer: [UUID: Context] = [:]
    private var peerBySession: [ObjectIdentifier: UUID] = [:]
    private var isForeground = false

    public init(eventSink: @escaping RangingEventSink) {
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

    public func createDiscoveryToken(requestID: String, peerID: String) {
        do {
            try begin(requestID: requestID, peerID: peerID)
        } catch {
            emitFailure(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: false
            )
        }
    }

    public func start(requestID: String, peerID: String, remoteDiscoveryToken: Data) {
        do {
            try receiveToken(
                requestID: requestID,
                peerID: peerID,
                remoteDiscoveryToken: remoteDiscoveryToken
            )
        } catch {
            emitFailure(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: false
            )
        }
    }

    public func cancel(requestID: String, peerID: String, reason: String) {
        do {
            try cancelOperation(peerID: peerID, reason: reason)
        } catch {
            emitFailure(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: false
            )
        }
    }

    public func shutdown() { stopAll(reason: "backendDestroyed") }

    private func begin(requestID: String, peerID peerText: String) throws {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else { throw BackendError.unsupported }
        guard isForeground else { throw BackendError.background }
        let (peerID, semanticPeerID, requestID) = try identifiers(peerID: peerText, requestID: requestID)

        if let existing = contextsByPeer[peerID], existing.requestID == requestID {
            emit(.discoveryToken(requestID: requestID, token: existing.localToken))
            return
        }
        if contextsByPeer[peerID] == nil,
           contextsByPeer.count >= Int(Self.maximumConcurrentSessions) {
            throw BackendError.concurrentSessionLimit
        }
        if let old = contextsByPeer.removeValue(forKey: peerID) {
            peerBySession.removeValue(forKey: ObjectIdentifier(old.session))
            old.session.invalidate()
        }

        let session = NISession()
        session.delegate = self
        session.delegateQueue = .main
        guard let token = session.discoveryToken else {
            session.invalidate()
            throw BackendError.tokenUnavailable
        }
        let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        let context = Context(
            peerID: peerID,
            semanticPeerID: semanticPeerID,
            requestID: requestID,
            session: session,
            configuration: nil,
            localToken: tokenData
        )
        contextsByPeer[peerID] = context
        peerBySession[ObjectIdentifier(session)] = peerID
        emit(.discoveryToken(requestID: requestID, token: tokenData))
    }

    private func receiveToken(
        requestID: String,
        peerID peerText: String,
        remoteDiscoveryToken: Data
    ) throws {
        guard isForeground else { throw BackendError.background }
        let (peerID, semanticPeerID, requestID) = try identifiers(peerID: peerText, requestID: requestID)
        if contextsByPeer[peerID]?.requestID != requestID {
            try begin(requestID: requestID, peerID: peerText)
        }
        guard var context = contextsByPeer[peerID], context.requestID == requestID else { throw BackendError.contextUnavailable }
        guard let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: NIDiscoveryToken.self,
            from: remoteDiscoveryToken
        ) else { throw BackendError.invalidToken }
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        context.configuration = configuration
        contextsByPeer[peerID] = context
        context.session.run(configuration)
        emit(.started(requestID: requestID, peerID: semanticPeerID))
    }

    private func cancelOperation(peerID peerText: String, reason: String) throws {
        guard let peerID = UUID(uuidString: peerText) else { throw BackendError.invalidPeerID }
        guard let context = contextsByPeer.removeValue(forKey: peerID) else {
            emit(.ended(peerID: peerText, reason: reason))
            return
        }
        peerBySession.removeValue(forKey: ObjectIdentifier(context.session))
        context.session.invalidate()
        emit(.ended(peerID: context.semanticPeerID, reason: reason))
    }

    private func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground { stopAll(reason: "applicationBackgrounded") }
    }

    private func stopAll(reason: String) {
        let contexts = contextsByPeer.values
        contextsByPeer.removeAll()
        peerBySession.removeAll()
        for context in contexts {
            context.session.invalidate()
            emit(.ended(peerID: context.semanticPeerID, reason: reason))
        }
    }

    private func identifiers(peerID peerText: String, requestID: String) throws -> (UUID, String, String) {
        guard let peerID = UUID(uuidString: peerText) else { throw BackendError.invalidPeerID }
        guard !requestID.isEmpty else { throw BackendError.invalidRequestID }
        return (peerID, peerText, requestID)
    }

    private func context(for session: NISession) -> Context? {
        guard let peerID = peerBySession[ObjectIdentifier(session)] else { return nil }
        return contextsByPeer[peerID]
    }

    private func emit(_ event: RangingEvent) {
        eventSink(event)
    }

    private func emitFailure(
        requestID: String? = nil,
        code: String,
        message: String,
        retryable: Bool
    ) {
        emit(.failed(
            requestID: requestID,
            code: code,
            message: message,
            retryable: retryable
        ))
    }

    @objc private func applicationDidEnterBackground() {
        setForeground(false)
    }

    @objc private func applicationDidBecomeActive() {
        setForeground(true)
    }

    private enum BackendError: Error, CustomStringConvertible {
        case unsupported
        case background
        case concurrentSessionLimit
        case invalidPeerID
        case invalidRequestID
        case tokenUnavailable
        case invalidToken
        case contextUnavailable

        var description: String {
            switch self {
            case .unsupported: "UWB precise distance is unsupported"
            case .background: "Nearby Interaction is foreground-only"
            case .concurrentSessionLimit: "maximum concurrent ranging sessions reached"
            case .invalidPeerID: "invalid peerID"
            case .invalidRequestID: "requestId is required"
            case .tokenUnavailable: "NISession did not provide a discovery token"
            case .invalidToken: "invalid Nearby Interaction discovery token"
            case .contextUnavailable: "ranging request context unavailable"
            }
        }
    }
}

extension RangingAppleBackend: @preconcurrency NISessionDelegate {
    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let context = context(for: session), let object = nearbyObjects.first else { return }
        let directionRadians = object.direction.flatMap { direction -> Double? in
            let magnitude = hypot(Double(direction.x), Double(direction.z))
            return magnitude > Double.ulpOfOne
                ? atan2(Double(direction.x), Double(direction.z))
                : nil
        }
        emit(.measurement(
            peerID: context.semanticPeerID,
            distanceM: object.distance.map(Double.init),
            directionRadians: directionRadians,
            // Nearby Interaction does not expose a measurement timestamp. Rust
            // materialization replaces this sentinel with its receive time.
            observedAtMs: 0
        ))
    }

    public func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let context = context(for: session) else { return }
        emit(.measurement(
            peerID: context.semanticPeerID,
            distanceM: nil,
            directionRadians: nil,
            observedAtMs: 0
        ))
    }

    public func sessionWasSuspended(_ session: NISession) {
        guard let context = context(for: session) else { return }
        emit(.suspended(peerID: context.semanticPeerID, reason: "suspended"))
    }

    public func sessionSuspensionEnded(_ session: NISession) {
        guard let context = context(for: session), isForeground, let configuration = context.configuration else { return }
        session.run(configuration)
        emit(.started(requestID: context.requestID, peerID: context.semanticPeerID))
    }

    public func session(_ session: NISession, didInvalidateWith error: any Error) {
        guard let context = context(for: session) else { return }
        contextsByPeer.removeValue(forKey: context.peerID)
        peerBySession.removeValue(forKey: ObjectIdentifier(session))
        emitFailure(
            requestID: context.requestID,
            code: "rangingFailed",
            message: String(describing: error),
            retryable: true
        )
    }
}
