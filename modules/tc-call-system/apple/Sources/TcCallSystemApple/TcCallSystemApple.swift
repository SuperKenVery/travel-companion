@preconcurrency import AVFAudio
@preconcurrency import CallKit
import Foundation

public typealias TcCallSystemEventSink = @MainActor @Sendable (Data) -> Void

@MainActor
public final class TcCallSystemAppleBackend: NSObject {
    private struct Command: Decodable {
        var type: String
        var requestID: String?
        var callID: String?
        var peerID: String?
        var displayName: String?
        var pcm16Base64: String?
        var sampleRate: Double?
        var channelCount: UInt32?
        var sequence: UInt64?
        var timestampMillis: UInt64?
        var reason: String?
        var muted: Bool?
    }

    private struct Event: Encodable {
        var type: String
        var requestID: String?
        var callID: String?
        var peerID: String?
        var pcm16Base64: String?
        var sampleRate: Double?
        var channelCount: UInt32?
        var sequence: UInt64?
        var timestampMillis: UInt64?
        var fields: [String: String]?
        var error: String?
    }

    private struct IncomingAudioFrame {
        var sequence: UInt64
        var timestampMillis: UInt64
        var pcm16: Data
        var sampleRate: Double
        var channelCount: UInt32
    }

    private let eventSink: TcCallSystemEventSink
    private let provider: CXProvider
    private let callController = CXCallController()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var activeCallID: UUID?
    private var activePeerID: String?
    private var programmaticEndCallIDs: Set<UUID> = []
    private var callKitAudioActive = false
    private var mediaAllowed = false
    private var isMuted = false
    private var audioSequence: UInt64 = 0
    private var tapInstalled = false
    private var engineRunning = false
    private var jitterFrames: [UInt64: IncomingAudioFrame] = [:]
    private var nextPlaybackSequence: UInt64?
    private var lastPlayedSequence: UInt64?
    private var jitterPrimed = false
    private var jitterDeadlineTask: Task<Void, Never>?

    private static let jitterTargetDepth = 3
    private static let jitterMaximumDepth = 12
    private static let jitterMaximumWait: Duration = .milliseconds(60)

