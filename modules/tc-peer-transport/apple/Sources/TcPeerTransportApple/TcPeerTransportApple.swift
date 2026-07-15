import Foundation
@preconcurrency import Network
@preconcurrency import Security

public enum TcPeerTransportChannel: Int, Sendable, Equatable {
    case control = 1
    case event = 2
    case chunk = 3
    case audio = 4
}

public enum TcPeerTransportConnectionSource: Sendable, Equatable {
    case inbound
    case outbound
}

public enum TcPeerTransportEvent: Sendable, Equatable {
    case discoveryStarted(requestID: String)
    case discoveryStopped(requestID: String)
    case peerFound(peerID: String)
    case connectionOpened(
        connection: UInt64,
        source: TcPeerTransportConnectionSource,
        expectedPeerID: String?
    )
    case disconnected(connection: UInt64, reason: String)
    case frameReceived(
        connection: UInt64,
        channel: TcPeerTransportChannel,
        bytes: [UInt8]
    )
    case sent(requestID: String)
    case failed(requestID: String?, code: String, message: String, retryable: Bool)
}

public typealias TcPeerTransportEventSink = @Sendable (TcPeerTransportEvent) -> Void

/// Platform capability values exposed without leaking Network.framework objects.
public struct TcPeerTransportCapabilitySnapshot: Sendable, Equatable {
    public let localOnly: Bool
    public let peerToPeer: Bool
    public let authenticatedStreams: Bool
    public let bulkStreams: Bool
    public let realtimeStreams: Bool
    public let maxDataFrameBytes: UInt32

    public init(
        localOnly: Bool,
        peerToPeer: Bool,
        authenticatedStreams: Bool,
        bulkStreams: Bool,
        realtimeStreams: Bool,
        maxDataFrameBytes: UInt32
    ) {
        self.localOnly = localOnly
        self.peerToPeer = peerToPeer
        self.authenticatedStreams = authenticatedStreams
        self.bulkStreams = bulkStreams
        self.realtimeStreams = realtimeStreams
        self.maxDataFrameBytes = maxDataFrameBytes
    }
}

