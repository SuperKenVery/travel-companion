@preconcurrency import Network
import Foundation
import OSLog
import WiFiAware

private let wifiAwareRuntimeLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "WiFiAwareRuntime"
)

extension WAPublishableService {
    static var travelValidationData: WAPublishableService {
        allServices["_tc-validate._tcp"]!
    }

    static var travelValidationVoice: WAPublishableService {
        allServices["_tc-voice._udp"]!
    }
}

extension WASubscribableService {
    static var travelValidationData: WASubscribableService {
        allServices["_tc-validate._tcp"]!
    }

    static var travelValidationVoice: WASubscribableService {
        allServices["_tc-voice._udp"]!
    }
}

typealias ValidationDataCoder = Coder<DataPlaneMessage, DataPlaneMessage, NetworkJSONCoder>
typealias ValidationDataConnection = NetworkConnection<ValidationDataCoder>
typealias ValidationVoiceCoder = Coder<VoicePacket, VoicePacket, NetworkJSONCoder>
typealias ValidationVoiceConnection = NetworkConnection<ValidationVoiceCoder>

struct WiFiAwareExperimentStatus: Sendable, Equatable {
    var pairedDeviceNames: [String] = []
    var dataPublisherState = "未启动"
    var voicePublisherState = "未启动"
    var discoveryState = "未启动"
    var connectionState = "未连接"
    var dataConnectionCount = 0
    var voiceConnectionCount = 0
    var lastError: String?
}