    public init(eventSink: @escaping TcCallSystemEventSink) {
        self.eventSink = eventSink
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaServicesReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
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
            case "reportIncoming": try reportIncoming(command)
            case "startOutgoing": try startOutgoing(command)
            case "end": try end(command)
            case "remoteAnswered": try remoteAnswered(command)
            case "remoteEnded": try remoteEnded(command)
            case "playAudio": try playAudio(command)
            case "setMuted": try setMuted(command)
            case "snapshot": snapshot(requestID: command.requestID)
            default: emit(.init(type: "commandFailed", requestID: command.requestID, error: "unknown command: \(command.type)"))
            }
        } catch {
            emit(.init(type: "commandFailed", requestID: command.requestID, callID: command.callID, peerID: command.peerID, error: String(describing: error)))
        }
    }

    public func shutdown() {
        mediaAllowed = false
        callKitAudioActive = false
        stopAudio()
        provider.invalidate()
    }

    private func reportIncoming(_ command: Command) throws {
        let callID = try requiredCallID(command)
        guard let peerID = command.peerID, !peerID.isEmpty else { throw BackendError.invalidPeerID }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerID)
        update.localizedCallerName = command.displayName ?? peerID
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.emit(.init(type: "incomingCallReportFailed", requestID: command.requestID, callID: callID.uuidString, peerID: peerID, error: String(describing: error)))
                } else {
                    self.activeCallID = callID
                    self.activePeerID = peerID
                    self.mediaAllowed = false
                    self.emit(.init(type: "incomingCallReported", requestID: command.requestID, callID: callID.uuidString, peerID: peerID))
                }
            }
        }
    }

    private func startOutgoing(_ command: Command) throws {
        let callID = try requiredCallID(command)
        guard let peerID = command.peerID, !peerID.isEmpty else { throw BackendError.invalidPeerID }
        let action = CXStartCallAction(call: callID, handle: CXHandle(type: .generic, value: peerID))
        callController.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.emit(.init(type: "transactionFailed", requestID: command.requestID, callID: callID.uuidString, error: String(describing: error)))
                } else {
                    self.activeCallID = callID
                    self.activePeerID = peerID
                    self.mediaAllowed = false
                    self.emit(.init(type: "outgoingCallRequested", requestID: command.requestID, callID: callID.uuidString, peerID: peerID))
                }
            }
        }
    }

    private func end(_ command: Command) throws {
        let callID = try requiredCallID(command)
        programmaticEndCallIDs.insert(callID)
        if activeCallID == callID {
            mediaAllowed = false
            stopAudio()
        }
        callController.request(CXTransaction(action: CXEndCallAction(call: callID))) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.programmaticEndCallIDs.remove(callID)
                    self?.mediaAllowed = true
                    self?.startAudio()
                    self?.emit(.init(type: "transactionFailed", requestID: command.requestID, callID: callID.uuidString, error: String(describing: error)))
                }
            }
        }
    }

    private func remoteAnswered(_ command: Command) throws {
        let callID = try requiredCallID(command)
        provider.reportOutgoingCall(with: callID, connectedAt: .now)
        activeCallID = callID
        try prepareAudio()
        mediaAllowed = true
        startAudio()
        emit(.init(type: "audioActivationRequested", requestID: command.requestID, callID: callID.uuidString))
    }

    private func remoteEnded(_ command: Command) throws {
        let callID = try requiredCallID(command)
        provider.reportCall(with: callID, endedAt: .now, reason: Self.endReason(command.reason))
        if activeCallID == callID {
            mediaAllowed = false
            stopAudio()
            activeCallID = nil
            activePeerID = nil
        }
        emit(.init(type: "audioDeactivationRequested", requestID: command.requestID, callID: callID.uuidString, fields: ["reason": command.reason ?? "remoteEnded"]))
    }

    private func setMuted(_ command: Command) throws {
        let callID = try requiredCallID(command)
        let muted = command.muted ?? true
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))) { [weak self] error in
            Task { @MainActor in
                if let error { self?.emit(.init(type: "transactionFailed", requestID: command.requestID, callID: callID.uuidString, error: String(describing: error))) }
            }
        }
    }

    private func prepareAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setPreferredSampleRate(48_000)
        emitRoute(type: "audioPrepared")
    }

    private func startAudio() {
        guard !engineRunning, callKitAudioActive, mediaAllowed, let callID = activeCallID else { return }
        do {
            try prepareAudio()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            if !tapInstalled {
                input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
                    guard let pcm = Self.encodePCM16(buffer), !pcm.isEmpty else { return }
                    let sampleRate = buffer.format.sampleRate
                    Task { @MainActor in
                        guard let self, self.engineRunning, !self.isMuted, self.activeCallID == callID else { return }
                        self.audioSequence &+= 1
                        self.emit(.init(
                            type: "audioFrame",
                            callID: callID.uuidString,
                            pcm16Base64: pcm.base64EncodedString(),
                            sampleRate: sampleRate,
                            channelCount: 1,
                            sequence: self.audioSequence,
                            timestampMillis: Self.nowMillis
                        ))
                    }
                }
                tapInstalled = true
            }
            try engine.start()
            player.play()
            engineRunning = true
            emitRoute(type: "audioActivated")
        } catch {
            emit(.init(type: "audioFailed", callID: callID.uuidString, error: String(describing: error)))
        }
    }

    private func playAudio(_ command: Command) throws {
        let callID = try requiredCallID(command)
        guard callID == activeCallID else { throw BackendError.inactiveCall }
        guard let encoded = command.pcm16Base64, let data = Data(base64Encoded: encoded), !data.isEmpty else { throw BackendError.invalidAudio }
        guard let sequence = command.sequence, let timestampMillis = command.timestampMillis else { throw BackendError.missingAudioMetadata }
        let sampleRate = command.sampleRate ?? 48_000
        let channelCount = command.channelCount ?? 1
        guard channelCount == 1 else { throw BackendError.unsupportedChannelCount }
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size), sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 96_000 else {
            throw BackendError.invalidAudio
        }

        if let lastPlayedSequence, sequence <= lastPlayedSequence {
            emitDropped(callID: callID, from: sequence, through: sequence, reason: "late")
            return
        }
        if let expected = nextPlaybackSequence, sequence < expected {
            emitDropped(callID: callID, from: sequence, through: sequence, reason: "late")
            return
        }
        guard jitterFrames[sequence] == nil else {
            emitDropped(callID: callID, from: sequence, through: sequence, reason: "duplicate")
            return
        }

        jitterFrames[sequence] = IncomingAudioFrame(
            sequence: sequence,
            timestampMillis: timestampMillis,
            pcm16: data,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        if nextPlaybackSequence == nil || !jitterPrimed, let minimum = jitterFrames.keys.min() {
            nextPlaybackSequence = minimum
        }
        emit(.init(
            type: "audioFrameQueued",
            requestID: command.requestID,
            callID: callID.uuidString,
            sequence: sequence,
            timestampMillis: timestampMillis,
            fields: ["byteCount": String(data.count), "queuedDepth": String(jitterFrames.count)]
        ))

        if jitterFrames.count >= Self.jitterTargetDepth {
            jitterPrimed = true
            jitterDeadlineTask?.cancel()
            jitterDeadlineTask = nil
            drainJitterBuffer(callID: callID)
        } else {
            armJitterDeadline(callID: callID)
        }
    }

    private func armJitterDeadline(callID: UUID) {
        guard jitterDeadlineTask == nil else { return }
        jitterDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: Self.jitterMaximumWait)
            guard !Task.isCancelled, let self, self.activeCallID == callID else { return }
            self.jitterDeadlineTask = nil
            self.jitterPrimed = true
            self.forceJitterProgress(callID: callID, reason: "deadline")
        }
    }

    private func drainJitterBuffer(callID: UUID) {
        guard jitterPrimed else { return }
        while let expected = nextPlaybackSequence, let frame = jitterFrames.removeValue(forKey: expected) {
            do {
                try schedule(frame)
                lastPlayedSequence = expected
            } catch {
                emit(.init(type: "audioFrameDropped", callID: callID.uuidString, sequence: expected, timestampMillis: frame.timestampMillis, fields: ["reason": "decode"], error: String(describing: error)))
            }
            nextPlaybackSequence = expected &+ 1
        }

        guard !jitterFrames.isEmpty else {
            jitterPrimed = false
            nextPlaybackSequence = nil
            jitterDeadlineTask?.cancel()
            jitterDeadlineTask = nil
            return
        }
        if jitterFrames.count >= Self.jitterMaximumDepth {
            forceJitterProgress(callID: callID, reason: "windowExceeded")
        } else {
            armJitterDeadline(callID: callID)
        }
    }

    private func forceJitterProgress(callID: UUID, reason: String) {
        guard let expected = nextPlaybackSequence, let minimum = jitterFrames.keys.min() else { return }
        if minimum > expected {
            emitDropped(callID: callID, from: expected, through: minimum - 1, reason: reason)
            nextPlaybackSequence = minimum
        }
        drainJitterBuffer(callID: callID)
    }

    private func schedule(_ frame: IncomingAudioFrame) throws {
        let channels = AVAudioChannelCount(frame.channelCount)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: frame.sampleRate, channels: channels, interleaved: false) else { throw BackendError.invalidAudio }
        let frameCount = AVAudioFrameCount(frame.pcm16.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount), let target = buffer.int16ChannelData?[0] else { throw BackendError.invalidAudio }
        buffer.frameLength = frameCount
        frame.pcm16.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress?.assumingMemoryBound(to: Int16.self) { target.update(from: source, count: Int(frameCount)) }
        }
        player.scheduleBuffer(buffer)
        if engineRunning, !player.isPlaying { player.play() }
    }

    private func emitDropped(callID: UUID, from: UInt64, through: UInt64, reason: String) {
        let count = through >= from ? through - from + 1 : 0
        emit(.init(type: "audioFramesDropped", callID: callID.uuidString, sequence: from, fields: [
            "throughSequence": String(through),
            "count": String(count),
            "reason": reason,
            "queuedDepth": String(jitterFrames.count),
        ]))
    }

    private func resetJitterBuffer(reason: String) {
        let discarded = jitterFrames.count
        jitterDeadlineTask?.cancel()
        jitterDeadlineTask = nil
        jitterFrames.removeAll()
        nextPlaybackSequence = nil
        lastPlayedSequence = nil
        jitterPrimed = false
        if discarded > 0, let callID = activeCallID {
            emit(.init(type: "audioFramesDropped", callID: callID.uuidString, fields: ["count": String(discarded), "reason": reason]))
        }
    }

    private func stopAudio() {
        resetJitterBuffer(reason: "callEnded")
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        engineRunning = false
    }

    private func snapshot(requestID: String?) {
        emit(.init(type: "capabilitySnapshot", requestID: requestID, callID: activeCallID?.uuidString, peerID: activePeerID, fields: [
            "active": String(activeCallID != nil),
            "audioEngineRunning": String(engineRunning),
            "networkAudioOwner": "tc-peer-transport",
            "maximumCallGroups": "1",
            "maximumCallsPerGroup": "1",
        ]))
        emitRoute(type: "audioRouteSnapshot", requestID: requestID)
    }

    private func requiredCallID(_ command: Command) throws -> UUID {
        guard let text = command.callID, let callID = UUID(uuidString: text) else { throw BackendError.invalidCallID }
        return callID
    }

    private func emitRoute(type: String, requestID: String? = nil) {
        let route = AVAudioSession.sharedInstance().currentRoute
        emit(.init(type: type, requestID: requestID, callID: activeCallID?.uuidString, fields: [
            "inputs": route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","),
            "outputs": route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","),
            "sampleRate": String(AVAudioSession.sharedInstance().sampleRate),
            "ioBufferDuration": String(AVAudioSession.sharedInstance().ioBufferDuration),
        ]))
    }

    private func emit(_ event: Event) {
        if let data = try? JSONEncoder().encode(event) { eventSink(data) }
    }

    @objc private func routeChanged(_ notification: Notification) {
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0.uintValue) }
        emitRoute(type: "audioRouteChanged")
        if let reason { emit(.init(type: "audioRouteReason", callID: activeCallID?.uuidString, fields: ["reason": String(describing: reason)])) }
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let callID = activeCallID else { return }
        let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        let phase: String
        switch type {
        case .began:
            phase = "began"
            engine.pause()
            player.pause()
            engineRunning = false
        case .ended:
            phase = "ended"
            startAudio()
        case nil:
            phase = "unknown"
        @unknown default:
            phase = "unknown"
        }
        emit(.init(type: "audioInterruption", callID: callID.uuidString, fields: ["phase": phase]))
    }

    @objc private func mediaServicesReset(_ notification: Notification) {
        stopAudio()
        emit(.init(type: "mediaServicesReset", callID: activeCallID?.uuidString))
    }

    private nonisolated static func encodePCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let source = channels[0]
        var result = Data(count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        result.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<Int(buffer.frameLength) {
                destination[index] = Int16(max(-1, min(1, source[index])) * Float(Int16.max))
            }
        }
        return result
    }

    private nonisolated static var nowMillis: UInt64 {
        UInt64(max(0, Date.now.timeIntervalSince1970 * 1_000))
    }

    private static func endReason(_ value: String?) -> CXCallEndedReason {
        switch value {
        case "failed": .failed
        case "unanswered": .unanswered
        case "declinedElsewhere": .declinedElsewhere
        case "answeredElsewhere": .answeredElsewhere
        default: .remoteEnded
        }
    }

    private enum BackendError: Error, CustomStringConvertible {
        case invalidCallID, invalidPeerID, inactiveCall, invalidAudio, unsupportedChannelCount, missingAudioMetadata
        var description: String {
            switch self {
            case .invalidCallID: "callID must be a UUID"
            case .invalidPeerID: "peerID is required"
            case .inactiveCall: "audio frame does not belong to the active call"
            case .invalidAudio: "invalid PCM16 audio frame"
            case .unsupportedChannelCount: "only mono PCM16 audio is supported"
            case .missingAudioMetadata: "audio sequence and timestampMillis are required"
            }
        }
    }
}

