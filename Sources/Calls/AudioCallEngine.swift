@preconcurrency import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
final class AudioCallEngine {
    typealias EventSink = @Sendable (ExperimentRecord) async -> Void

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eventSink: EventSink
    private var callID: UUID?
    private var deviceID: UUID?
    private var sequence: UInt64 = 0
    private var tapInstalled = false

    var onPacket: ((VoicePacket) -> Void)?
    private(set) var isRunning = false
    private(set) var capturedPackets = 0
    private(set) var playedPackets = 0

    init(eventSink: @escaping EventSink) {
        self.eventSink = eventSink
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    func prepare(callID: UUID, deviceID: UUID) throws {
        self.callID = callID
        self.deviceID = deviceID
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        log(name: "audioSession", phase: "prepared", outcome: .success, metadata: [
            "sampleRate": String(session.sampleRate),
            "ioBufferDuration": String(session.ioBufferDuration),
            "route": session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        ])
    }

    func start() {
        guard !isRunning, let callID, let deviceID else { return }
        do {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            if !tapInstalled {
                input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
                    guard let pcm = Self.encodePCM16(buffer), !pcm.isEmpty else { return }
                    let sampleRate = buffer.format.sampleRate
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.sequence &+= 1
                        self.capturedPackets += 1
                        self.onPacket?(
                            VoicePacket(
                                callID: callID,
                                senderID: deviceID,
                                sequence: self.sequence,
                                sentAt: .now,
                                sampleRate: sampleRate,
                                channelCount: 1,
                                pcm16: pcm
                            )
                        )
                    }
                }
                tapInstalled = true
            }
            try engine.start()
            player.play()
            isRunning = true
            log(name: "audioEngine", phase: "start", outcome: .success, metadata: ["callID": callID.uuidString])
        } catch {
            log(name: "audioEngine", phase: "start", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }

    func play(_ packet: VoicePacket) {
        guard packet.callID == callID,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: packet.sampleRate,
                channels: 1,
                interleaved: false
              )
        else { return }
        let frameCount = AVAudioFrameCount(packet.pcm16.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?[0]
        else { return }
        buffer.frameLength = frameCount
        packet.pcm16.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frameCount))
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
        playedPackets += 1
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let callID {
            log(name: "audioEngine", phase: "stop", outcome: .success, metadata: [
                "callID": callID.uuidString,
                "capturedPackets": String(capturedPackets),
                "playedPackets": String(playedPackets)
            ])
        }
        isRunning = false
        callID = nil
        deviceID = nil
    }

    private nonisolated static func encodePCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let samples = channels[0]
        var data = Data(count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<Int(buffer.frameLength) {
                let clamped = max(-1, min(1, samples[index]))
                target[index] = Int16(clamped * Float(Int16.max))
            }
        }
        return data
    }

    private func log(
        name: String,
        phase: String,
        outcome: ExperimentOutcome,
        metadata: [String: String] = [:]
    ) {
        let record = ExperimentRecord(kind: .call, name: name, phase: phase, outcome: outcome, metadata: metadata)
        Task { await eventSink(record) }
    }
}

