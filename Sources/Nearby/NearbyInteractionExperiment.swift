@preconcurrency import NearbyInteraction
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class NearbyInteractionExperiment: NSObject {
    typealias EventSink = @Sendable (ExperimentRecord) async -> Void

    private struct Context {
        let peerID: UUID
        let requestID: UUID
        let session: NISession
        var configuration: NINearbyPeerConfiguration?
    }

    private let eventSink: EventSink
    private var contextsByPeer: [UUID: Context] = [:]
    private var peerBySession: [ObjectIdentifier: UUID] = [:]

    var onLocalToken: ((UUID, UUID, Data) -> Void)?
    private(set) var activeSessionCount = 0
    private(set) var latestDistance: Float?
    private(set) var latestDirection: SIMD3<Float>?
    private(set) var latestPeerID: UUID?
    private(set) var state = "idle"
    private(set) var observedResourceLimit: Int?
    private(set) var isForeground = true

    init(eventSink: @escaping EventSink) {
        self.eventSink = eventSink
        super.init()
    }

    var isSupported: Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    var supportsDirection: Bool {
        NISession.deviceCapabilities.supportsDirectionMeasurement
    }

    func begin(peerID: UUID, requestID: UUID) {
        guard isSupported else {
            log(name: "capability", phase: "begin", outcome: .failure, metadata: ["reason": "preciseDistanceUnsupported"])
            return
        }
        guard isForeground else {
            log(name: "session", phase: "begin", outcome: .failure, metadata: ["reason": "notForeground"])
            return
        }
        if let old = contextsByPeer.removeValue(forKey: peerID) {
            peerBySession.removeValue(forKey: ObjectIdentifier(old.session))
            old.session.invalidate()
        }
        let session = NISession()
        session.delegate = self
        session.delegateQueue = .main
        contextsByPeer[peerID] = Context(peerID: peerID, requestID: requestID, session: session)
        peerBySession[ObjectIdentifier(session)] = peerID
        activeSessionCount = contextsByPeer.count
        guard let token = session.discoveryToken else {
            log(name: "token", phase: "local", outcome: .failure, metadata: ["peerID": peerID.uuidString])
            return
        }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            onLocalToken?(peerID, requestID, data)
            state = "waiting for peer token"
            log(name: "token", phase: "local", outcome: .success, byteCount: data.count, metadata: ["peerID": peerID.uuidString, "requestID": requestID.uuidString, "concurrentSessions": String(activeSessionCount)])
        } catch {
            log(name: "token", phase: "archive", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }

    func receiveToken(from peerID: UUID, requestID: UUID, data: Data) {
        guard isForeground else {
            log(name: "token", phase: "receive", outcome: .failure, metadata: ["reason": "notForeground"])
            return
        }
        if contextsByPeer[peerID] == nil {
            begin(peerID: peerID, requestID: requestID)
        }
        guard var context = contextsByPeer[peerID] else { return }
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
                throw NearbyError.invalidToken
            }
            let configuration = NINearbyPeerConfiguration(peerToken: token)
            context.configuration = configuration
            contextsByPeer[peerID] = context
            context.session.run(configuration)
            state = "ranging"
            log(name: "token", phase: "receive", outcome: .success, byteCount: data.count, metadata: ["peerID": peerID.uuidString, "requestID": requestID.uuidString])
            log(name: "session", phase: "run", outcome: .success, metadata: ["peerID": peerID.uuidString, "concurrentSessions": String(activeSessionCount)])
        } catch {
            log(name: "token", phase: "decode", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground {
            stopAll(reason: "applicationBackgrounded")
        }
    }

    func cancel(peerID: UUID, reason: String) {
        guard let context = contextsByPeer.removeValue(forKey: peerID) else { return }
        peerBySession.removeValue(forKey: ObjectIdentifier(context.session))
        context.session.invalidate()
        activeSessionCount = contextsByPeer.count
        state = contextsByPeer.isEmpty ? "GPS fallback" : "ranging"
        log(name: "session", phase: "cancel", outcome: .success, metadata: ["peerID": peerID.uuidString, "reason": reason])
    }

    func stopAll(reason: String) {
        let count = contextsByPeer.count
        for context in contextsByPeer.values { context.session.invalidate() }
        contextsByPeer.removeAll()
        peerBySession.removeAll()
        activeSessionCount = 0
        latestDistance = nil
        latestDirection = nil
        latestPeerID = nil
        state = "GPS fallback"
        log(name: "session", phase: "stopAll", outcome: .success, metadata: ["reason": reason, "sessions": String(count)])
    }

    private func peerID(for session: NISession) -> UUID? {
        peerBySession[ObjectIdentifier(session)]
    }

    private func log(
        name: String,
        phase: String,
        outcome: ExperimentOutcome,
        latencyMilliseconds: Double? = nil,
        byteCount: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        let record = ExperimentRecord(
            kind: .uwb,
            name: name,
            phase: phase,
            outcome: outcome,
            latencyMilliseconds: latencyMilliseconds,
            byteCount: byteCount,
            metadata: metadata
        )
        Task { await eventSink(record) }
    }

    private enum NearbyError: Error { case invalidToken }
}

extension NearbyInteractionExperiment: @preconcurrency NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peerID = peerID(for: session), let object = nearbyObjects.first else { return }
        latestPeerID = peerID
        latestDistance = object.distance
        latestDirection = object.direction
        state = "ranging"
        var metadata = [
            "peerID": peerID.uuidString,
            "distanceMeters": object.distance.map { String(format: "%.3f", $0) } ?? "unavailable",
            "directionAvailable": String(object.direction != nil),
            "orientation": UIDevice.current.orientation.isLandscape ? "landscape" : "portrait"
        ]
        if let direction = object.direction {
            metadata["directionX"] = String(format: "%.4f", direction.x)
            metadata["directionY"] = String(format: "%.4f", direction.y)
            metadata["directionZ"] = String(format: "%.4f", direction.z)
        }
        log(name: "measurement", phase: "update", outcome: object.distance == nil ? .failure : .success, metadata: metadata)
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peerID = peerID(for: session) else { return }
        latestDistance = nil
        latestDirection = nil
        state = "GPS fallback"
        log(name: "measurement", phase: "removed", outcome: .failure, metadata: ["peerID": peerID.uuidString, "reason": String(describing: reason), "objects": String(nearbyObjects.count)])
    }

    func sessionWasSuspended(_ session: NISession) {
        guard let peerID = peerID(for: session) else { return }
        latestDistance = nil
        latestDirection = nil
        state = "GPS fallback"
        log(name: "session", phase: "suspended", outcome: .info, metadata: ["peerID": peerID.uuidString])
    }

    func sessionSuspensionEnded(_ session: NISession) {
        guard let peerID = peerID(for: session),
              isForeground,
              let configuration = contextsByPeer[peerID]?.configuration
        else { return }
        session.run(configuration)
        state = "ranging resumed"
        log(name: "session", phase: "resumed", outcome: .success, metadata: ["peerID": peerID.uuidString])
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let peerID = peerID(for: session) else { return }
        contextsByPeer.removeValue(forKey: peerID)
        peerBySession.removeValue(forKey: ObjectIdentifier(session))
        activeSessionCount = contextsByPeer.count
        latestDistance = nil
        latestDirection = nil
        state = "GPS fallback"
        if observedResourceLimit == nil, activeSessionCount > 0 {
            observedResourceLimit = activeSessionCount
        }
        log(name: "session", phase: "invalidated", outcome: .failure, metadata: ["peerID": peerID.uuidString, "error": String(describing: error), "activeAfterInvalidation": String(activeSessionCount)])
    }
}