extension TcCallSystemAppleBackend: CXProviderDelegate {
    nonisolated public func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.mediaAllowed = false
            self?.callKitAudioActive = false
            self?.stopAudio()
            self?.activeCallID = nil
            self?.activePeerID = nil
            self?.emit(.init(type: "providerReset"))
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            self.activeCallID = action.callUUID
            self.activePeerID = action.handle.value
            self.mediaAllowed = false
            do {
                try self.prepareAudio()
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: .now)
                action.fulfill()
                self.emit(.init(type: "startSignalingRequested", callID: action.callUUID.uuidString, peerID: action.handle.value))
            } catch {
                action.fail()
                self.emit(.init(type: "audioFailed", callID: action.callUUID.uuidString, error: String(describing: error)))
            }
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            self.activeCallID = action.callUUID
            self.mediaAllowed = true
            do {
                try self.prepareAudio()
                action.fulfill()
                self.emit(.init(type: "answerSignalingRequested", callID: action.callUUID.uuidString, peerID: self.activePeerID))
            } catch {
                action.fail()
                self.emit(.init(type: "audioFailed", callID: action.callUUID.uuidString, error: String(describing: error)))
            }
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            let programmatic = self.programmaticEndCallIDs.remove(action.callUUID) != nil
            self.mediaAllowed = false
            self.stopAudio()
            if programmatic {
                self.emit(.init(type: "callEnded", callID: action.callUUID.uuidString, peerID: self.activePeerID))
            } else {
                self.emit(.init(type: "endSignalingRequested", callID: action.callUUID.uuidString, peerID: self.activePeerID))
            }
            self.activeCallID = nil
            self.activePeerID = nil
            action.fulfill()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            self?.isMuted = action.isMuted
            self?.emit(.init(type: "muteChanged", callID: action.callUUID.uuidString, fields: ["muted": String(action.isMuted)]))
            action.fulfill()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.callKitAudioActive = true
            self?.startAudio()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.callKitAudioActive = false
            self?.stopAudio()
            self?.emit(.init(type: "audioDeactivated", callID: self?.activeCallID?.uuidString))
        }
    }
}

