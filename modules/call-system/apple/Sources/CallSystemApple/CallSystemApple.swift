@preconcurrency import AVFAudio
@preconcurrency import CallKit
import Foundation

public enum CallSystemAudioRoute: Sendable, Equatable {
    case receiver
    case speaker
    case wiredHeadset
    case bluetooth
}

/// Typed events emitted by the CallKit/AVFAudio backend. `Data` appears only
/// for actual PCM16 audio frames.
public enum CallSystemEvent: Sendable, Equatable {
    case incomingReported(requestID: String, callID: String)
    case outgoingReported(requestID: String, callID: String)
    case userAnswered(callID: String)
    case userRejected(callID: String)
    case userEnded(callID: String)
    case audioActivated(callID: String)
    case audioDeactivated(callID: String)
    case audioInterrupted(callID: String, shouldResume: Bool)
    case routeChanged(route: CallSystemAudioRoute)
    case audioFrame(
        callID: String,
        pcm16: Data,
        sampleRate: UInt32,
        channelCount: UInt32,
        sequence: UInt64,
        timestampMs: Int64
    )
    case mutedChanged(callID: String, muted: Bool)
    case failed(requestID: String?, code: String, message: String)
}

public typealias CallSystemEventSink = @MainActor @Sendable (CallSystemEvent) -> Void

/// Platform capability values exposed without leaking CallKit or AVFAudio objects.
public struct CallSystemCapabilitySnapshot: Sendable, Equatable {
    public let incomingCallUI: Bool
    public let backgroundAudio: Bool
    public let voiceProcessing: Bool
    public let bluetoothRoutes: Bool

    public init(
        incomingCallUI: Bool,
        backgroundAudio: Bool,
        voiceProcessing: Bool,
        bluetoothRoutes: Bool
    ) {
        self.incomingCallUI = incomingCallUI
        self.backgroundAudio = backgroundAudio
        self.voiceProcessing = voiceProcessing
        self.bluetoothRoutes = bluetoothRoutes
    }
}

@MainActor
public final class CallSystemAppleBackend: NSObject {
    public nonisolated static var capabilitySnapshot: CallSystemCapabilitySnapshot {
        CallSystemCapabilitySnapshot(
            incomingCallUI: true,
            backgroundAudio: true,
            voiceProcessing: true,
            bluetoothRoutes: true
        )
    }

    private struct IncomingAudioFrame {
        var sequence: UInt64
        var timestampMillis: UInt64
        var pcm16: Data
        var sampleRate: Double
        var channelCount: UInt32
    }

    private let eventSink: CallSystemEventSink
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

