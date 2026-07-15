import CryptoKit
import Foundation
@preconcurrency import Network
@preconcurrency import Security

public typealias TcPeerTransportEventSink = @Sendable (Data) -> Void

/// iOS 26 Bonjour/AWDL transport using Network.framework's structured-concurrency API.
/// TLV type 1 is control, 2 is an immutable event, 3 is a resource chunk, and 4 is audio.
public actor TcPeerTransportAppleBackend {
    public enum Channel: Int, Sendable {
        case control = 1
        case event = 2
        case chunk = 3
        case audio = 4
    }

    private static let serviceType = "_tc-travel._tcp"

    private struct Command: Decodable, Sendable {
        var type: String
        var requestID: String?
        var localPeerID: String?
        var groupID: String?
        var displayName: String?
        var protocolVersion: UInt16?
        var groupKeyBase64: String?
        var identityPKCS12Base64: String?
        var identityPassword: String?
        var certificateDERBase64: String?
        var privateKeyPKCS8Base64: String?
        var peerHandle: UInt64?
        var channel: String?
        var payloadBase64: String?
        var realtime: Bool?
    }

    private struct Event: Encodable, Sendable {
        var type: String
        var requestID: String?
        var peerHandle: UInt64?
        var peerID: String?
        var channel: String?
        var payloadBase64: String?
        var fields: [String: String]?
        var error: String?
    }

    private struct Hello: Codable, Sendable {
        var kind = "hello"
        var protocolVersion: UInt16
        var peerID: UUID
        var groupID: String
        var displayName: String
        var nonce: UUID
        var authenticationTag: Data
    }

    private struct Configuration: @unchecked Sendable {
        var localPeerID: UUID
        var groupID: String
        var displayName: String
        var protocolVersion: UInt16
        var groupKey: SymmetricKey
        var identity: sec_identity_t
    }

    private enum Source: String, Sendable { case listener, bonjour }

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
    private var sourceByConnectionID: [String: Source] = [:]
    private var connectionsByPeer: [UUID: NetworkConnection<TLV>] = [:]
    private var peerByConnectionID: [String: UUID] = [:]
    private var peerHandleByID: [UUID: UInt64] = [:]
    private var peerIDByHandle: [UInt64: UUID] = [:]
    private var nextPeerHandle: UInt64 = 1

    public init(eventSink: @escaping TcPeerTransportEventSink) {
        self.eventSink = eventSink
    }

    public func submit(_ json: Data) {
        let command: Command
        do {
            command = try JSONDecoder().decode(Command.self, from: json)
        } catch {
            emit(.init(type: "commandFailed", error: String(describing: error)))
            return
        }
        switch command.type {
        case "start":
            Task { await self.start(command) }
        case "stop":
            Task { await self.stop(requestID: command.requestID) }
        case "send":
            Task { await self.send(command) }
        case "setRealtime":
            Task { await self.setRealtime(command.realtime ?? false, requestID: command.requestID) }
        case "snapshot": snapshot(requestID: command.requestID)
        default: emit(.init(type: "commandFailed", requestID: command.requestID, error: "unknown command: \(command.type)"))
        }
    }

    public func shutdown() async { await stop(requestID: nil) }

    private func start(_ command: Command) async {
        do {
            let config = try Self.makeConfiguration(command)
            await resetNetworkTasks(reason: "transportRestarted")
            configuration = config
            running = true
            startListener()
            startBrowser()
            emit(.init(type: "commandCompleted", requestID: command.requestID, fields: [
                "command": "start",
                "serviceType": Self.serviceType,
                "peerToPeerIncluded": "true",
                "localOnly": "true",
                "protocolVersion": String(config.protocolVersion),
            ]))
        } catch let error as BackendError {
            switch error {
            case .invalidIdentity, .identityImportFailed, .certificateImportFailed, .privateKeyImportFailed:
                emit(.init(
                    type: "capabilityBlocked",
                    requestID: command.requestID,
                    fields: [
                        "reason": "tlsIdentityUnavailable",
                        "tlsPurpose": "encryptionOnly",
                        "peerAuthentication": "firstFrameGroupHMACThenBusinessAEAD",
                    ],
                    error: error.description
                ))
            default:
                emit(.init(type: "commandFailed", requestID: command.requestID, error: error.description))
            }
        } catch {
            emit(.init(type: "commandFailed", requestID: command.requestID, error: String(describing: error)))
        }
    }

    private func stop(requestID: String?) async {
        running = false
        await resetNetworkTasks(reason: "transportStopped")
        configuration = nil
        emit(.init(type: "commandCompleted", requestID: requestID, fields: ["command": "stop"]))
    }

    private func setRealtime(_ enabled: Bool, requestID: String?) async {
        guard realtime != enabled else {
            emit(.init(type: "commandCompleted", requestID: requestID, fields: ["command": "setRealtime", "reused": "true"]))
            return
        }
        realtime = enabled
        if running, configuration != nil {
            await resetNetworkTasks(reason: "trafficClassChanged")
            startListener()
            startBrowser()
        }
        emit(.init(type: "trafficClassChanged", requestID: requestID, fields: [
            "realtime": String(enabled),
            "serviceClass": enabled ? "interactiveVoice" : "bestEffort",
        ]))
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
                    await self.attach(connection, source: .listener, endpoint: nil, expectedPeerID: nil)
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
        var accepted = 0
        var available: Set<String> = []
        for endpoint in endpoints {
            guard endpoint.txtRecord["gid"] == config.groupID,
                  endpoint.txtRecord["v"] == String(config.protocolVersion),
                  let peerText = endpoint.txtRecord["peer"],
                  let peerID = UUID(uuidString: peerText),
                  peerID != config.localPeerID
            else { continue }
            accepted += 1
            available.insert(endpoint.id)
            // Exactly one side dials: the lexicographically smaller stable peer ID.
            guard config.localPeerID.uuidString < peerID.uuidString else { continue }
            connect(endpoint, expectedPeerID: peerID)
        }
        discoveredEndpointKeys = available
        emit(.init(type: "discoveryUpdated", fields: ["matchingPeerCount": String(accepted)]))
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
        emit(.init(type: "dialStarted", peerID: expectedPeerID.uuidString, fields: ["endpointID": endpoint.id]))
        attach(connection, source: .bonjour, endpoint: endpoint, expectedPeerID: expectedPeerID)
    }

    private func attach(
        _ connection: NetworkConnection<TLV>,
        source: Source,
        endpoint: Bonjour.Endpoint?,
        expectedPeerID: UUID?
    ) {
        sourceByConnectionID[connection.id] = source
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handle(connection, source: source, endpoint: endpoint, expectedPeerID: expectedPeerID)
        }
        connectionTasks[connection.id] = task
    }

    private func handle(
        _ connection: NetworkConnection<TLV>,
        source: Source,
        endpoint: Bonjour.Endpoint?,
        expectedPeerID: UUID?
    ) async {
        guard let config = configuration else { return }
        connection.onStateUpdate { _, state in
            Task { self.connectionStateChanged(connection, state: state) }
        }
        connection.onPathUpdate { _, path in
            Task { self.pathChanged(connection, path: path) }
        }
        var shouldRetry = false
        do {
            let nonce = UUID()
            let hello = Hello(
                protocolVersion: config.protocolVersion,
                peerID: config.localPeerID,
                groupID: config.groupID,
                displayName: config.displayName,
                nonce: nonce,
                authenticationTag: Self.authenticationTag(
                    key: config.groupKey,
                    protocolVersion: config.protocolVersion,
                    peerID: config.localPeerID,
                    groupID: config.groupID,
                    displayName: config.displayName,
                    nonce: nonce
                )
            )
            try await connection.send(JSONEncoder().encode(hello), type: Channel.control.rawValue)
            var authenticatedPeer: UUID?
            for try await (payload, metadata) in connection.messages {
                try Task.checkCancellation()
                if authenticatedPeer == nil {
                    guard metadata.type == Channel.control.rawValue else { throw BackendError.businessBeforeAuthentication }
                    let remote = try JSONDecoder().decode(Hello.self, from: payload)
                    try Self.validate(remote, config: config)
                    if let expectedPeerID, remote.peerID != expectedPeerID {
                        throw BackendError.unexpectedPeerIdentity
                    }
                    let expectedSource: Source = config.localPeerID.uuidString < remote.peerID.uuidString ? .bonjour : .listener
                    guard source == expectedSource else { throw BackendError.duplicateDirection }
                    if let existing = connectionsByPeer[remote.peerID], existing.id != connection.id {
                        connectionTasks[existing.id]?.cancel()
                    }
                    authenticatedPeer = remote.peerID
                    connectionsByPeer[remote.peerID] = connection
                    peerByConnectionID[connection.id] = remote.peerID
                    let handle = peerHandle(remote.peerID)
                    emit(.init(type: "peerConnected", peerHandle: handle, peerID: remote.peerID.uuidString, fields: [
                        "displayName": remote.displayName,
                        "source": source.rawValue,
                        "authenticated": "true",
                    ]))
                    continue
                }
                guard let peerID = authenticatedPeer, let channel = Channel(rawValue: metadata.type) else { throw BackendError.invalidTLVType }
                emit(.init(
                    type: "frameReceived",
                    peerHandle: peerHandle(peerID),
                    peerID: peerID.uuidString,
                    channel: Self.channelName(channel),
                    payloadBase64: payload.base64EncodedString(),
                    fields: ["byteCount": String(payload.count)]
                ))
            }
        } catch is CancellationError {
            // Normal shutdown/reconfiguration.
        } catch {
            shouldRetry = source == .bonjour
            emit(.init(type: "connectionFailed", peerID: peerByConnectionID[connection.id]?.uuidString, error: String(describing: error)))
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

    private func send(_ command: Command) async {
        do {
            guard let handle = command.peerHandle, let peerID = peerIDByHandle[handle], let connection = connectionsByPeer[peerID] else {
                throw BackendError.peerUnavailable
            }
            guard let name = command.channel, let channel = Self.channel(named: name) else { throw BackendError.invalidTLVType }
            guard let encoded = command.payloadBase64, let payload = Data(base64Encoded: encoded) else { throw BackendError.invalidPayload }
            let limit = channel == .chunk ? 8 * 1_024 * 1_024 : 512 * 1_024
            guard payload.count <= limit else { throw BackendError.payloadTooLarge }
            try await connection.send(payload, type: channel.rawValue)
            emit(.init(type: "frameSent", requestID: command.requestID, peerHandle: handle, peerID: peerID.uuidString, channel: name, fields: ["byteCount": String(payload.count)]))
        } catch {
            emit(.init(type: "commandFailed", requestID: command.requestID, peerHandle: command.peerHandle, error: String(describing: error)))
        }
    }

    private func remove(_ connection: NetworkConnection<TLV>, endpointKey: String?) {
        connectionTasks.removeValue(forKey: connection.id)
        if let peerID = peerByConnectionID.removeValue(forKey: connection.id), connectionsByPeer[peerID]?.id == connection.id {
            connectionsByPeer.removeValue(forKey: peerID)
            emit(.init(type: "peerDisconnected", peerHandle: peerHandleByID[peerID], peerID: peerID.uuidString))
        }
        sourceByConnectionID.removeValue(forKey: connection.id)
        if let key = endpointKey ?? endpointKeyByConnectionID.removeValue(forKey: connection.id) { endpointKeys.remove(key) }
    }

    private func resetNetworkTasks(reason: String) async {
        for (peerID, _) in connectionsByPeer {
            emit(.init(
                type: "peerDisconnected",
                peerHandle: peerHandleByID[peerID],
                peerID: peerID.uuidString,
                error: reason
            ))
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
        sourceByConnectionID.removeAll()
        connectionsByPeer.removeAll()
        peerByConnectionID.removeAll()
        await Task.yield()
    }

    private func peerHandle(_ peerID: UUID) -> UInt64 {
        if let existing = peerHandleByID[peerID] { return existing }
        let handle = nextPeerHandle
        nextPeerHandle &+= 1
        peerHandleByID[peerID] = handle
        peerIDByHandle[handle] = peerID
        return handle
    }

    private func snapshot(requestID: String?) {
        emit(.init(type: "capabilitySnapshot", requestID: requestID, fields: [
            "running": String(running),
            "peerToPeerIncluded": "true",
            "localOnly": "true",
            "bonjourServiceType": Self.serviceType,
            "authenticatedPeerCount": String(connectionsByPeer.count),
            "realtime": String(realtime),
            "serviceClass": realtime ? "interactiveVoice" : "bestEffort",
            "framing": "TLV(UInt8,UInt32)",
        ]))
    }

    private func listenerStateChanged(_ state: NetworkListener<TLV>.State) {
        emit(.init(type: "listenerStateChanged", fields: ["state": String(describing: state)]))
    }

    private func browserStateChanged(_ state: NetworkBrowser<Bonjour>.State) {
        emit(.init(type: "browserStateChanged", fields: ["state": String(describing: state)]))
    }

    private func connectionStateChanged(_ connection: NetworkConnection<TLV>, state: NetworkChannel<TLV>.State) {
        emit(.init(type: "connectionStateChanged", peerID: peerByConnectionID[connection.id]?.uuidString, fields: [
            "connectionID": connection.id,
            "state": String(describing: state),
        ]))
    }

    private func pathChanged(_ connection: NetworkConnection<TLV>, path: NWPath) {
        let interfaces = path.availableInterfaces.map(\.name).sorted()
        emit(.init(type: "pathChanged", peerID: peerByConnectionID[connection.id]?.uuidString, fields: [
            "status": String(describing: path.status),
            "interfaces": interfaces.joined(separator: ","),
            "awdlObserved": String(interfaces.contains { $0.lowercased().contains("awdl") }),
            "usesWiFi": String(path.usesInterfaceType(.wifi)),
            "localOnly": "true",
        ]))
    }

    private func transportFailed(_ component: String, error: any Error) {
        emit(.init(type: "transportFailed", fields: ["component": component], error: String(describing: error)))
    }

    private func emit(_ event: Event) {
        if let data = try? JSONEncoder().encode(event) { eventSink(data) }
    }

    private nonisolated static func makeConfiguration(_ command: Command) throws -> Configuration {
        guard let localText = command.localPeerID, let localPeerID = UUID(uuidString: localText) else { throw BackendError.invalidPeerID }
        guard let groupID = command.groupID, !groupID.isEmpty else { throw BackendError.invalidGroupID }
        guard let displayName = command.displayName, !displayName.isEmpty else { throw BackendError.invalidDisplayName }
        guard let groupText = command.groupKeyBase64, let groupData = Data(base64Encoded: groupText), groupData.count >= 32 else { throw BackendError.invalidGroupKey }
        let identity = try importIdentity(command)
        return Configuration(
            localPeerID: localPeerID,
            groupID: groupID,
            displayName: String(displayName.prefix(63)),
            protocolVersion: command.protocolVersion ?? 1,
            groupKey: SymmetricKey(data: groupData),
            identity: identity
        )
    }

    private nonisolated static func importIdentity(_ command: Command) throws -> sec_identity_t {
        if let identityText = command.identityPKCS12Base64 {
            guard let identityData = Data(base64Encoded: identityText) else { throw BackendError.invalidIdentity }
            return try importIdentity(pkcs12: identityData, password: command.identityPassword ?? "")
        }
        guard let certificateText = command.certificateDERBase64,
              let certificateData = Data(base64Encoded: certificateText),
              let privateKeyText = command.privateKeyPKCS8Base64,
              let privateKeyData = Data(base64Encoded: privateKeyText)
        else { throw BackendError.invalidIdentity }
        return try importIdentity(certificateDER: certificateData, privateKeyPKCS8: privateKeyData)
    }

    private nonisolated static func importIdentity(pkcs12: Data, password: String) throws -> sec_identity_t {
        let options = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let values = items as? [[String: Any]],
              let identityValue = values.first?[kSecImportItemIdentity as String]
        else { throw BackendError.identityImportFailed(status) }
        let identity = identityValue as CFTypeRef
        guard CFGetTypeID(identity) == SecIdentityGetTypeID() else {
            throw BackendError.identityImportFailed(errSecDecode)
        }
        guard let protocolIdentity = sec_identity_create(identity as! SecIdentity) else {
            throw BackendError.identityImportFailed(errSecDecode)
        }
        return protocolIdentity
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
            // The certificate only provides encryption. The mandatory first TLV authenticates
            // group membership with an HMAC over stable peer/group identity and a nonce.
            .certificateValidator { _, _ in true }
        }
    }

    private nonisolated static func txtRecord(_ config: Configuration) -> NWTXTRecord {
        NWTXTRecord([
            "gid": config.groupID,
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

    private nonisolated static func authenticationTag(
        key: SymmetricKey,
        protocolVersion: UInt16,
        peerID: UUID,
        groupID: String,
        displayName: String,
        nonce: UUID
    ) -> Data {
        let input = authenticationInput(
            protocolVersion: protocolVersion,
            peerID: peerID,
            groupID: groupID,
            displayName: displayName,
            nonce: nonce
        )
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
    }

    private nonisolated static func authenticationInput(
        protocolVersion: UInt16,
        peerID: UUID,
        groupID: String,
        displayName: String,
        nonce: UUID
    ) -> Data {
        Data("\(protocolVersion)|\(peerID.uuidString)|\(groupID)|\(displayName)|\(nonce.uuidString)".utf8)
    }

    private nonisolated static func validate(_ hello: Hello, config: Configuration) throws {
        guard hello.kind == "hello", hello.protocolVersion == config.protocolVersion else { throw BackendError.protocolVersion }
        guard hello.groupID == config.groupID, hello.peerID != config.localPeerID else { throw BackendError.groupAuthenticationFailed }
        let input = authenticationInput(
            protocolVersion: hello.protocolVersion,
            peerID: hello.peerID,
            groupID: hello.groupID,
            displayName: hello.displayName,
            nonce: hello.nonce
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            hello.authenticationTag,
            authenticating: input,
            using: config.groupKey
        ) else { throw BackendError.groupAuthenticationFailed }
    }

    private nonisolated static func channel(named value: String) -> Channel? {
        switch value {
        case "control": .control
        case "event": .event
        case "chunk": .chunk
        case "audio": .audio
        default: nil
        }
    }

    private nonisolated static func channelName(_ value: Channel) -> String {
        switch value {
        case .control: "control"
        case .event: "event"
        case .chunk: "chunk"
        case .audio: "audio"
        }
    }

    private enum BackendError: Error, CustomStringConvertible {
        case invalidPeerID, invalidGroupID, invalidDisplayName, invalidGroupKey, invalidIdentity
        case identityImportFailed(OSStatus), certificateImportFailed, privateKeyImportFailed(String)
        case businessBeforeAuthentication, groupAuthenticationFailed
        case duplicateDirection, unexpectedPeerIdentity, protocolVersion, invalidTLVType, peerUnavailable, invalidPayload, payloadTooLarge
        var description: String {
            switch self {
            case .invalidPeerID: "localPeerID must be a UUID"
            case .invalidGroupID: "groupID is required"
            case .invalidDisplayName: "displayName is required"
            case .invalidGroupKey: "groupKeyBase64 must contain at least 32 bytes"
            case .invalidIdentity: "provide identityPKCS12Base64 or both certificateDERBase64 and privateKeyPKCS8Base64"
            case let .identityImportFailed(status): "PKCS#12 identity import failed (OSStatus \(status))"
            case .certificateImportFailed: "certificate DER import failed or its public-key attributes are unavailable"
            case let .privateKeyImportFailed(message): "PKCS#8 private-key import failed: \(message)"
            case .businessBeforeAuthentication: "business TLV received before authenticated hello"
            case .groupAuthenticationFailed: "peer group authentication failed"
            case .duplicateDirection: "connection violates stable peer-ID dial direction"
            case .unexpectedPeerIdentity: "authenticated hello peerID does not match the discovered Bonjour endpoint"
            case .protocolVersion: "protocol version mismatch"
            case .invalidTLVType: "TLV channel must be control, event, chunk, or audio"
            case .peerUnavailable: "peerHandle is not connected"
            case .invalidPayload: "invalid payloadBase64"
            case .payloadTooLarge: "payload exceeds per-frame safety limit"
            }
        }
    }
}

// MARK: - Module-private C ABI

public typealias PeerTransportCEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UInt) -> Void
private final class PeerTransportCallbackBox: @unchecked Sendable {
    let callback: PeerTransportCEventCallback
    let context: UInt
    init(callback: @escaping PeerTransportCEventCallback, context: UInt) { self.callback = callback; self.context = context }
    func send(_ data: Data) { data.withUnsafeBytes { callback($0.bindMemory(to: UInt8.self).baseAddress, data.count, context) } }
}
private final class PeerTransportHandleSource: @unchecked Sendable {
    static let shared = PeerTransportHandleSource()
    private let lock = NSLock()
    private var next: UInt64 = 1
    func allocate() -> UInt64 { lock.withLock { defer { next &+= 1 }; return next } }
}
private final class PeerTransportRegistry: @unchecked Sendable {
    static let shared = PeerTransportRegistry()
    private let lock = NSLock()
    private var values: [UInt64: TcPeerTransportAppleBackend] = [:]
    func insert(_ value: TcPeerTransportAppleBackend, for handle: UInt64) { lock.withLock { values[handle] = value } }
    func get(_ handle: UInt64) -> TcPeerTransportAppleBackend? { lock.withLock { values[handle] } }
    func remove(_ handle: UInt64) -> TcPeerTransportAppleBackend? { lock.withLock { values.removeValue(forKey: handle) } }
}

@_cdecl("tc_peer_transport_apple_create")
public func tc_peer_transport_apple_create(_ callback: PeerTransportCEventCallback?, _ context: UInt) -> UInt64 {
    guard let callback else { return 0 }
    let handle = PeerTransportHandleSource.shared.allocate()
    let box = PeerTransportCallbackBox(callback: callback, context: context)
    PeerTransportRegistry.shared.insert(TcPeerTransportAppleBackend(eventSink: box.send), for: handle)
    return handle
}

@_cdecl("tc_peer_transport_apple_submit")
public func tc_peer_transport_apple_submit(_ handle: UInt64, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard let backend = PeerTransportRegistry.shared.get(handle), length >= 0, length == 0 || bytes != nil else { return false }
    let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
    Task { await backend.submit(data) }
    return true
}

@_cdecl("tc_peer_transport_apple_destroy")
public func tc_peer_transport_apple_destroy(_ handle: UInt64) {
    guard let backend = PeerTransportRegistry.shared.remove(handle) else { return }
    Task { await backend.shutdown() }
}