// MARK: - Module-private C ABI

public typealias CallSystemCEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UInt) -> Void
private final class CallSystemCallbackBox: @unchecked Sendable {
    let callback: CallSystemCEventCallback
    let context: UInt
    init(callback: @escaping CallSystemCEventCallback, context: UInt) { self.callback = callback; self.context = context }
    @MainActor func send(_ data: Data) { data.withUnsafeBytes { callback($0.bindMemory(to: UInt8.self).baseAddress, data.count, context) } }
}
private final class CallSystemHandleSource: @unchecked Sendable {
    static let shared = CallSystemHandleSource()
    private let lock = NSLock()
    private var next: UInt64 = 1
    func allocate() -> UInt64 { lock.withLock { defer { next &+= 1 }; return next } }
}
@MainActor private enum CallSystemRuntime {
    static var backends: [UInt64: TcCallSystemAppleBackend] = [:]
}

@_cdecl("tc_call_system_apple_create")
public func tc_call_system_apple_create(_ callback: CallSystemCEventCallback?, _ context: UInt) -> UInt64 {
    guard let callback else { return 0 }
    let handle = CallSystemHandleSource.shared.allocate()
    let box = CallSystemCallbackBox(callback: callback, context: context)
    Task { @MainActor in CallSystemRuntime.backends[handle] = TcCallSystemAppleBackend(eventSink: box.send) }
    return handle
}

@_cdecl("tc_call_system_apple_submit")
public func tc_call_system_apple_submit(_ handle: UInt64, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard length >= 0, length == 0 || bytes != nil else { return false }
    let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
    Task { @MainActor in CallSystemRuntime.backends[handle]?.submit(data) }
    return true
}

@_cdecl("tc_call_system_apple_destroy")
public func tc_call_system_apple_destroy(_ handle: UInt64) {
    Task { @MainActor in CallSystemRuntime.backends.removeValue(forKey: handle)?.shutdown() }
}
