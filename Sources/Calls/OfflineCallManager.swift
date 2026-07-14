@preconcurrency import AVFAudio
@preconcurrency import CallKit
import Foundation
import Observation

@MainActor
@Observable
final class OfflineCallManager: NSObject {
    typealias EventSink = @Sendable (ExperimentRecord) async -> Void

    private let deviceID: UUID
    private let eventSink: EventSink
    private let provider: CXProvider
    private let callController = CXCallController()
    private let audioEngine: AudioCallEngine
    private var offerReceivedAt: [UUID: ContinuousClock.Instant] = [:]

    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onStartOutgoing: ((UUID) -> Void)?
    var onVoicePacket: ((VoicePacket) -> Void)? {
        didSet { audioEngine.onPacket = onVoicePacket }
    }

    private(set) var activeCallID: UUID?
    private(set) var callState = "idle"
    private(set) var lastBoundary: String?

    init(deviceID: UUID, eventSink: @escaping EventSink) {
        self.deviceID = deviceID
        self.eventSink = eventSink
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        audioEngine = AudioCallEngine(eventSink: eventSink)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func reportIncoming(callID: UUID, callerID: UUID, displayName: String) {
        offerReceivedAt[callID] = .now
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerID.uuidString)
        update.localizedCallerName = displayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let latency = self.offerReceivedAt[callID].map { ContinuousClock.now - $0 }
                if let error {
                    self.lastBoundary = String(describing: error)
                    self.callState = "incoming presentation failed"
                    self.log(name: "incomingCall", phase: "report", outcome: .failure, latencyMilliseconds: latency?.milliseconds, metadata: ["error": String(describing: error), "fallback": "missedCallOnNextLaunch"])
                } else {
                    self.activeCallID = callID
                    self.callState = "ringing"
                    self.log(name: "incomingCall", phase: "reported", outcome: .success, latencyMilliseconds: latency?.milliseconds, metadata: ["callID": callID.uuidString])
                }
            }
        }
    }

    func startOutgoing(callID: UUID, peerID: UUID) {
        let handle = CXHandle(type: .generic, value: peerID.uuidString)
        let action = CXStartCallAction(call: callID, handle: handle)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastBoundary = String(describing: error)
                    self.log(name: "outgoingCall", phase: "request", outcome: .failure, metadata: ["error": String(describing: error)])
                } else {
                    self.activeCallID = callID
                    self.callState = "connecting"
                    self.onStartOutgoing?(callID)
                    self.log(name: "outgoingCall", phase: "request", outcome: .success, metadata: ["callID": callID.uuidString])
                }
            }
        }
    }

    func end(callID: UUID) {
        let transaction = CXTransaction(action: CXEndCallAction(call: callID))
        callController.request(transaction) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log(name: "call", phase: "endRequest", outcome: .failure, metadata: ["error": String(describing: error)])
                }
            }
        }
    }

    func receive(_ packet: VoicePacket) {
        audioEngine.play(packet)
    }

    func markRemoteAnswered(callID: UUID) {
        guard activeCallID == callID else { return }
        provider.reportOutgoingCall(with: callID, connectedAt: .now)
        callState = "connected"
        prepareAudio(callID: callID)
    }

    func markRemoteEnded(callID: UUID, reason: CXCallEndedReason = .remoteEnded) {
        provider.reportCall(with: callID, endedAt: .now, reason: reason)
        if activeCallID == callID {
            audioEngine.stop()
            activeCallID = nil
            callState = "ended"
        }
    }

    private func prepareAudio(callID: UUID) {
        do {
            try audioEngine.prepare(callID: callID, deviceID: deviceID)
        } catch {
            lastBoundary = String(describing: error)
            log(name: "audioSession", phase: "prepare", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }

    private func log(
        name: String,
        phase: String,
        outcome: ExperimentOutcome,
        latencyMilliseconds: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        let record = ExperimentRecord(kind: .call, name: name, phase: phase, outcome: outcome, latencyMilliseconds: latencyMilliseconds, metadata: metadata)
        Task { await eventSink(record) }
    }
}

extension OfflineCallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.audioEngine.stop()
            self?.activeCallID = nil
            self?.callState = "reset"
            self?.log(name: "callKit", phase: "reset", outcome: .info)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            self.activeCallID = action.callUUID
            self.prepareAudio(callID: action.callUUID)
            self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: .now)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            self.activeCallID = action.callUUID
            self.callState = "answering"
            self.prepareAudio(callID: action.callUUID)
            self.onAnswer?(action.callUUID)
            action.fulfill()
            self.log(name: "incomingCall", phase: "answered", outcome: .success, metadata: ["callID": action.callUUID.uuidString])
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            self.audioEngine.stop()
            self.onEnd?(action.callUUID)
            self.activeCallID = nil
            self.callState = "ended"
            action.fulfill()
            self.log(name: "call", phase: "ended", outcome: .success, metadata: ["callID": action.callUUID.uuidString])
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.audioEngine.start()
            self?.callState = "connected"
            self?.log(name: "audioSession", phase: "activated", outcome: .success, metadata: ["sampleRate": String(audioSession.sampleRate)])
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.audioEngine.stop()
            self?.log(name: "audioSession", phase: "deactivated", outcome: .info)
        }
    }
}