actor WiFiAwareExperiment {
    typealias EventSink = @Sendable (ExperimentRecord) async -> Void
    typealias MessageSink = @Sendable (DataPlaneMessage) async -> Void
    typealias VoiceSink = @Sendable (VoicePacket) async -> Void
    typealias StatusSink = @Sendable (WiFiAwareExperimentStatus) async -> Void

    private let deviceID: UUID
    private let displayName: String
    private let eventStore: ValidationEventStore
    private let transferStore: ResourceTransferStore
    private let eventSink: EventSink
    private let tlsConfiguration: ValidationTLSConfiguration?
    private let tlsConfigurationError: String?
    private var messageSink: MessageSink?
    private var voiceSink: VoiceSink?
    private var statusSink: StatusSink?

    private var dataConnections: [String: ValidationDataConnection] = [:]
    private var voiceConnections: [String: ValidationVoiceConnection] = [:]
    private var readyDataConnectionIDs: Set<String> = []
    private var readyVoiceConnectionIDs: Set<String> = []
    private var voiceEndpointKeys: Set<String> = []
    private var pairedDevicesTask: Task<Void, Never>?
    private var publisherTasks: [Task<Void, Never>] = []
    private var subscriberTasks: [Task<Void, Never>] = []
    private var connectionTasks: [Task<Void, Never>] = []
    private var pingStarts: [UUID: ContinuousClock.Instant] = [:]
    private var transferStarts: [UUID: ContinuousClock.Instant] = [:]
    private var outgoingResources: [UUID: (ResourceManifest, URL)] = [:]
    private var status = WiFiAwareExperimentStatus()
    private var isRunning = false
    private var isPublishing = false

    init(
        deviceID: UUID,
        displayName: String,
        eventStore: ValidationEventStore,
        transferStore: ResourceTransferStore,
        eventSink: @escaping EventSink
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.eventStore = eventStore
        self.transferStore = transferStore
        self.eventSink = eventSink
        do {
            tlsConfiguration = try ValidationTLSConfiguration.load()
            tlsConfigurationError = nil
        } catch {
            tlsConfiguration = nil
            tlsConfigurationError = String(describing: error)
            wifiAwareRuntimeLogger.error(
                "TLS configuration load failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    func setMessageSink(_ sink: @escaping MessageSink) {
        messageSink = sink
    }

    func setVoiceSink(_ sink: @escaping VoiceSink) {
        voiceSink = sink
    }

    func setStatusSink(_ sink: @escaping StatusSink) async {
        statusSink = sink
        await sink(status)
    }

    func start() async {
        wifiAwareRuntimeLogger.notice("experiment start begin")
        guard !isRunning else { return }
        guard WACapabilities.supportedFeatures.contains(.wifiAware) else {
            status.lastError = "当前设备不支持 Wi‑Fi Aware"
            await emitStatus()
            await record(name: "capability", phase: "start", outcome: .failure, metadata: ["reason": "wifiAwareUnsupported"])
            return
        }
        isRunning = true
        await record(
            name: "capability",
            phase: "start",
            outcome: .success,
            metadata: [
                "maxDevices": String(WACapabilities.maximumConnectableDevices),
                "maxPublishServices": String(WACapabilities.maximumPublishableServices),
                "maxSubscribeServices": String(WACapabilities.maximumSubscribableServices)
            ]
        )
        startPairedDeviceObservation()
        wifiAwareRuntimeLogger.notice("experiment start end; no publisher or browser started")
    }

    func stop() async {
        isRunning = false
        isPublishing = false
        pairedDevicesTask?.cancel()
        pairedDevicesTask = nil
        publisherTasks.forEach { $0.cancel() }
        publisherTasks.removeAll()
        subscriberTasks.forEach { $0.cancel() }
        subscriberTasks.removeAll()
        connectionTasks.forEach { $0.cancel() }
        connectionTasks.removeAll()
        dataConnections.removeAll()
        voiceConnections.removeAll()
        readyDataConnectionIDs.removeAll()
        readyVoiceConnectionIDs.removeAll()
        voiceEndpointKeys.removeAll()
        status.dataPublisherState = "未启动"
        status.voicePublisherState = "未启动"
        status.discoveryState = "未启动"
        status.connectionState = "未连接"
        status.dataConnectionCount = 0
        status.voiceConnectionCount = 0
        await emitStatus()
        await record(name: "lifecycle", phase: "stop", outcome: .success)
    }

    func startPublishing() async {
        wifiAwareRuntimeLogger.notice("publisher explicit start begin")
        guard isRunning else {
            status.lastError = "请先开始全部验证，再启动 Wi‑Fi Aware 服务"
            await emitStatus()
            await record(name: "publisher", phase: "start", outcome: .failure, metadata: ["reason": "labNotRunning"])
            return
        }
        publisherTasks.forEach { $0.cancel() }
        publisherTasks.removeAll()
        isPublishing = true
        status.lastError = nil
        status.dataPublisherState = "启动中"
        status.voicePublisherState = "启动中"
        await emitStatus()
        startDataListener()
        startVoiceListener()
        wifiAwareRuntimeLogger.notice("publisher explicit start tasks created")
    }

    func connectPickedEndpoint(_ endpoint: WAEndpoint) async {
        guard isRunning else {
            status.lastError = "请先开始全部验证，再查找另一台设备"
            await emitStatus()
            await record(name: "dataConnection", phase: "select", outcome: .failure, metadata: ["reason": "labNotRunning"])
            return
        }
        guard let tlsConfiguration else {
            let error = tlsConfigurationError ?? "TLS configuration unavailable"
            status.lastError = error
            status.connectionState = "TLS 配置失败"
            await emitStatus()
            await record(name: "dataConnection", phase: "tlsConfiguration", outcome: .failure, metadata: ["error": error])
            return
        }
        let peerName = endpoint.device.name ?? String(endpoint.device.id)
        wifiAwareRuntimeLogger.notice("picker selected peer=\(peerName, privacy: .public)")
        status.lastError = nil
        status.discoveryState = "已选择 \(peerName)"
        status.connectionState = "正在连接 \(peerName)"
        await emitStatus()
        let connection = ValidationDataConnection(
            to: endpoint,
            using: .parameters {
                Coder(DataPlaneMessage.self, using: NetworkJSONCoder()) {
                    tlsConfiguration.protocolOptions()
                }
            }
            .wifiAware { $0.performanceMode = .bulk }
            .serviceClass(.bestEffort)
            .localOnly(true)
            .noProxiesPreferred(true)
        )
        attachDataConnection(connection, source: "pairingPicker")
        await startVoiceBrowser(for: endpoint.device)
        wifiAwareRuntimeLogger.notice("picker connection tasks created peer=\(peerName, privacy: .public)")
    }

    func sendPing() async {
        let id = UUID()
        pingStarts[id] = .now
        wifiAwareRuntimeLogger.notice(
            "RTT ping send id=\(id.uuidString, privacy: .public) connections=\(self.dataConnections.count) ready=\(self.readyDataConnectionIDs.count)"
        )
        await broadcast(.ping(id: id, sentAt: .now))
    }

    @discardableResult
    func publishText(_ body: String) async -> ReplicatedTextEvent {
        let cursor = await eventStore.latestCursor()
        let event = ReplicatedTextEvent(
            id: UUID(),
            senderID: deviceID,
            sequence: cursor + 1,
            body: body,
            createdAt: .now
        )
        _ = await eventStore.append(event)
        await broadcast(.text(event))
        await record(name: "text", phase: "send", outcome: dataConnections.isEmpty ? .failure : .success)
        return event
    }

    func requestSync() async -> Bool {
        wifiAwareRuntimeLogger.notice("requestSync begin readyDataConnections=\(self.readyDataConnectionIDs.count)")
        let cursor = await eventStore.latestCursor()
        guard !dataConnections.isEmpty else {
            wifiAwareRuntimeLogger.notice("requestSync end success=false reason=noConnection")
            await record(name: "antiEntropy", phase: "pull", outcome: .failure, metadata: ["reason": "noConnection"])
            return false
        }
        await broadcast(.syncPull(after: cursor))
        await record(name: "antiEntropy", phase: "pull", outcome: .success, metadata: ["cursor": String(cursor)])
        wifiAwareRuntimeLogger.notice("requestSync end success=true cursor=\(cursor)")
        return true
    }

    func sendResource(byteCount: Int) async {
        do {
            let (manifest, fileURL) = try await transferStore.prepareOutgoing(byteCount: byteCount)
            outgoingResources[manifest.id] = (manifest, fileURL)
            transferStarts[manifest.id] = .now
            await broadcast(.resourceManifest(manifest))
            let chunks = try await transferStore.chunks(for: manifest, fileURL: fileURL)
            for chunk in chunks {
                if Task.isCancelled { return }
                await broadcast(.resourceChunk(chunk))
            }
            await record(
                name: "largeFile",
                phase: "chunksSent",
                outcome: .success,
                byteCount: byteCount,
                metadata: ["resourceID": manifest.id.uuidString, "chunks": String(chunks.count)]
            )
        } catch {
            await record(name: "largeFile", phase: "send", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }

    func sendNearbyToken(peerID: UUID, requestID: UUID, token: Data) async {
        await broadcast(.nearbyToken(senderID: deviceID, peerID: peerID, requestID: requestID, token: token))
    }

    func sendVoice(_ packet: VoicePacket) async {
        guard !voiceConnections.isEmpty else {
            await record(name: "voicePacket", phase: "send", outcome: .failure, metadata: ["reason": "noRealtimeConnection"])
            return
        }
        for connection in voiceConnections.values {
            do {
                try await connection.send(packet)
            } catch {
                await record(name: "voicePacket", phase: "send", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
    }

    func connectionCounts() -> (data: Int, voice: Int) {
        (readyDataConnectionIDs.count, readyVoiceConnectionIDs.count)
    }

    private func startPairedDeviceObservation() {
        guard pairedDevicesTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await devices in WAPairedDevice.allDevices {
                    let names = devices.values
                        .map { $0.name ?? String($0.id) }
                        .sorted()
                    await self.updatePairedDevices(names)
                    await self.record(
                        name: "pairedDevices",
                        phase: "update",
                        outcome: .info,
                        metadata: [
                            "count": String(devices.count),
                            "devices": devices.values.map { $0.name ?? String($0.id) }.sorted().joined(separator: ",")
                        ]
                    )
                }
            } catch {
                await self.pairedObservationFailed(error)
                await self.record(name: "pairedDevices", phase: "observe", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
        pairedDevicesTask = task
    }

    private func startDataListener() {
        let task = Task { [weak self] in
            guard let self else { return }
            guard let tlsConfiguration = self.tlsConfiguration else {
                await self.publisherFailed(
                    ValidationTLSError.invalidEmbeddedIdentity,
                    channel: "data"
                )
                return
            }
            do {
                let listener = try NetworkListener<ValidationDataCoder>(
                    for: .wifiAware(.connecting(to: .travelValidationData, from: .allPairedDevices)),
                    using: .parameters {
                        Coder(DataPlaneMessage.self, using: NetworkJSONCoder()) {
                            tlsConfiguration.protocolOptions()
                        }
                    }
                    .wifiAware { $0.performanceMode = .bulk }
                    .serviceClass(.bestEffort)
                    .localOnly(true)
                    .noProxiesPreferred(true)
                )
                .onStateUpdate { _, state in
                    Task { await self.logListenerState(state, name: "dataListener") }
                }
                try await listener.run { connection in
                    await self.handleDataConnection(connection, source: "listener")
                }
            } catch is CancellationError {
                return
            } catch {
                await self.publisherFailed(error, channel: "data")
                await self.record(name: "dataListener", phase: "run", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
        publisherTasks.append(task)
    }

    private func startVoiceListener() {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let listener = try NetworkListener<ValidationVoiceCoder>(
                    for: .wifiAware(
                        .connecting(
                            to: .travelValidationVoice,
                            from: .allPairedDevices,
                            datapath: .realtime
                        )
                    ),
                    using: .parameters {
                        Coder(VoicePacket.self, using: NetworkJSONCoder()) {
                            UDP()
                        }
                    }
                    .wifiAware { $0.performanceMode = .realtime }
                    .serviceClass(.interactiveVoice)
                    .localOnly(true)
                    .noProxiesPreferred(true)
                )
                .onStateUpdate { _, state in
                    Task { await self.logListenerState(state, name: "voiceListener") }
                }
                try await listener.run { connection in
                    await self.handleVoiceConnection(connection, source: "listener")
                }
            } catch is CancellationError {
                return
            } catch {
                await self.publisherFailed(error, channel: "voice")
                await self.record(name: "voiceListener", phase: "run", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
        publisherTasks.append(task)
    }

    private func startVoiceBrowser(for device: WAPairedDevice) async {
        subscriberTasks.forEach { $0.cancel() }
        subscriberTasks.removeAll()
        voiceEndpointKeys.removeAll()
        status.discoveryState = "正在查找 \(device.name ?? String(device.id)) 的语音服务"
        await emitStatus()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let browser = NetworkBrowser(
                    for: WASubscriberBrowser.wifiAware(
                        .connecting(to: .selected([device]), from: .travelValidationVoice)
                    )
                )
                .onStateUpdate { _, state in
                    Task { await self.logBrowserState(state, name: "voiceBrowser") }
                }
                try await browser.run { endpoints in
                    await self.connectVoiceEndpoints(endpoints)
                }
            } catch is CancellationError {
                return
            } catch {
                await self.discoveryFailed(error)
                await self.record(name: "voiceBrowser", phase: "run", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
        subscriberTasks.append(task)
    }

    private func connectVoiceEndpoints(_ endpoints: [WAEndpoint]) {
        for endpoint in endpoints {
            guard voiceEndpointKeys.insert(endpoint.description).inserted else { continue }
            let connection = ValidationVoiceConnection(
                to: endpoint,
                using: .parameters {
                    Coder(VoicePacket.self, using: NetworkJSONCoder()) {
                        UDP()
                    }
                }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVoice)
                .localOnly(true)
                .noProxiesPreferred(true)
            )
            attachVoiceConnection(connection, source: "browser")
        }
    }

    private func attachDataConnection(_ connection: ValidationDataConnection, source: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handleDataConnection(connection, source: source)
        }
        connectionTasks.append(task)
    }

    private func attachVoiceConnection(_ connection: ValidationVoiceConnection, source: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handleVoiceConnection(connection, source: source)
        }
        connectionTasks.append(task)
    }

    private func handleDataConnection(_ connection: ValidationDataConnection, source: String) async {
        dataConnections[connection.id] = connection
        connection.onStateUpdate { _, state in
            Task { await self.logDataConnectionState(connection, state: state, source: source) }
        }
        do {
            try await connection.send(.hello(deviceID: deviceID, name: displayName))
            for try await (message, _) in connection.messages {
                try Task.checkCancellation()
                await handle(message, on: connection)
            }
            removeDataConnection(connection)
            await emitStatus()
        } catch is CancellationError {
            removeDataConnection(connection)
            await emitStatus()
            return
        } catch {
            removeDataConnection(connection)
            status.connectionState = "数据连接已断开"
            status.lastError = String(describing: error)
            await emitStatus()
            await record(name: "dataConnection", phase: "receive", outcome: .failure, metadata: ["source": source, "error": String(describing: error)])
        }
    }

    private func handleVoiceConnection(_ connection: ValidationVoiceConnection, source: String) async {
        voiceConnections[connection.id] = connection
        connection.onStateUpdate { _, state in
            Task { await self.logVoiceConnectionState(connection, state: state, source: source) }
        }
        do {
            for try await (packet, _) in connection.messages {
                try Task.checkCancellation()
                await voiceSink?(packet)
                let latency = max(0, Date.now.timeIntervalSince(packet.sentAt) * 1_000)
                await record(
                    name: "voicePacket",
                    phase: "receive",
                    outcome: .success,
                    latencyMilliseconds: latency,
                    byteCount: packet.pcm16.count,
                    metadata: ["callID": packet.callID.uuidString, "sequence": String(packet.sequence)]
                )
            }
            removeVoiceConnection(connection)
            await emitStatus()
        } catch is CancellationError {
            removeVoiceConnection(connection)
            await emitStatus()
            return
        } catch {
            removeVoiceConnection(connection)
            status.lastError = String(describing: error)
            await emitStatus()
            await record(name: "voiceConnection", phase: "receive", outcome: .failure, metadata: ["source": source, "error": String(describing: error)])
        }
    }

    private func handle(_ message: DataPlaneMessage, on connection: ValidationDataConnection) async {
        switch message {
        case let .hello(peerID, name):
            await record(name: "hello", phase: "receive", outcome: .success, metadata: ["peerID": peerID.uuidString, "name": name])
        case let .ping(id, sentAt):
            wifiAwareRuntimeLogger.notice("RTT ping receive id=\(id.uuidString, privacy: .public)")
            do {
                try await connection.send(.pong(id: id, sentAt: sentAt))
                wifiAwareRuntimeLogger.notice("RTT pong send id=\(id.uuidString, privacy: .public)")
            } catch {
                wifiAwareRuntimeLogger.error(
                    "RTT pong send failed id=\(id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                await record(name: "smallMessage", phase: "pong", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        case let .pong(id, _):
            let latency = pingStarts.removeValue(forKey: id).map { ContinuousClock.now - $0 }
            if let latency {
                wifiAwareRuntimeLogger.notice(
                    "RTT pong receive id=\(id.uuidString, privacy: .public) latencyMilliseconds=\(latency.milliseconds, format: .fixed(precision: 3))"
                )
            } else {
                wifiAwareRuntimeLogger.error("RTT pong receive without pending ping id=\(id.uuidString, privacy: .public)")
            }
            await record(name: "smallMessage", phase: "roundTrip", outcome: latency == nil ? .failure : .success, latencyMilliseconds: latency?.milliseconds)
        case let .text(event):
            let inserted = await eventStore.append(event)
            await record(name: "text", phase: "receive", outcome: inserted ? .success : .skipped, metadata: ["deduplicated": String(!inserted)])
            if inserted { await messageSink?(message) }
        case let .syncPull(cursor):
            let events = await eventStore.events(after: cursor)
            let latest = await eventStore.latestCursor()
            do { try await connection.send(.syncBatch(events: events, latestCursor: latest)) }
            catch { await record(name: "antiEntropy", phase: "respond", outcome: .failure, metadata: ["error": String(describing: error)]) }
        case let .syncBatch(events, latest):
            var inserted = 0
            for event in events where await eventStore.append(event) { inserted += 1 }
            await record(name: "antiEntropy", phase: "receive", outcome: .success, metadata: ["received": String(events.count), "inserted": String(inserted), "latestCursor": String(latest)])
            await messageSink?(message)
        case let .resourceManifest(manifest):
            do {
                let missing = try await transferStore.accept(manifest)
                try await connection.send(.resourceMissing(resourceID: manifest.id, indexes: missing))
                await record(name: "largeFile", phase: "manifest", outcome: .success, byteCount: manifest.byteCount, metadata: ["missing": String(missing.count)])
            } catch {
                await record(name: "largeFile", phase: "manifest", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        case let .resourceMissing(resourceID, indexes):
            guard let (manifest, fileURL) = outgoingResources[resourceID] else { return }
            do {
                let chunks = try await transferStore.chunks(for: manifest, fileURL: fileURL, indexes: indexes)
                for chunk in chunks { try await connection.send(.resourceChunk(chunk)) }
                await record(name: "largeFile", phase: "resume", outcome: .success, metadata: ["chunks": String(chunks.count)])
            } catch {
                await record(name: "largeFile", phase: "resume", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        case let .resourceChunk(chunk):
            do {
                if let completion = try await transferStore.accept(chunk) {
                    try await connection.send(.resourceComplete(resourceID: completion.resourceID))
                    await record(name: "largeFile", phase: "receiveComplete", outcome: .success, byteCount: completion.byteCount, metadata: ["path": completion.url.lastPathComponent])
                }
            } catch {
                await record(name: "largeFile", phase: "chunk", outcome: .failure, metadata: ["index": String(chunk.index), "error": String(describing: error)])
            }
        case let .resourceComplete(resourceID):
            let elapsed = transferStarts.removeValue(forKey: resourceID).map { ContinuousClock.now - $0 }
            let bytes = outgoingResources.removeValue(forKey: resourceID)?.0.byteCount
            let throughput = if let bytes, let elapsed, elapsed.milliseconds > 0 {
                Double(bytes) / (elapsed.milliseconds / 1_000)
            } else { 0.0 }
            await record(name: "largeFile", phase: "acknowledged", outcome: .success, latencyMilliseconds: elapsed?.milliseconds, byteCount: bytes, metadata: ["bytesPerSecond": String(format: "%.0f", throughput)])
        case .nearbyToken:
            await messageSink?(message)
        }
    }

    private func broadcast(_ message: DataPlaneMessage) async {
        for connection in dataConnections.values {
            do {
                try await connection.send(message)
            } catch {
                await record(name: "dataConnection", phase: "send", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
    }

    private func logDataConnectionState(
        _ connection: ValidationDataConnection,
        state: NetworkChannel<ValidationDataCoder>.State,
        source: String
    ) async {
        wifiAwareRuntimeLogger.notice(
            "data connection state id=\(connection.id, privacy: .public) source=\(source, privacy: .public) state=\(String(describing: state), privacy: .public)"
        )
        if case .ready = state {
            readyDataConnectionIDs.insert(connection.id)
            status.connectionState = "已连接（Wi‑Fi Aware 数据路径 ready）"
            status.lastError = nil
        } else if state.isTerminal {
            readyDataConnectionIDs.remove(connection.id)
            status.connectionState = "未连接"
        } else {
            status.connectionState = "数据连接：\(String(describing: state))"
        }
        syncConnectionCountsIntoStatus()
        await emitStatus()
        await record(name: "dataConnection", phase: String(describing: state), outcome: state.isFailure ? .failure : .info, metadata: ["source": source])
        guard case .ready = state else { return }
        do {
            guard let path = try await connection.currentPath?.wifiAware else {
                await record(name: "pathAudit", phase: "ready", outcome: .failure, metadata: ["reason": "notWiFiAware"])
                return
            }
            let deviceName = path.endpoint.device.name ?? String(path.endpoint.device.id)
            let signal = path.performance.signalStrength.map { String(format: "%.4f", $0) } ?? "unknown"
            let capacity = path.performance.throughputCapacity.map { String(format: "%.0f", $0) } ?? "unknown"
            let activeSeconds = String(format: "%.3f", path.durationActive.milliseconds / 1_000)
            await record(
                name: "pathAudit",
                phase: "ready",
                outcome: .success,
                metadata: [
                    "device": deviceName,
                    "signal": signal,
                    "capacity": capacity,
                    "activeSeconds": activeSeconds
                ]
            )
        } catch {
            await record(name: "pathAudit", phase: "ready", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }

    private func logVoiceConnectionState(
        _ connection: ValidationVoiceConnection,
        state: NetworkChannel<ValidationVoiceCoder>.State,
        source: String
    ) async {
        if case .ready = state {
            readyVoiceConnectionIDs.insert(connection.id)
            status.discoveryState = "已找到数据与语音服务"
            status.lastError = nil
        } else if state.isTerminal {
            readyVoiceConnectionIDs.remove(connection.id)
        }
        syncConnectionCountsIntoStatus()
        await emitStatus()
        await record(name: "voiceConnection", phase: String(describing: state), outcome: state.isFailure ? .failure : .info, metadata: ["source": source])
        if case .ready = state {
            do {
                let path = try await connection.currentPath?.wifiAware
                await record(name: "voicePathAudit", phase: "ready", outcome: path == nil ? .failure : .success)
            } catch {
                await record(name: "voicePathAudit", phase: "ready", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
    }

    private func logListenerState<ApplicationProtocol>(
        _ state: NetworkListener<ApplicationProtocol>.State,
        name: String
    ) async where ApplicationProtocol: NetworkProtocolOptions {
        let value = String(describing: state)
        wifiAwareRuntimeLogger.notice("listener state name=\(name, privacy: .public) state=\(value, privacy: .public)")
        if name == "dataListener" {
            status.dataPublisherState = value
        } else {
            status.voicePublisherState = value
        }
        if state.isFailure {
            status.lastError = value
        }
        await emitStatus()
        await record(name: name, phase: String(describing: state), outcome: state.isFailure ? .failure : .info)
    }

    private func logBrowserState<Provider>(
        _ state: NetworkBrowser<Provider>.State,
        name: String
    ) async where Provider: BrowserProvider {
        status.discoveryState = String(describing: state)
        wifiAwareRuntimeLogger.notice(
            "browser state name=\(name, privacy: .public) state=\(String(describing: state), privacy: .public)"
        )
        if state.isFailure {
            status.lastError = String(describing: state)
        }
        await emitStatus()
        await record(name: name, phase: String(describing: state), outcome: state.isFailure ? .failure : .info)
    }

    private func updatePairedDevices(_ names: [String]) async {
        status.pairedDeviceNames = names
        await emitStatus()
    }

    private func publisherFailed(_ error: Error, channel: String) async {
        let description = String(describing: error)
        if channel == "data" {
            status.dataPublisherState = "失败"
        } else {
            status.voicePublisherState = "失败"
        }
        status.lastError = description
        await emitStatus()
    }

    private func discoveryFailed(_ error: Error) async {
        status.discoveryState = "查找失败"
        status.lastError = String(describing: error)
        await emitStatus()
    }

    private func pairedObservationFailed(_ error: Error) async {
        status.discoveryState = "读取已配对设备失败"
        status.lastError = String(describing: error)
        await emitStatus()
    }

    private func removeDataConnection(_ connection: ValidationDataConnection) {
        dataConnections.removeValue(forKey: connection.id)
        readyDataConnectionIDs.remove(connection.id)
        syncConnectionCountsIntoStatus()
    }

    private func removeVoiceConnection(_ connection: ValidationVoiceConnection) {
        voiceConnections.removeValue(forKey: connection.id)
        readyVoiceConnectionIDs.remove(connection.id)
        syncConnectionCountsIntoStatus()
    }

    private func syncConnectionCountsIntoStatus() {
        status.dataConnectionCount = readyDataConnectionIDs.count
        status.voiceConnectionCount = readyVoiceConnectionIDs.count
    }

    private func emitStatus() async {
        await statusSink?(status)
    }

    private func record(
        name: String,
        phase: String,
        outcome: ExperimentOutcome,
        latencyMilliseconds: Double? = nil,
        byteCount: Int? = nil,
        metadata: [String: String] = [:]
    ) async {
        await eventSink(
            ExperimentRecord(
                kind: .wifiAware,
                name: name,
                phase: phase,
                outcome: outcome,
                latencyMilliseconds: latencyMilliseconds,
                byteCount: byteCount,
                metadata: metadata
            )
        )
    }
}

private extension NetworkChannel.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var isTerminal: Bool {
        switch self {
        case .failed, .cancelled:
            true
        default:
            false
        }
    }
}

private extension NetworkListener.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension NetworkBrowser.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
