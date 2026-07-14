import Foundation

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
    static let currentProtocolVersion = 1

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
    case hello(deviceID: UUID, name: String)
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