    public init(eventSink: @escaping CallSystemEventSink) {
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

    public func reportIncoming(
        requestID: String,
        callID: String,
        peerID: String,
        displayName: String
    ) {
        perform(requestID: requestID, callID: callID, peerID: peerID) {
            try reportIncomingImpl(
                requestID: requestID,
                callID: callID,
                peerID: peerID,
                displayName: displayName
            )
        }
    }

    public func reportOutgoing(
        requestID: String,
        callID: String,
        peerID: String,
        displayName: String
    ) {
        perform(requestID: requestID, callID: callID, peerID: peerID) {
            try startOutgoingImpl(
                requestID: requestID,
                callID: callID,
                peerID: peerID,
                displayName: displayName
            )
        }
    }

    public func activateAudio(requestID: String, callID: String) {
        perform(requestID: requestID, callID: callID) {
            try remoteAnsweredImpl(requestID: requestID, callID: callID)
        }
    }

    public func deactivateAudio(requestID: String, callID: String) {
        perform(requestID: requestID, callID: callID) {
            try remoteEndedImpl(requestID: requestID, callID: callID)
        }
    }

    public func setMuted(requestID: String, callID: String, muted: Bool) {
        perform(requestID: requestID, callID: callID) {
            try setMutedImpl(requestID: requestID, callID: callID, muted: muted)
        }
    }

    public func setRoute(requestID: String, route: CallSystemAudioRoute) {
        _ = route
        emit(.failed(
            requestID: requestID,
            code: "commandFailed",
            message: BackendError.systemOwnsRoute.description
        ))
    }

    public func playAudio(
        requestID: String,
        callID: String,
        pcm16: Data,
        sampleRate: UInt32,
        channelCount: UInt32,
        sequence: UInt64,
        timestampMs: Int64
    ) {
        perform(requestID: requestID, callID: callID) {
            try playAudioImpl(
                requestID: requestID,
                callID: callID,
                pcm16: pcm16,
                sampleRate: sampleRate,
                channelCount: channelCount,
                sequence: sequence,
                timestampMs: timestampMs
            )
        }
    }

    public func end(requestID: String, callID: String, reason: String) {
        perform(requestID: requestID, callID: callID) {
            try endImpl(requestID: requestID, callID: callID, reason: reason)
        }
    }

    public func shutdown() {
        mediaAllowed = false
        callKitAudioActive = false
        stopAudio()
        provider.invalidate()
    }

    private func reportIncomingImpl(
        requestID: String,
        callID callIDText: String,
        peerID: String,
        displayName: String
    ) throws {
        try validate(requestID: requestID)
        let callID = try parseCallID(callIDText)
        guard !peerID.isEmpty else { throw BackendError.invalidPeerID }
        guard !displayName.isEmpty else { throw BackendError.missingField("displayName") }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerID)
        update.localizedCallerName = displayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.emit(.failed(
                        requestID: requestID,
                        code: "incomingCallReportFailed",
                        message: String(describing: error)
                    ))
                } else {
                    self.activeCallID = callID
                    self.activePeerID = peerID
                    self.mediaAllowed = false
                    self.emit(.incomingReported(
                        requestID: requestID,
                        callID: Self.semanticCallID(callID)
                    ))
                }
            }
        }
    }

    private func startOutgoingImpl(
        requestID: String,
        callID callIDText: String,
        peerID: String,
        displayName: String
    ) throws {
        try validate(requestID: requestID)
        let callID = try parseCallID(callIDText)
        guard !peerID.isEmpty else { throw BackendError.invalidPeerID }
        guard !displayName.isEmpty else { throw BackendError.missingField("displayName") }
        let action = CXStartCallAction(call: callID, handle: CXHandle(type: .generic, value: peerID))
        callController.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.emit(.failed(
                        requestID: requestID,
                        code: "transactionFailed",
                        message: String(describing: error)
                    ))
                } else {
                    self.activeCallID = callID
                    self.activePeerID = peerID
                    self.mediaAllowed = false
                    self.emit(.outgoingReported(
                        requestID: requestID,
                        callID: Self.semanticCallID(callID)
                    ))
                }
            }
        }
    }

    private func endImpl(requestID: String, callID callIDText: String, reason: String) throws {
        try validate(requestID: requestID)
        let callID = try parseCallID(callIDText)
        guard !reason.isEmpty else { throw BackendError.missingField("reason") }
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
                    self?.emit(.failed(
                        requestID: requestID,
                        code: "transactionFailed",
                        message: String(describing: error)
                    ))
                }
            }
        }
    }

    private func remoteAnsweredImpl(requestID: String, callID callIDText: String) throws {
        try validate(requestID: requestID)
        let callID = try parseCallID(callIDText)
        provider.reportOutgoingCall(with: callID, connectedAt: .now)
        activeCallID = callID
        try prepareAudio()
        mediaAllowed = true
        startAudio()
    }

    private func remoteEndedImpl(requestID: String, callID callIDText: String) throws {
        try validate(requestID: requestID)
        let callID = try parseCallID(callIDText)
        provider.reportCall(with: callID, endedAt: .now, reason: .remoteEnded)
        if activeCallID == callID {
            mediaAllowed = false
            stopAudio()
            activeCallID = nil
            activePeerID = nil
        }
        emit(.audioDeactivated(callID: Self.semanticCallID(callID)))
    }

    private func setMutedImpl(requestID: String, callID callIDText: String, muted: Bool) throws {
        try validate(requestID: requestID)
        let callID = try parseCallID(callIDText)
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted))) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.emit(.failed(
                        requestID: requestID,
                        code: "transactionFailed",
                        message: String(describing: error)
                    ))
                }
            }
        }
    }

    private func prepareAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setPreferredSampleRate(48_000)
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
                        self.emit(.audioFrame(
                            callID: Self.semanticCallID(callID),
                            pcm16: pcm,
                            sampleRate: UInt32(sampleRate.rounded()),
                            channelCount: 1,
                            sequence: self.audioSequence,
                            timestampMs: Int64(clamping: Self.nowMillis)
                        ))
                    }
                }
                tapInstalled = true
            }
            try engine.start()
            player.play()
            engineRunning = true
            emit(.audioActivated(callID: Self.semanticCallID(callID)))
        } catch {
            emit(.failed(
                requestID: nil,
                code: "audioFailed",
                message: String(describing: error)
            ))
        }
    }

    private func playAudioImpl(
        requestID: String,
        callID callIDText: String,
        pcm16: Data,
        sampleRate: UInt32,
        channelCount: UInt32,
        sequence: UInt64,
        timestampMs: Int64
    ) throws {
        try validate(requestID: requestID)
        let callID = try parseCallID(callIDText)
        guard callID == activeCallID else { throw BackendError.inactiveCall }
        guard !pcm16.isEmpty else { throw BackendError.invalidAudio }
        guard timestampMs >= 0 else { throw BackendError.missingAudioMetadata }
        let timestampMillis = UInt64(timestampMs)
        let sampleRate = Double(sampleRate)
        guard channelCount == 1 else { throw BackendError.unsupportedChannelCount }
        guard pcm16.count.isMultiple(of: MemoryLayout<Int16>.size), sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 96_000 else {
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
            pcm16: pcm16,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        if nextPlaybackSequence == nil || !jitterPrimed, let minimum = jitterFrames.keys.min() {
            nextPlaybackSequence = minimum
        }
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
                emit(.failed(
                    requestID: nil,
                    code: "audioFrameDropped",
                    message: String(describing: error)
                ))
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
        _ = callID
        _ = from
        _ = through
        _ = reason
    }

    private func resetJitterBuffer(reason: String) {
        _ = reason
        jitterDeadlineTask?.cancel()
        jitterDeadlineTask = nil
        jitterFrames.removeAll()
        nextPlaybackSequence = nil
        lastPlayedSequence = nil
        jitterPrimed = false
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

    private func perform(
        requestID: String,
        callID: String? = nil,
        peerID: String? = nil,
        operation: () throws -> Void
    ) {
        do {
            try operation()
        } catch {
            emit(.failed(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error)
            ))
        }
    }

    private func validate(requestID: String) throws {
        guard !requestID.isEmpty else { throw BackendError.missingField("requestID") }
    }

    private func parseCallID(_ text: String) throws -> UUID {
        let unprefixed = text.hasPrefix("call_") ? String(text.dropFirst("call_".count)) : text
        let simple = unprefixed.replacingOccurrences(of: "-", with: "")
        guard simple.count == 32,
              simple.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                      || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
              }),
              let callID = UUID(uuidString: Self.hyphenatedUUID(simple))
        else { throw BackendError.invalidCallID }
        return callID
    }

    private func emitRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let description = (route.outputs + route.inputs)
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
            .lowercased()
        emit(.routeChanged(route: Self.semanticRoute(from: description)))
    }

    private func emit(_ event: CallSystemEvent) {
        eventSink(event)
    }

    private nonisolated static func semanticCallID(_ callID: UUID) -> String {
        "call_" + callID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private nonisolated static func semanticRoute(from route: String) -> CallSystemAudioRoute {
        if route.contains("bluetooth") { return .bluetooth }
        if route.contains("headphone") || route.contains("headset") || route.contains("usb") {
            return .wiredHeadset
        }
        if route.contains("speaker") { return .speaker }
        return .receiver
    }

    private nonisolated static func hyphenatedUUID(_ simple: String) -> String {
        let characters = Array(simple)
        return String(characters[0..<8]) + "-"
            + String(characters[8..<12]) + "-"
            + String(characters[12..<16]) + "-"
            + String(characters[16..<20]) + "-"
            + String(characters[20..<32])
    }

    @objc private func routeChanged(_ notification: Notification) {
        _ = notification
        emitRoute()
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let callID = activeCallID else { return }
        let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        let shouldResume: Bool
        switch type {
        case .began:
            shouldResume = false
            engine.pause()
            player.pause()
            engineRunning = false
        case .ended:
            shouldResume = true
            startAudio()
        case nil:
            shouldResume = false
        @unknown default:
            shouldResume = false
        }
        emit(.audioInterrupted(
            callID: Self.semanticCallID(callID),
            shouldResume: shouldResume
        ))
    }

    @objc private func mediaServicesReset(_ notification: Notification) {
        _ = notification
        stopAudio()
        emit(.failed(
            requestID: nil,
            code: "mediaServicesReset",
            message: "AVAudioSession media services were reset"
        ))
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

    private enum BackendError: Error, CustomStringConvertible {
        case invalidCallID, invalidPeerID, inactiveCall, invalidAudio, unsupportedChannelCount
        case missingAudioMetadata, missingField(String), systemOwnsRoute
        var description: String {
            switch self {
            case .invalidCallID: "callID must be a UUID"
            case .invalidPeerID: "peerID is required"
            case .inactiveCall: "audio frame does not belong to the active call"
            case .invalidAudio: "invalid PCM16 audio frame"
            case .unsupportedChannelCount: "only mono PCM16 audio is supported"
            case .missingAudioMetadata: "audio sequence and timestampMs are required and nonnegative"
            case let .missingField(field): "\(field) is required"
            case .systemOwnsRoute: "AVAudioSession and system UI own route selection"
            }
        }
    }
}

extension CallSystemAppleBackend: CXProviderDelegate {
    nonisolated public func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.mediaAllowed = false
            self?.callKitAudioActive = false
            self?.stopAudio()
            self?.activeCallID = nil
            self?.activePeerID = nil
            self?.emit(.failed(
                requestID: nil,
                code: "providerReset",
                message: "CallKit provider was reset"
            ))
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
            } catch {
                action.fail()
                self.emit(.failed(
                    requestID: nil,
                    code: "audioFailed",
                    message: String(describing: error)
                ))
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
                self.emit(.userAnswered(callID: Self.semanticCallID(action.callUUID)))
            } catch {
                action.fail()
                self.emit(.failed(
                    requestID: nil,
                    code: "audioFailed",
                    message: String(describing: error)
                ))
            }
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            let programmatic = self.programmaticEndCallIDs.remove(action.callUUID) != nil
            self.mediaAllowed = false
            self.stopAudio()
            if !programmatic {
                self.emit(.userEnded(callID: Self.semanticCallID(action.callUUID)))
            }
            self.activeCallID = nil
            self.activePeerID = nil
            action.fulfill()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            self?.isMuted = action.isMuted
            self?.emit(.mutedChanged(
                callID: Self.semanticCallID(action.callUUID),
                muted: action.isMuted
            ))
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
            if let callID = self?.activeCallID {
                self?.emit(.audioDeactivated(callID: Self.semanticCallID(callID)))
            }
        }
    }
}
