import CryptoKit
import Foundation

struct NearbyGroupCredentials: Codable, Sendable, Equatable {
    static let defaultsKey = "nearbyGroupCredentials"

    let id: String
    let keyData: Data

    static func derive(fromPIN rawPIN: String) throws -> Self {
        let pin = rawPIN.filter(\.isNumber)
        guard pin.count == 6, pin == rawPIN.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw GroupPairingError.invalidPIN
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
            salt: Data("travel-companion-ble-pin-v1".utf8),
            info: Data("nearby-group-control-key".utf8),
            outputByteCount: 32
        )
        let keyData = key.withUnsafeBytes { Data($0) }
        let digest = SHA256.hash(data: keyData + Data("nearby-group-id".utf8))
        let id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return Self(id: id, keyData: keyData)
    }

    static func generatePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    func authenticationTag(for payload: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: keyData)))
    }

    func authenticates(_ tag: Data, payload: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: payload, using: SymmetricKey(data: keyData))
    }
}

enum GroupPairingError: LocalizedError {
    case invalidPIN

    var errorDescription: String? {
        switch self {
        case .invalidPIN:
            "PIN 必须是 6 位数字"
        }
    }
}

struct LocationSample: Codable, Sendable, Hashable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let speed: Double
    let course: Double
    let sampledAt: Date
    let stationary: Bool

    var age: TimeInterval { Date.now.timeIntervalSince(sampledAt) }
}

enum LocationResponseStatus: String, Codable, Sendable {
    case fresh
    case stale
    case timeout
    case unavailable
    case sharingPaused
}

enum ControlKind: Codable, Sendable, Hashable {
    case groupHello(groupID: String, name: String)
    case dataAvailable(cursor: UInt64)
    case locationRequest(desiredFreshness: TimeInterval, deadline: Date)
    case locationResponse(requestID: UUID, sample: LocationSample?, status: LocationResponseStatus)
    case precisionLocateRequest(deadline: Date)
    case precisionLocateResponse(requestID: UUID, accepted: Bool, reason: String?)
    case precisionLocateCancel(requestID: UUID)
    case callOffer(callID: UUID, displayName: String)
    case callAnswer(callID: UUID)
    case callReject(callID: UUID, reason: String)
    case callEnd(callID: UUID)
    case ack(messageID: UUID)
}

struct ControlMessage: Codable, Sendable, Identifiable, Hashable {
    static let currentProtocolVersion = 2

    let protocolVersion: Int
    let id: UUID
    let senderID: UUID
    let sequence: UInt64
    let createdAt: Date
    let ttl: TimeInterval
    let kind: ControlKind

    init(
        id: UUID = UUID(),
        senderID: UUID,
        sequence: UInt64,
        createdAt: Date = .now,
        ttl: TimeInterval = 30,
        kind: ControlKind
    ) {
        protocolVersion = Self.currentProtocolVersion
        self.id = id
        self.senderID = senderID
        self.sequence = sequence
        self.createdAt = createdAt
        self.ttl = ttl
        self.kind = kind
    }

    var isExpired: Bool { Date.now.timeIntervalSince(createdAt) > ttl }
}

struct ReplicatedTextEvent: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let senderID: UUID
    let sequence: UInt64
    let body: String
    let createdAt: Date
}

struct ResourceManifest: Codable, Sendable, Hashable {
    let id: UUID
    let name: String
    let byteCount: Int
    let chunkSize: Int
    let chunkDigests: [Data]
    let digest: Data
}

struct ResourceChunk: Codable, Sendable, Hashable {
    let resourceID: UUID
    let index: Int
    let data: Data
    let digest: Data
}

enum DataPlaneMessage: Codable, Sendable, Hashable {
    case hello(deviceID: UUID, name: String, groupID: String, nonce: UUID, authenticationTag: Data)
    case ping(id: UUID, sentAt: Date)
    case pong(id: UUID, sentAt: Date)
    case text(ReplicatedTextEvent)
    case syncPull(after: UInt64)
    case syncBatch(events: [ReplicatedTextEvent], latestCursor: UInt64)
    case resourceManifest(ResourceManifest)
    case resourceMissing(resourceID: UUID, indexes: [Int])
    case resourceChunk(ResourceChunk)
    case resourceComplete(resourceID: UUID)
    case nearbyToken(senderID: UUID, peerID: UUID, requestID: UUID, token: Data)
}

struct VoicePacket: Codable, Sendable, Hashable {
    let callID: UUID
    let senderID: UUID
    let sequence: UInt64
    let sentAt: Date
    let sampleRate: Double
    let channelCount: UInt32
    let pcm16: Data
}

struct AuthenticatedVoicePacket: Codable, Sendable, Hashable {
    let packet: VoicePacket
    let authenticationTag: Data
}

struct PendingPrecisionRequest: Identifiable, Sendable, Hashable {
    let id: UUID
    let senderID: UUID
    let receivedAt: Date
    let deadline: Date

    var isExpired: Bool { deadline < .now }
}

enum LocationExperimentStrategy: String, CaseIterable, Codable, Identifiable, Sendable {
    case bleOnDemand
    case adaptiveBackground
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bleOnDemand: "仅 BLE 按需"
        case .adaptiveBackground: "低频自适应"
        case .hybrid: "自适应 + BLE 按需"
        }
    }
}
