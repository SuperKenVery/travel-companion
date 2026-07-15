@preconcurrency import Network
import Foundation
import OSLog

private let peerToPeerRuntimeLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "PeerToPeerRuntime"
)

typealias ValidationDataCoder = Coder<DataPlaneMessage, DataPlaneMessage, NetworkJSONCoder>
typealias ValidationDataConnection = NetworkConnection<ValidationDataCoder>
typealias ValidationVoiceCoder = Coder<AuthenticatedVoicePacket, AuthenticatedVoicePacket, NetworkJSONCoder>
typealias ValidationVoiceConnection = NetworkConnection<ValidationVoiceCoder>

struct PeerToPeerTransportStatus: Sendable, Equatable {
    var discoveredMemberNames: [String] = []
    var dataPublisherState = "未启动"
    var voicePublisherState = "未启动"
    var discoveryState = "未启动"
    var connectionState = "未连接"
    var dataConnectionCount = 0
    var voiceConnectionCount = 0
    var lastError: String?
}

actor PeerToPeerTransport {
    private static let dataServiceType = "_tc-validate._tcp"
    private static let voiceServiceType = "_tc-voice._udp"

    typealias EventSink = @Sendable (ExperimentRecord) async -> Void
    typealias MessageSink = @Sendable (DataPlaneMessage) async -> Void
    typealias VoiceSink = @Sendable (VoicePacket) async -> Void
    typealias StatusSink = @Sendable (PeerToPeerTransportStatus) async -> Void

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
    private var authenticatedDataConnectionIDs: Set<String> = []
    private var authenticatedPeerByDataConnectionID: [String: UUID] = [:]
    private var dataConnectionSources: [String: String] = [:]
    private var lastDataActivity: [String: String] = [:]
    private var readyVoiceConnectionIDs: Set<String> = []
    private var dataEndpointKeys: Set<String> = []
    private var voiceEndpointKeys: Set<String> = []
    private var availableDataEndpoints: [String: Bonjour.Endpoint] = [:]
    private var availableVoiceEndpoints: [String: Bonjour.Endpoint] = [:]
    private var dataConnectionEndpointKeys: [String: String] = [:]
    private var voiceConnectionEndpointKeys: [String: String] = [:]
    private var publisherTasks: [Task<Void, Never>] = []
    private var subscriberTasks: [Task<Void, Never>] = []
    private var connectionTasks: [Task<Void, Never>] = []
    private var pingStarts: [UUID: ContinuousClock.Instant] = [:]
    private var transferStarts: [UUID: ContinuousClock.Instant] = [:]
    private var outgoingResources: [UUID: (ResourceManifest, URL)] = [:]
    private var status = PeerToPeerTransportStatus()
    private var isRunning = false
    private var groupCredentials: NearbyGroupCredentials?

    private var groupID: String? { groupCredentials?.id }

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
            peerToPeerRuntimeLogger.error(
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
        peerToPeerRuntimeLogger.notice("transport start begin")
        guard !isRunning else { return }
        isRunning = true
        await startNetworkingIfPossible()
        await record(name: "lifecycle", phase: "start", outcome: .success, metadata: ["peerToPeerIncluded": "true"])
        peerToPeerRuntimeLogger.notice("transport start end")
    }

    func configureGroup(_ credentials: NearbyGroupCredentials?) async {
        guard groupCredentials != credentials else { return }
        groupCredentials = credentials
        await resetNetworkTasks()
        await startNetworkingIfPossible()
    }

    func stop() async {
        isRunning = false
        await resetNetworkTasks()
        status.dataPublisherState = "未启动"
        status.voicePublisherState = "未启动"
        status.discoveryState = "未启动"
        status.connectionState = "未连接"
        status.dataConnectionCount = 0
        status.voiceConnectionCount = 0
        await emitStatus()
        await record(name: "lifecycle", phase: "stop", outcome: .success)
    }

    private func startNetworkingIfPossible() async {
        guard isRunning else { return }
        guard groupID != nil else {
            status.discoveryState = "等待 BLE PIN 入群"
            status.connectionState = "尚未入群"
            await emitStatus()
            return
        }
        publisherTasks.forEach { $0.cancel() }
        publisherTasks.removeAll()
        subscriberTasks.forEach { $0.cancel() }
        subscriberTasks.removeAll()
        status.lastError = nil
        status.dataPublisherState = "启动中"
        status.voicePublisherState = "启动中"
        status.discoveryState = "正在通过 Bonjour 查找群成员"
        await emitStatus()
        startDataListener()
        startVoiceListener()
        startDataBrowser()
        startVoiceBrowser()
        peerToPeerRuntimeLogger.notice("Bonjour listeners and browsers started")
    }

    func sendPing() async {
        let id = UUID()
        pingStarts[id] = .now
        peerToPeerRuntimeLogger.notice(
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
        await record(name: "text", phase: "send", outcome: authenticatedDataConnectionIDs.isEmpty ? .failure : .success)
        return event
    }

    func requestSync() async -> Bool {
        peerToPeerRuntimeLogger.notice("requestSync begin readyDataConnections=\(self.readyDataConnectionIDs.count)")
        let cursor = await eventStore.latestCursor()
        guard !authenticatedDataConnectionIDs.isEmpty else {
            peerToPeerRuntimeLogger.notice("requestSync end success=false reason=noConnection")
            await record(name: "antiEntropy", phase: "pull", outcome: .failure, metadata: ["reason": "noConnection"])
            return false
        }
        await broadcast(.syncPull(after: cursor))
        await record(name: "antiEntropy", phase: "pull", outcome: .success, metadata: ["cursor": String(cursor)])
        peerToPeerRuntimeLogger.notice("requestSync end success=true cursor=\(cursor)")
        return true
    }

    func sendResource(byteCount: Int) async {
        guard !authenticatedDataConnectionIDs.isEmpty else {
            await record(name: "largeFile", phase: "send", outcome: .failure, metadata: ["reason": "noAuthenticatedConnection"])
            return
        }
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
        let message = DataPlaneMessage.nearbyToken(
            senderID: deviceID,
            peerID: peerID,
            requestID: requestID,
            token: token
        )
        let targets = dataConnections.values.filter {
            authenticatedDataConnectionIDs.contains($0.id)
                && authenticatedPeerByDataConnectionID[$0.id] == peerID
        }
        guard !targets.isEmpty else {
            let knownPeers = Set(authenticatedPeerByDataConnectionID.values.map(\.uuidString)).sorted()
            await record(
                name: "nearbyToken",
                phase: "send",
                outcome: .failure,
                byteCount: token.count,
                metadata: [
                    "requestID": requestID.uuidString,
                    "peerID": peerID.uuidString,
                    "reason": "noAuthenticatedConnectionForPeer",
                    "authenticatedConnections": String(authenticatedDataConnectionIDs.count),
                    "knownPeers": knownPeers.joined(separator: ",")
                ]
            )
            peerToPeerRuntimeLogger.error(
                "UWB token send unavailable requestID=\(requestID.uuidString, privacy: .public) peerID=\(peerID.uuidString, privacy: .public) authenticatedConnections=\(self.authenticatedDataConnectionIDs.count)"
            )
            return
        }
        for connection in targets {
            lastDataActivity[connection.id] = "nearbyToken.send.begin:\(requestID.uuidString)"
            var metadata = dataConnectionMetadata(connection)
            metadata["requestID"] = requestID.uuidString
            metadata["peerID"] = peerID.uuidString
            do {
                peerToPeerRuntimeLogger.notice(
                    "UWB token send begin requestID=\(requestID.uuidString, privacy: .public) peerID=\(peerID.uuidString, privacy: .public) connectionID=\(connection.id, privacy: .public) bytes=\(token.count)"
                )
                try await connection.send(message)
                lastDataActivity[connection.id] = "nearbyToken.send.end:\(requestID.uuidString)"
                await record(name: "nearbyToken", phase: "send", outcome: .success, byteCount: token.count, metadata: metadata)
                peerToPeerRuntimeLogger.notice(
                    "UWB token send end requestID=\(requestID.uuidString, privacy: .public) connectionID=\(connection.id, privacy: .public)"
                )
            } catch {
                lastDataActivity[connection.id] = "nearbyToken.send.failed:\(requestID.uuidString)"
                metadata.merge(Self.errorMetadata(error)) { _, new in new }
                metadata.merge(dataConnectionMetadata(connection)) { _, new in new }
                status.lastError = metadata["error"]
                await emitStatus()
                await record(name: "nearbyToken", phase: "send", outcome: .failure, byteCount: token.count, metadata: metadata)
                peerToPeerRuntimeLogger.error(
                    "UWB token send failed requestID=\(requestID.uuidString, privacy: .public) connectionID=\(connection.id, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    func sendVoice(_ packet: VoicePacket) async {
        guard !voiceConnections.isEmpty, let groupCredentials else {
            await record(name: "voicePacket", phase: "send", outcome: .failure, metadata: ["reason": "noRealtimeConnection"])
            return
        }
        for connection in voiceConnections.values {
            do {
                let payload = Self.voiceAuthenticationPayload(packet)
                try await connection.send(
                    AuthenticatedVoicePacket(
                        packet: packet,
                        authenticationTag: groupCredentials.authenticationTag(for: payload)
                    )
                )
            } catch {
                await record(name: "voicePacket", phase: "send", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
    }

    func connectionCounts() -> (data: Int, voice: Int) {
        (authenticatedDataConnectionIDs.count, readyVoiceConnectionIDs.count)
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
                let groupID = await self.groupID
                guard let groupID else { return }
                let listener = try NetworkListener<ValidationDataCoder>(
                    for: .bonjour(
                        name: self.displayName,
                        type: Self.dataServiceType,
                        txtRecord: Self.serviceTXTRecord(groupID: groupID, deviceID: self.deviceID, displayName: self.displayName)
                    ),
                    using: .parameters {
                        Coder(DataPlaneMessage.self, using: NetworkJSONCoder()) {
                            tlsConfiguration.protocolOptions()
                        }
                    }
                    .peerToPeerIncluded(true)
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
                let groupID = await self.groupID
                guard let groupID else { return }
                let listener = try NetworkListener<ValidationVoiceCoder>(
                    for: .bonjour(
                        name: self.displayName,
                        type: Self.voiceServiceType,
                        txtRecord: Self.serviceTXTRecord(groupID: groupID, deviceID: self.deviceID, displayName: self.displayName)
                    ),
                    using: .parameters {
                        Coder(AuthenticatedVoicePacket.self, using: NetworkJSONCoder()) {
                            UDP()
                        }
                    }
                    .peerToPeerIncluded(true)
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

    private func startDataBrowser() {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let browser = NetworkBrowser(
                    for: Bonjour.bonjour(Self.dataServiceType, includeTxtRecord: true),
                    using: Self.browserParameters()
                )
                .onStateUpdate { _, state in
                    Task { await self.logBrowserState(state, name: "dataBrowser") }
                }
                try await browser.run { endpoints in
                    await self.connectDataEndpoints(endpoints)
                }
            } catch is CancellationError {
                return
            } catch {
                await self.discoveryFailed(error)
                await self.record(name: "dataBrowser", phase: "run", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
        subscriberTasks.append(task)
    }

    private func startVoiceBrowser() {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let browser = NetworkBrowser(
                    for: Bonjour.bonjour(Self.voiceServiceType, includeTxtRecord: true),
                    using: Self.browserParameters()
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

    private func connectDataEndpoints(_ endpoints: [Bonjour.Endpoint]) async {
        await updateDiscoveredMembers(from: endpoints)
        availableDataEndpoints = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })
        for endpoint in endpoints { connectDataEndpoint(endpoint) }
    }

    private func connectVoiceEndpoints(_ endpoints: [Bonjour.Endpoint]) {
        availableVoiceEndpoints = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })
        for endpoint in endpoints { connectVoiceEndpoint(endpoint) }
    }

    private func connectDataEndpoint(_ endpoint: Bonjour.Endpoint) {
        guard shouldInitiateConnection(to: endpoint), let tlsConfiguration else { return }
        guard dataEndpointKeys.insert(endpoint.id).inserted else { return }
        let connection = ValidationDataConnection(
            to: endpoint,
            using: .parameters {
                Coder(DataPlaneMessage.self, using: NetworkJSONCoder()) {
                    tlsConfiguration.protocolOptions()
                }
            }
            .peerToPeerIncluded(true)
            .serviceClass(.bestEffort)
            .localOnly(true)
            .noProxiesPreferred(true)
        )
        dataConnectionEndpointKeys[connection.id] = endpoint.id
        attachDataConnection(connection, source: "bonjour")
    }

    private func connectVoiceEndpoint(_ endpoint: Bonjour.Endpoint) {
        guard shouldInitiateConnection(to: endpoint) else { return }
        guard voiceEndpointKeys.insert(endpoint.id).inserted else { return }
        let connection = ValidationVoiceConnection(
            to: endpoint,
            using: .parameters {
                Coder(AuthenticatedVoicePacket.self, using: NetworkJSONCoder()) {
                    UDP()
                }
            }
            .peerToPeerIncluded(true)
            .serviceClass(.interactiveVoice)
            .localOnly(true)
            .noProxiesPreferred(true)
        )
        voiceConnectionEndpointKeys[connection.id] = endpoint.id
        attachVoiceConnection(connection, source: "bonjour")
    }

    private func shouldInitiateConnection(to endpoint: Bonjour.Endpoint) -> Bool {
        guard
            endpoint.txtRecord["gid"] == groupID,
            let peerIDText = endpoint.txtRecord["peer"],
            let peerID = UUID(uuidString: peerIDText),
            peerID != deviceID
        else { return false }
        return deviceID.uuidString < peerID.uuidString
    }

    private func updateDiscoveredMembers(from endpoints: [Bonjour.Endpoint]) async {
        status.discoveredMemberNames = endpoints.compactMap { endpoint in
            guard endpoint.txtRecord["gid"] == groupID else { return nil }
            return endpoint.txtRecord["name"] ?? endpoint.name
        }.filter { $0 != displayName }.sorted()
        status.discoveryState = "发现 \(status.discoveredMemberNames.count) 个同群 Bonjour 成员"
        await emitStatus()
    }

    private nonisolated static func serviceTXTRecord(groupID: String, deviceID: UUID, displayName: String) -> NWTXTRecord {
        NWTXTRecord([
            "gid": groupID,
            "peer": deviceID.uuidString,
            "name": displayName,
            "v": "1"
        ])
    }

    private nonisolated static func browserParameters() -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        parameters.acceptLocalOnly = true
        parameters.preferNoProxies = true
        return parameters
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
        dataConnectionSources[connection.id] = source
        lastDataActivity[connection.id] = "connection.attached"
        connection.onStateUpdate { _, state in
            Task { await self.logDataConnectionState(connection, state: state, source: source) }
        }
        connection.onPathUpdate { _, path in
            Task { await self.logDataPathUpdate(connection, path: path, source: source) }
        }
        do {
            guard let groupCredentials else { throw PeerToPeerTransportError.groupCredentialsUnavailable }
            let nonce = UUID()
            let helloPayload = Self.helloAuthenticationPayload(
                deviceID: deviceID,
                name: displayName,
                groupID: groupCredentials.id,
                nonce: nonce
            )
            try await connection.send(
                .hello(
                    deviceID: deviceID,
                    name: displayName,
                    groupID: groupCredentials.id,
                    nonce: nonce,
                    authenticationTag: groupCredentials.authenticationTag(for: helloPayload)
                )
            )
            lastDataActivity[connection.id] = "hello.sent"
            var peerAuthenticated = false
            for try await (message, _) in connection.messages {
                try Task.checkCancellation()
                lastDataActivity[connection.id] = "receive:\(Self.messageDescription(message))"
                if !peerAuthenticated {
                    guard case let .hello(peerID, name, groupID, nonce, tag) = message else {
                        throw PeerToPeerTransportError.businessMessageBeforeAuthentication
                    }
                    let payload = Self.helloAuthenticationPayload(
                        deviceID: peerID,
                        name: name,
                        groupID: groupID,
                        nonce: nonce
                    )
                    guard groupID == groupCredentials.id,
                          groupCredentials.authenticates(tag, payload: payload)
                    else { throw PeerToPeerTransportError.groupAuthenticationFailed }
                    peerAuthenticated = true
                    authenticatedDataConnectionIDs.insert(connection.id)
                    authenticatedPeerByDataConnectionID[connection.id] = peerID
                    status.connectionState = "已连接（群组已认证）"
                    syncConnectionCountsIntoStatus()
                    await emitStatus()
                    var metadata = dataConnectionMetadata(connection)
                    metadata["peerID"] = peerID.uuidString
                    metadata["name"] = name
                    await record(name: "hello", phase: "authenticated", outcome: .success, metadata: metadata)
                    continue
                }
                await handle(message, on: connection)
            }
            var metadata = dataConnectionMetadata(connection)
            metadata["reason"] = "messageSequenceEnded"
            await record(name: "dataConnection", phase: "streamEnded", outcome: .info, metadata: metadata)
            removeDataConnection(connection)
            await emitStatus()
        } catch is CancellationError {
            var metadata = dataConnectionMetadata(connection)
            metadata["reason"] = "taskCancelled"
            await record(name: "dataConnection", phase: "cancel", outcome: .info, metadata: metadata)
            removeDataConnection(connection)
            await emitStatus()
            return
        } catch {
            var metadata = dataConnectionMetadata(connection)
            metadata.merge(Self.errorMetadata(error)) { _, new in new }
            removeDataConnection(connection)
            status.connectionState = "数据连接已断开"
            status.lastError = String(describing: error)
            await emitStatus()
            await record(name: "dataConnection", phase: "receive", outcome: .failure, metadata: metadata)
            peerToPeerRuntimeLogger.error(
                "data connection receive failed connectionID=\(connection.id, privacy: .public) source=\(source, privacy: .public) lastActivity=\(metadata["lastActivity"] ?? "none", privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func handleVoiceConnection(_ connection: ValidationVoiceConnection, source: String) async {
        voiceConnections[connection.id] = connection
        connection.onStateUpdate { _, state in
            Task { await self.logVoiceConnectionState(connection, state: state, source: source) }
        }
        do {
            guard let groupCredentials else { throw PeerToPeerTransportError.groupCredentialsUnavailable }
            for try await (authenticated, _) in connection.messages {
                try Task.checkCancellation()
                let packet = authenticated.packet
                guard groupCredentials.authenticates(
                    authenticated.authenticationTag,
                    payload: Self.voiceAuthenticationPayload(packet)
                ) else {
                    await record(name: "voicePacket", phase: "authenticate", outcome: .failure)
                    continue
                }
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
        case .hello:
            await record(name: "hello", phase: "duplicate", outcome: .failure)
        case let .ping(id, sentAt):
            peerToPeerRuntimeLogger.notice("RTT ping receive id=\(id.uuidString, privacy: .public)")
            do {
                try await connection.send(.pong(id: id, sentAt: sentAt))
                peerToPeerRuntimeLogger.notice("RTT pong send id=\(id.uuidString, privacy: .public)")
            } catch {
                peerToPeerRuntimeLogger.error(
                    "RTT pong send failed id=\(id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                await record(name: "smallMessage", phase: "pong", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        case let .pong(id, _):
            let latency = pingStarts.removeValue(forKey: id).map { ContinuousClock.now - $0 }
            if let latency {
                peerToPeerRuntimeLogger.notice(
                    "RTT pong receive id=\(id.uuidString, privacy: .public) latencyMilliseconds=\(latency.milliseconds, format: .fixed(precision: 3))"
                )
            } else {
                peerToPeerRuntimeLogger.error("RTT pong receive without pending ping id=\(id.uuidString, privacy: .public)")
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
        case let .nearbyToken(senderID, peerID, requestID, token):
            var metadata = dataConnectionMetadata(connection)
            metadata["senderID"] = senderID.uuidString
            metadata["peerID"] = peerID.uuidString
            metadata["requestID"] = requestID.uuidString
            await record(name: "nearbyToken", phase: "receive", outcome: .success, byteCount: token.count, metadata: metadata)
            peerToPeerRuntimeLogger.notice(
                "UWB token receive requestID=\(requestID.uuidString, privacy: .public) senderID=\(senderID.uuidString, privacy: .public) connectionID=\(connection.id, privacy: .public) bytes=\(token.count)"
            )
            await messageSink?(message)
        }
    }

    private func broadcast(_ message: DataPlaneMessage) async {
        for connection in dataConnections.values where authenticatedDataConnectionIDs.contains(connection.id) {
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
        peerToPeerRuntimeLogger.notice(
            "data connection state id=\(connection.id, privacy: .public) source=\(source, privacy: .public) state=\(String(describing: state), privacy: .public)"
        )
        if case .ready = state {
            readyDataConnectionIDs.insert(connection.id)
            status.connectionState = "已连接（Bonjour / peer-to-peer ready）"
            status.lastError = nil
        } else if state.isTerminal {
            readyDataConnectionIDs.remove(connection.id)
            status.connectionState = "未连接"
        } else {
            status.connectionState = "数据连接：\(String(describing: state))"
        }
        syncConnectionCountsIntoStatus()
        await emitStatus()
        var metadata = dataConnectionMetadata(connection)
        metadata["source"] = source
        if let stateError = state.networkError {
            metadata.merge(Self.errorMetadata(stateError)) { _, new in new }
        }
        await record(name: "dataConnection", phase: String(describing: state), outcome: state.isFailure ? .failure : .info, metadata: metadata)
        guard case .ready = state else { return }
        guard let path = connection.currentPath else {
            await record(name: "pathAudit", phase: "ready", outcome: .failure, metadata: ["reason": "pathUnavailable"])
            return
        }
        let interfaces = path.availableInterfaces.map(\.name).sorted()
        await record(
            name: "pathAudit",
            phase: "ready",
            outcome: path.status == .satisfied ? .success : .failure,
            metadata: [
                "interfaces": interfaces.joined(separator: ","),
                "awdlObserved": String(interfaces.contains { $0.lowercased().contains("awdl") }),
                "usesWiFi": String(path.usesInterfaceType(.wifi)),
                "peerToPeerIncluded": String(connection.parameters.includePeerToPeer),
                "remoteEndpoint": String(describing: connection.remoteEndpoint)
            ]
        )
    }

    private func logDataPathUpdate(
        _ connection: ValidationDataConnection,
        path: NWPath,
        source: String
    ) async {
        var metadata = Self.pathMetadata(path)
        metadata["connectionID"] = connection.id
        metadata["source"] = source
        metadata["remoteEndpoint"] = String(describing: connection.remoteEndpoint)
        metadata["peerID"] = authenticatedPeerByDataConnectionID[connection.id]?.uuidString ?? "unauthenticated"
        await record(
            name: "pathAudit",
            phase: "update",
            outcome: path.status == .satisfied ? .success : .failure,
            metadata: metadata
        )
        peerToPeerRuntimeLogger.notice(
            "data path update connectionID=\(connection.id, privacy: .public) peerID=\(metadata["peerID"] ?? "unknown", privacy: .public) path=\(String(describing: path), privacy: .public)"
        )
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
            let path = connection.currentPath
            let interfaces = path?.availableInterfaces.map(\.name).sorted() ?? []
            await record(
                name: "voicePathAudit",
                phase: "ready",
                outcome: path?.status == .satisfied ? .success : .failure,
                metadata: [
                    "interfaces": interfaces.joined(separator: ","),
                    "awdlObserved": String(interfaces.contains { $0.lowercased().contains("awdl") }),
                    "peerToPeerIncluded": String(connection.parameters.includePeerToPeer)
                ]
            )
        }
    }

    private func logListenerState<ApplicationProtocol>(
        _ state: NetworkListener<ApplicationProtocol>.State,
        name: String
    ) async where ApplicationProtocol: NetworkProtocolOptions {
        let value = String(describing: state)
        peerToPeerRuntimeLogger.notice("listener state name=\(name, privacy: .public) state=\(value, privacy: .public)")
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
        peerToPeerRuntimeLogger.notice(
            "browser state name=\(name, privacy: .public) state=\(String(describing: state), privacy: .public)"
        )
        if state.isFailure {
            status.lastError = String(describing: state)
        }
        await emitStatus()
        await record(name: name, phase: String(describing: state), outcome: state.isFailure ? .failure : .info)
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

    private func resetNetworkTasks() async {
        publisherTasks.forEach { $0.cancel() }
        publisherTasks.removeAll()
        subscriberTasks.forEach { $0.cancel() }
        subscriberTasks.removeAll()
        connectionTasks.forEach { $0.cancel() }
        connectionTasks.removeAll()
        dataConnections.removeAll()
        voiceConnections.removeAll()
        readyDataConnectionIDs.removeAll()
        authenticatedDataConnectionIDs.removeAll()
        authenticatedPeerByDataConnectionID.removeAll()
        dataConnectionSources.removeAll()
        lastDataActivity.removeAll()
        readyVoiceConnectionIDs.removeAll()
        dataEndpointKeys.removeAll()
        voiceEndpointKeys.removeAll()
        availableDataEndpoints.removeAll()
        availableVoiceEndpoints.removeAll()
        dataConnectionEndpointKeys.removeAll()
        voiceConnectionEndpointKeys.removeAll()
        status.discoveredMemberNames.removeAll()
        status.dataPublisherState = "未启动"
        status.voicePublisherState = "未启动"
        status.connectionState = "未连接"
        status.lastError = nil
        syncConnectionCountsIntoStatus()
    }

    private func removeDataConnection(_ connection: ValidationDataConnection) {
        dataConnections.removeValue(forKey: connection.id)
        readyDataConnectionIDs.remove(connection.id)
        authenticatedDataConnectionIDs.remove(connection.id)
        authenticatedPeerByDataConnectionID.removeValue(forKey: connection.id)
        dataConnectionSources.removeValue(forKey: connection.id)
        lastDataActivity.removeValue(forKey: connection.id)
        if let endpointKey = dataConnectionEndpointKeys.removeValue(forKey: connection.id) {
            dataEndpointKeys.remove(endpointKey)
            scheduleDataReconnect(endpointKey: endpointKey)
        }
        syncConnectionCountsIntoStatus()
    }

    private func removeVoiceConnection(_ connection: ValidationVoiceConnection) {
        voiceConnections.removeValue(forKey: connection.id)
        readyVoiceConnectionIDs.remove(connection.id)
        if let endpointKey = voiceConnectionEndpointKeys.removeValue(forKey: connection.id) {
            voiceEndpointKeys.remove(endpointKey)
            scheduleVoiceReconnect(endpointKey: endpointKey)
        }
        syncConnectionCountsIntoStatus()
    }

    private func scheduleDataReconnect(endpointKey: String) {
        guard isRunning else { return }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.reconnectDataEndpoint(endpointKey)
        }
        connectionTasks.append(task)
    }

    private func reconnectDataEndpoint(_ endpointKey: String) {
        guard let endpoint = availableDataEndpoints[endpointKey] else { return }
        connectDataEndpoint(endpoint)
    }

    private func scheduleVoiceReconnect(endpointKey: String) {
        guard isRunning else { return }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.reconnectVoiceEndpoint(endpointKey)
        }
        connectionTasks.append(task)
    }

    private func reconnectVoiceEndpoint(_ endpointKey: String) {
        guard let endpoint = availableVoiceEndpoints[endpointKey] else { return }
        connectVoiceEndpoint(endpoint)
    }

    private func syncConnectionCountsIntoStatus() {
        status.dataConnectionCount = authenticatedDataConnectionIDs.count
        status.voiceConnectionCount = readyVoiceConnectionIDs.count
    }

    private nonisolated static func helloAuthenticationPayload(
        deviceID: UUID,
        name: String,
        groupID: String,
        nonce: UUID
    ) -> Data {
        Data("hello|\(deviceID.uuidString)|\(name)|\(groupID)|\(nonce.uuidString)".utf8)
    }

    private nonisolated static func voiceAuthenticationPayload(_ packet: VoicePacket) -> Data {
        var payload = Data("voice|\(packet.callID.uuidString)|\(packet.senderID.uuidString)|".utf8)
        var sequence = packet.sequence.bigEndian
        var sentAt = packet.sentAt.timeIntervalSince1970.bitPattern.bigEndian
        var sampleRate = packet.sampleRate.bitPattern.bigEndian
        var channelCount = packet.channelCount.bigEndian
        withUnsafeBytes(of: &sequence) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &sentAt) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &sampleRate) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &channelCount) { payload.append(contentsOf: $0) }
        payload.append(packet.pcm16)
        return payload
    }

    private func dataConnectionMetadata(_ connection: ValidationDataConnection) -> [String: String] {
        var metadata = Self.pathMetadata(connection.currentPath)
        metadata["connectionID"] = connection.id
        metadata["connectionState"] = String(describing: connection.state)
        metadata["source"] = dataConnectionSources[connection.id] ?? "unknown"
        metadata["localEndpoint"] = String(describing: connection.localEndpoint)
        metadata["remoteEndpoint"] = String(describing: connection.remoteEndpoint)
        metadata["authenticatedPeerID"] = authenticatedPeerByDataConnectionID[connection.id]?.uuidString ?? "unauthenticated"
        metadata["lastActivity"] = lastDataActivity[connection.id] ?? "none"
        return metadata
    }

    private nonisolated static func pathMetadata(_ path: NWPath?) -> [String: String] {
        guard let path else { return ["pathStatus": "unavailable"] }
        let interfaces = path.availableInterfaces.map(\.name).sorted()
        return [
            "pathStatus": String(describing: path.status),
            "interfaces": interfaces.joined(separator: ","),
            "awdlObserved": String(interfaces.contains { $0.lowercased().contains("awdl") }),
            "usesWiFi": String(path.usesInterfaceType(.wifi)),
            "usesCellular": String(path.usesInterfaceType(.cellular)),
            "isExpensive": String(path.isExpensive),
            "isConstrained": String(path.isConstrained),
            "supportsIPv4": String(path.supportsIPv4),
            "supportsIPv6": String(path.supportsIPv6),
            "linkQuality": String(describing: path.linkQuality)
        ]
    }

    private nonisolated static func errorMetadata(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        var metadata = [
            "error": String(describing: error),
            "errorType": String(reflecting: type(of: error)),
            "errorDomain": nsError.domain,
            "errorCode": String(nsError.code)
        ]
        if let networkError = error as? NWError {
            switch networkError {
            case let .posix(code):
                metadata["networkErrorKind"] = "posix"
                metadata["networkErrorCode"] = String(code.rawValue)
                metadata["networkErrorSymbol"] = String(describing: code)
            case let .dns(code):
                metadata["networkErrorKind"] = "dns"
                metadata["networkErrorCode"] = String(code)
            case let .tls(code):
                metadata["networkErrorKind"] = "tls"
                metadata["networkErrorCode"] = String(code)
            case let .wifiAware(code):
                metadata["networkErrorKind"] = "wifiAware"
                metadata["networkErrorCode"] = String(code)
            @unknown default:
                metadata["networkErrorKind"] = "unknown"
            }
        }
        return metadata
    }

    private nonisolated static func messageDescription(_ message: DataPlaneMessage) -> String {
        switch message {
        case .hello: "hello"
        case .ping: "ping"
        case .pong: "pong"
        case .text: "text"
        case .syncPull: "syncPull"
        case .syncBatch: "syncBatch"
        case .resourceManifest: "resourceManifest"
        case .resourceMissing: "resourceMissing"
        case .resourceChunk: "resourceChunk"
        case .resourceComplete: "resourceComplete"
        case let .nearbyToken(_, _, requestID, _): "nearbyToken:\(requestID.uuidString)"
        }
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
                kind: .peerToPeer,
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

    var networkError: NWError? {
        switch self {
        case let .waiting(error), let .failed(error): error
        default: nil
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

private enum PeerToPeerTransportError: Error {
    case groupCredentialsUnavailable
    case businessMessageBeforeAuthentication
    case groupAuthenticationFailed
}