/// iOS 26 Bonjour/AWDL transport using Network.framework's structured-concurrency API.
/// Rust owns the meaning and contents of every TLV frame.
public actor TcPeerTransportAppleBackend {
    private static let serviceType = "_tc-travel._tcp"

    public nonisolated static var capabilitySnapshot: TcPeerTransportCapabilitySnapshot {
        TcPeerTransportCapabilitySnapshot(
            localOnly: true,
            peerToPeer: true,
            authenticatedStreams: true,
            bulkStreams: true,
            realtimeStreams: true,
            maxDataFrameBytes: 8 * 1_024 * 1_024
        )
    }

    private struct Configuration: @unchecked Sendable {
        var localPeerID: UUID
        var discoveryScope: String
        var displayName: String
        var protocolVersion: UInt16
        var identity: sec_identity_t
    }

    private let eventSink: TcPeerTransportEventSink
    private var configuration: Configuration?
    private var realtime = false
    private var running = false
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var connectionTasks: [String: Task<Void, Never>] = [:]
    private var endpointKeys: Set<String> = []
    private var discoveredEndpointKeys: Set<String> = []
    private var endpointKeyByConnectionID: [String: String] = [:]
    private var connectionsByHandle: [UInt64: NetworkConnection<TLV>] = [:]
    private var handleByConnectionID: [String: UInt64] = [:]
    private var nextConnectionHandle: UInt64 = 1

    public init(eventSink: @escaping TcPeerTransportEventSink) {
        self.eventSink = eventSink
    }

    public func startDiscovery(
        requestID: String,
        localPeerID: String,
        discoveryScope: String,
        displayName: String,
        protocolVersion: UInt16,
        certificateDER: [UInt8],
        privateKeyPKCS8: [UInt8]
    ) async {
        do {
            let config = try Self.makeConfiguration(
                localPeerID: localPeerID,
                discoveryScope: discoveryScope,
                displayName: displayName,
                protocolVersion: protocolVersion,
                certificateDER: certificateDER,
                privateKeyPKCS8: privateKeyPKCS8
            )
            await resetNetworkTasks(reason: "transportRestarted")
            configuration = config
            running = true
            startListener()
            startBrowser()
            emit(.discoveryStarted(requestID: requestID))
        } catch let error as BackendError {
            switch error {
            case .invalidIdentity, .identityImportFailed, .certificateImportFailed, .privateKeyImportFailed:
                emit(.failed(
                    requestID: requestID,
                    code: "tlsIdentityUnavailable",
                    message: error.description,
                    retryable: false
                ))
            default:
                emit(.failed(
                    requestID: requestID,
                    code: "commandFailed",
                    message: error.description,
                    retryable: true
                ))
            }
        } catch {
            emit(.failed(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: true
            ))
        }
    }

    public func stopDiscovery(requestID: String) async {
        await stop(requestID: requestID)
    }

    /// Discovery owns the sole connection direction; this is an idempotent hint.
    public func connect(requestID: String, peerID: String) {
        guard UUID(uuidString: peerID) != nil else {
            emit(.failed(
                requestID: requestID,
                code: "commandFailed",
                message: "peerID is invalid",
                retryable: false
            ))
            return
        }
    }

    public func disconnect(requestID: String, connection: UInt64) {
        guard let networkConnection = connectionsByHandle[connection] else {
            emit(.failed(
                requestID: requestID,
                code: "commandFailed",
                message: "connection is unavailable",
                retryable: false
            ))
            return
        }
        connectionTasks[networkConnection.id]?.cancel()
        emit(.sent(requestID: requestID))
    }

    public func sendFrame(
        requestID: String,
        connection: UInt64,
        channel: TcPeerTransportChannel,
        bytes: [UInt8]
    ) async {
        await send(
            requestID: requestID,
            connectionHandle: connection,
            channel: channel,
            payload: Data(bytes)
        )
    }

    public func setRealtime(requestID: String, realtime enabled: Bool) async {
        guard realtime != enabled else {
            emit(.sent(requestID: requestID))
            return
        }
        realtime = enabled
        if running, configuration != nil {
            await resetNetworkTasks(reason: "trafficClassChanged")
            startListener()
            startBrowser()
        }
        emit(.sent(requestID: requestID))
    }

    public func shutdown() async { await stop(requestID: nil) }

    private func stop(requestID: String?) async {
        running = false
        await resetNetworkTasks(reason: "transportStopped")
        configuration = nil
        if let requestID {
            emit(.discoveryStopped(requestID: requestID))
        }
    }

    private func startListener() {
        guard let config = configuration else { return }
        let realtime = realtime
        listenerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listener = try NetworkListener<TLV>(
                    for: .bonjour(
                        name: config.displayName,
                        type: Self.serviceType,
                        txtRecord: Self.txtRecord(config)
                    ),
                    using: .parameters {
                        Self.protocolStack(identity: config.identity)
                    }
                    .peerToPeerIncluded(true)
                    .serviceClass(realtime ? .interactiveVoice : .bestEffort)
                    .localOnly(true)
                    .noProxiesPreferred(true)
                )
                .onStateUpdate { _, state in
                    Task { await self.listenerStateChanged(state) }
                }
                try await listener.run { connection in
                    await self.attach(connection, source: .inbound, endpoint: nil, expectedPeerID: nil)
                }
            } catch is CancellationError {
                return
            } catch {
                await self.transportFailed("listener", error: error)
            }
        }
    }

    private func startBrowser() {
        browserTask = Task { [weak self] in
            guard let self else { return }
            do {
                let browser = NetworkBrowser(
                    for: Bonjour.bonjour(Self.serviceType, includeTxtRecord: true),
                    using: Self.browserParameters()
                )
                .onStateUpdate { _, state in
                    Task { await self.browserStateChanged(state) }
                }
                try await browser.run { endpoints in
                    await self.discovered(endpoints)
                }
            } catch is CancellationError {
                return
            } catch {
                await self.transportFailed("browser", error: error)
            }
        }
    }

    private func discovered(_ endpoints: [Bonjour.Endpoint]) {
        guard let config = configuration else { return }
        var available: Set<String> = []
        for endpoint in endpoints {
            guard endpoint.txtRecord["gid"] == config.discoveryScope,
                  endpoint.txtRecord["v"] == String(config.protocolVersion),
                  let peerText = endpoint.txtRecord["peer"],
                  let peerID = UUID(uuidString: peerText),
                  peerID != config.localPeerID
            else { continue }
            available.insert(endpoint.id)
            // Exactly one side dials: the lexicographically smaller stable peer ID.
            guard config.localPeerID.uuidString < peerID.uuidString else { continue }
            connect(endpoint, expectedPeerID: peerID)
        }
        discoveredEndpointKeys = available
    }

    private func connect(_ endpoint: Bonjour.Endpoint, expectedPeerID: UUID) {
        guard let config = configuration, endpointKeys.insert(endpoint.id).inserted else { return }
        let realtime = realtime
        let connection = NetworkConnection<TLV>(
            to: endpoint,
            using: .parameters {
                Self.protocolStack(identity: config.identity)
            }
            .peerToPeerIncluded(true)
            .serviceClass(realtime ? .interactiveVoice : .bestEffort)
            .localOnly(true)
            .noProxiesPreferred(true)
        )
        endpointKeyByConnectionID[connection.id] = endpoint.id
        emit(.peerFound(peerID: expectedPeerID.uuidString.lowercased()))
        attach(connection, source: .outbound, endpoint: endpoint, expectedPeerID: expectedPeerID)
    }

    private func attach(
        _ connection: NetworkConnection<TLV>,
        source: TcPeerTransportConnectionSource,
        endpoint: Bonjour.Endpoint?,
        expectedPeerID: UUID?
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handle(connection, source: source, endpoint: endpoint, expectedPeerID: expectedPeerID)
        }
        connectionTasks[connection.id] = task
    }

    private func handle(
        _ connection: NetworkConnection<TLV>,
        source: TcPeerTransportConnectionSource,
        endpoint: Bonjour.Endpoint?,
        expectedPeerID: UUID?
    ) async {
        guard configuration != nil else { return }
        connection.onStateUpdate { _, state in
            Task { self.connectionStateChanged(connection, state: state) }
        }
        connection.onPathUpdate { _, path in
            Task { self.pathChanged(connection, path: path) }
        }
        let handle = connectionHandle(connection)
        connectionsByHandle[handle] = connection
        emit(.connectionOpened(
            connection: handle,
            source: source,
            expectedPeerID: expectedPeerID?.uuidString.lowercased()
        ))
        var shouldRetry = false
        do {
            for try await (payload, metadata) in connection.messages {
                try Task.checkCancellation()
                guard let channel = TcPeerTransportChannel(rawValue: metadata.type) else {
                    throw BackendError.invalidTLVType
                }
                emit(.frameReceived(
                    connection: handle,
                    channel: channel,
                    bytes: [UInt8](payload)
                ))
            }
        } catch is CancellationError {
            // Normal shutdown/reconfiguration.
        } catch {
            shouldRetry = source == .outbound
            emit(.failed(
                requestID: nil,
                code: "connectionFailed",
                message: String(describing: error),
                retryable: shouldRetry
            ))
        }
        remove(connection, endpointKey: endpoint?.id)
        if shouldRetry, let endpoint, let expectedPeerID {
            scheduleRetry(endpoint, expectedPeerID: expectedPeerID)
        }
    }

    private func scheduleRetry(_ endpoint: Bonjour.Endpoint, expectedPeerID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.retry(endpoint, expectedPeerID: expectedPeerID)
        }
    }

    private func retry(_ endpoint: Bonjour.Endpoint, expectedPeerID: UUID) {
        guard running, configuration != nil, discoveredEndpointKeys.contains(endpoint.id) else { return }
        connect(endpoint, expectedPeerID: expectedPeerID)
    }

    private func send(
        requestID: String,
        connectionHandle: UInt64,
        channel: TcPeerTransportChannel,
        payload: Data
    ) async {
        do {
            guard let connection = connectionsByHandle[connectionHandle] else {
                throw BackendError.peerUnavailable
            }
            let limit = channel == .chunk ? 8 * 1_024 * 1_024 : 512 * 1_024
            guard payload.count <= limit else { throw BackendError.payloadTooLarge }
            try await connection.send(payload, type: channel.rawValue)
            emit(.sent(requestID: requestID))
        } catch {
            emit(.failed(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: true
            ))
        }
    }

    private func remove(_ connection: NetworkConnection<TLV>, endpointKey: String?) {
        connectionTasks.removeValue(forKey: connection.id)
        if let handle = handleByConnectionID.removeValue(forKey: connection.id) {
            connectionsByHandle.removeValue(forKey: handle)
            emit(.disconnected(connection: handle, reason: "disconnected"))
        }
        if let key = endpointKey ?? endpointKeyByConnectionID.removeValue(forKey: connection.id) { endpointKeys.remove(key) }
    }

    private func resetNetworkTasks(reason: String) async {
        for handle in connectionsByHandle.keys {
            emit(.disconnected(connection: handle, reason: reason))
        }
        listenerTask?.cancel()
        browserTask?.cancel()
        listenerTask = nil
        browserTask = nil
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        endpointKeys.removeAll()
        discoveredEndpointKeys.removeAll()
        endpointKeyByConnectionID.removeAll()
        connectionsByHandle.removeAll()
        handleByConnectionID.removeAll()
        await Task.yield()
    }

    private func connectionHandle(_ connection: NetworkConnection<TLV>) -> UInt64 {
        if let existing = handleByConnectionID[connection.id] { return existing }
        let handle = nextConnectionHandle
        nextConnectionHandle &+= 1
        handleByConnectionID[connection.id] = handle
        return handle
    }

    private func listenerStateChanged(_ state: NetworkListener<TLV>.State) {
        _ = state
    }

    private func browserStateChanged(_ state: NetworkBrowser<Bonjour>.State) {
        _ = state
    }

    private func connectionStateChanged(_ connection: NetworkConnection<TLV>, state: NetworkChannel<TLV>.State) {
        _ = connection
        _ = state
    }

    private func pathChanged(_ connection: NetworkConnection<TLV>, path: NWPath) {
        _ = connection
        _ = path
    }

    private func transportFailed(_ component: String, error: any Error) {
        emit(.failed(
            requestID: nil,
            code: "transportFailed",
            message: "\(component): \(error)",
            retryable: true
        ))
    }

    private func emit(_ event: TcPeerTransportEvent) {
        eventSink(event)
    }

    private nonisolated static func makeConfiguration(
        localPeerID localText: String,
        discoveryScope: String,
        displayName: String,
        protocolVersion: UInt16,
        certificateDER: [UInt8],
        privateKeyPKCS8: [UInt8]
    ) throws -> Configuration {
        guard let localPeerID = UUID(uuidString: localText) else { throw BackendError.invalidPeerID }
        guard !discoveryScope.isEmpty else { throw BackendError.invalidDiscoveryScope }
        guard !displayName.isEmpty else { throw BackendError.invalidDisplayName }
        let identity = try importIdentity(
            certificateDER: certificateDER,
            privateKeyPKCS8: privateKeyPKCS8
        )
        return Configuration(
            localPeerID: localPeerID,
            discoveryScope: discoveryScope,
            displayName: String(displayName.prefix(63)),
            protocolVersion: protocolVersion,
            identity: identity
        )
    }

    private nonisolated static func importIdentity(
        certificateDER: [UInt8],
        privateKeyPKCS8: [UInt8]
    ) throws -> sec_identity_t {
        guard !certificateDER.isEmpty, !privateKeyPKCS8.isEmpty else {
            throw BackendError.invalidIdentity
        }
        return try importIdentity(
            certificateDER: Data(certificateDER),
            privateKeyPKCS8: Data(privateKeyPKCS8)
        )
    }

    private nonisolated static func importIdentity(
        certificateDER: Data,
        privateKeyPKCS8: Data
    ) throws -> sec_identity_t {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              let publicAttributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
              let keyType = publicAttributes[kSecAttrKeyType],
              let keySize = publicAttributes[kSecAttrKeySizeInBits]
        else { throw BackendError.certificateImportFailed }

        let privateAttributes: [CFString: Any] = [
            kSecAttrKeyType: keyType,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: keySize,
        ]
        var keyError: Unmanaged<CFError>?
        var privateKey = SecKeyCreateWithData(
            privateKeyPKCS8 as CFData,
            privateAttributes as CFDictionary,
            &keyError
        )
        let directImportError = keyError?.takeRetainedValue().localizedDescription

        // Security.framework expects ANSI X9.63 (public point + scalar) for
        // EC private keys on systems that do not accept a PKCS#8 container.
        if privateKey == nil,
           let publicExternal = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
           let external = try? ecPrivateKeyExternalRepresentation(
               pkcs8: privateKeyPKCS8,
               publicKey: publicExternal,
               scalarByteCount: (keySize as? NSNumber).map { ($0.intValue + 7) / 8 }
           )
        {
            keyError = nil
            privateKey = SecKeyCreateWithData(
                external as CFData,
                privateAttributes as CFDictionary,
                &keyError
            )
        }
        guard let privateKey else {
            let description = keyError?.takeRetainedValue().localizedDescription
                ?? directImportError
                ?? "SecKeyCreateWithData rejected PKCS#8 and X9.63 fallback"
            throw BackendError.privateKeyImportFailed(description)
        }
        guard let securityIdentity = SecIdentityCreate(nil, certificate, privateKey),
              let protocolIdentity = sec_identity_create(securityIdentity)
        else { throw BackendError.privateKeyImportFailed("certificate and private key do not form an identity") }
        return protocolIdentity
    }

    private nonisolated static func ecPrivateKeyExternalRepresentation(
        pkcs8: Data,
        publicKey: Data,
        scalarByteCount: Int?
    ) throws -> Data {
        var outer = DERReader(pkcs8)
        var privateKeyInfo = DERReader(try outer.read(tag: 0x30))
        _ = try privateKeyInfo.read(tag: 0x02)
        _ = try privateKeyInfo.read(tag: 0x30)
        var ecContainer = DERReader(try privateKeyInfo.read(tag: 0x04))
        var ecPrivateKey = DERReader(try ecContainer.read(tag: 0x30))
        _ = try ecPrivateKey.read(tag: 0x02)
        var scalar = try ecPrivateKey.read(tag: 0x04)
        let requiredCount = scalarByteCount ?? scalar.count
        guard requiredCount > 0, scalar.count <= requiredCount, publicKey.first == 0x04 else {
            throw BackendError.privateKeyImportFailed("unsupported EC PKCS#8 representation")
        }
        if scalar.count < requiredCount {
            scalar.insert(contentsOf: repeatElement(0, count: requiredCount - scalar.count), at: 0)
        }
        var external = publicKey
        external.append(scalar)
        return external
    }

    private struct DERReader {
        private let data: Data
        private var offset = 0

        init(_ data: Data) { self.data = data }

        mutating func read(tag expectedTag: UInt8) throws -> Data {
            guard offset < data.count, data[offset] == expectedTag else {
                throw BackendError.privateKeyImportFailed("malformed PKCS#8 DER tag")
            }
            offset += 1
            guard offset < data.count else {
                throw BackendError.privateKeyImportFailed("truncated PKCS#8 DER length")
            }
            let firstLength = data[offset]
            offset += 1
            let length: Int
            if firstLength & 0x80 == 0 {
                length = Int(firstLength)
            } else {
                let byteCount = Int(firstLength & 0x7f)
                guard byteCount > 0, byteCount <= 4, offset + byteCount <= data.count else {
                    throw BackendError.privateKeyImportFailed("invalid PKCS#8 DER length")
                }
                var value = 0
                for byte in data[offset..<(offset + byteCount)] {
                    value = (value << 8) | Int(byte)
                }
                offset += byteCount
                length = value
            }
            guard length >= 0, offset + length <= data.count else {
                throw BackendError.privateKeyImportFailed("truncated PKCS#8 DER value")
            }
            defer { offset += length }
            return data.subdata(in: offset..<(offset + length))
        }
    }

    private nonisolated static func protocolStack(identity: sec_identity_t) -> TLV {
        TLV(type: UInt8.self, length: UInt32.self) {
            TLS {
                TCP().noDelay(true).keepalive(idleTimeInSeconds: 10, count: 3, intervalInSeconds: 3)
            }
            .localIdentity(identity)
            .peerAuthentication(.none)
            .applicationProtocols(["travel-companion/1"])
            // The certificate provides channel encryption. Rust authenticates
            // the first opaque control frame before surfacing the connection.
            .certificateValidator { _, _ in true }
        }
    }

    private nonisolated static func txtRecord(_ config: Configuration) -> NWTXTRecord {
        NWTXTRecord([
            "gid": config.discoveryScope,
            "peer": config.localPeerID.uuidString,
            "name": config.displayName,
            "v": String(config.protocolVersion),
        ])
    }

    private nonisolated static func browserParameters() -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        parameters.acceptLocalOnly = true
        parameters.preferNoProxies = true
        return parameters
    }

    private enum BackendError: Error, CustomStringConvertible {
        case invalidPeerID, invalidDiscoveryScope, invalidDisplayName, invalidIdentity
        case identityImportFailed(OSStatus), certificateImportFailed, privateKeyImportFailed(String)
        case invalidTLVType, peerUnavailable, payloadTooLarge
        var description: String {
            switch self {
            case .invalidPeerID: "localPeerID must be a UUID"
            case .invalidDiscoveryScope: "discoveryScope is required"
            case .invalidDisplayName: "displayName is required"
            case .invalidIdentity: "certificateDer and privateKeyPkcs8 are required"
            case let .identityImportFailed(status): "PKCS#12 identity import failed (OSStatus \(status))"
            case .certificateImportFailed: "certificate DER import failed or its public-key attributes are unavailable"
            case let .privateKeyImportFailed(message): "PKCS#8 private-key import failed: \(message)"
            case .invalidTLVType: "TLV channel must be control, event, chunk, or audio"
            case .peerUnavailable: "connection is not connected"
            case .payloadTooLarge: "payload exceeds per-frame safety limit"
            }
        }
    }
}
