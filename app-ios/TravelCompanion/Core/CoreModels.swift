import Foundation

struct AppSnapshot: Codable, Sendable, Equatable {
    var protocolVersion: UInt16
    var revision: UInt64
    var lifecycle: LifecycleSnapshot
    var identity: IdentitySnapshot
    var group: GroupSnapshot?
    var peers: [PeerSnapshot]
    var conversations: [ConversationSnapshot]
    var places: [PlaceSnapshot]
    var document: DocumentSnapshot
    var activeCall: CallSnapshot?
    var pendingPrecisionRequests: [PrecisionRequestSnapshot]

    static let empty = AppSnapshot(
        protocolVersion: 1,
        revision: 0,
        lifecycle: .idle,
        identity: .placeholder,
        group: nil,
        peers: [],
        conversations: [],
        places: [],
        document: .empty,
        activeCall: nil,
        pendingPrecisionRequests: []
    )
}

struct LifecycleSnapshot: Codable, Sendable, Equatable {
    var isTraveling: Bool
    var isForeground: Bool
    var locationSharingEnabled: Bool
    var phase: String
    var blockers: [CapabilityBlocker]
    var lastError: String?

    static let idle = LifecycleSnapshot(
        isTraveling: false,
        isForeground: true,
        locationSharingEnabled: true,
        phase: "idle",
        blockers: [],
        lastError: nil
    )
}

struct CapabilityBlocker: Codable, Sendable, Hashable, Identifiable {
    var capability: String
    var reason: String
    var recoverySuggestion: String?

    var id: String { capability }
}

struct IdentitySnapshot: Codable, Sendable, Equatable {
    var peerID: String
    var displayName: String

    static let placeholder = IdentitySnapshot(peerID: "", displayName: "此 iPhone")
}

struct GroupSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var epoch: UInt64
    var ownerID: String
    var invitePIN: String?
    var members: [MemberSnapshot]
}

struct MemberSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var role: String
    var isReachable: Bool
    var lastSeenAt: Date?
}

struct PeerSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var isReachable: Bool
    var lastSeenAt: Date?
    var location: LocationSnapshot?
    var ranging: RangingSnapshot?
    var locationSharingPaused: Bool
    var precisionState: String
}

struct LocationSnapshot: Codable, Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var horizontalAccuracyMeters: Double
    var speedMetersPerSecond: Double?
    var courseDegrees: Double?
    var sampledAt: Date
    var receivedAt: Date
    var isStale: Bool
    var distanceMeters: Double?
    var bearingDegrees: Double?
    var source: String
}

struct RangingSnapshot: Codable, Sendable, Equatable {
    var distanceMeters: Double?
    var directionDegrees: Double?
    var distanceSource: String
    var directionSource: String
    var updatedAt: Date
}

struct ConversationSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var kind: String
    var participantIDs: [String]
    var unreadCount: Int
    var messages: [MessageSnapshot]
}

struct MessageSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var senderID: String
    var senderName: String
    var kind: String
    var text: String?
    var resource: ResourceSnapshot?
    var createdAt: Date
    var isOutgoing: Bool
    var delivery: DeliverySnapshot
}

struct ResourceSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var mimeType: String
    var localPath: String?
    var byteCount: UInt64
    var transferredBytes: UInt64
    var state: String

    var progress: Double {
        guard byteCount > 0 else { return 0 }
        return min(1, Double(transferredBytes) / Double(byteCount))
    }
}

struct DeliverySnapshot: Codable, Sendable, Equatable {
    var phase: String
    var relayCount: Int
    var deliveredMemberIDs: [String]
    var targetMemberIDs: [String]
    var error: String?
}

struct PlaceSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var note: String
    var latitude: Double
    var longitude: Double
    var authorID: String
    var authorName: String
    var createdAt: Date
    var updatedAt: Date
}

struct DocumentSnapshot: Codable, Sendable, Equatable {
    var content: String
    var revisionID: String?
    var parentRevisionID: String?
    var contentHash: String?
    var updatedAt: Date?
    var lease: DocumentLeaseSnapshot?
    var conflicts: [DocumentConflictSnapshot]

    static let empty = DocumentSnapshot(
        content: "# Trip\n",
        revisionID: nil,
        parentRevisionID: nil,
        contentHash: nil,
        updatedAt: nil,
        lease: nil,
        conflicts: []
    )
}

struct DocumentLeaseSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var holderID: String
    var holderName: String
    var expiresAt: Date
    var isHeldByLocalPeer: Bool
}

struct DocumentConflictSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var revisionID: String
    var authorName: String
    var content: String
    var createdAt: Date
}

struct CallSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var peerID: String
    var peerName: String
    var direction: String
    var state: String
    var startedAt: Date?
}

struct PrecisionRequestSnapshot: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var requesterID: String
    var requesterName: String
    var createdAt: Date
    var expiresAt: Date
    var state: String
}

enum MediaKind: String, Codable, Sendable {
    case image
    case voice
}

enum CoreCommand: Sendable, Equatable {
    case startTravel
    case endTravel
    case createGroup(name: String)
    case joinGroup(pin: String)
    case leaveGroup
    case setLocationSharing(Bool)
    case requestPrecision(peerID: String)
    case respondPrecision(requestID: String, accept: Bool)
    case sendText(conversationID: String, body: String)
    case registerMedia(kind: MediaKind, path: String, conversationID: String)
    case cancelResource(id: String)
    case retryResource(id: String)
    case createPlace(title: String, note: String, latitude: Double, longitude: Double)
    case updatePlace(id: String, title: String, note: String, latitude: Double, longitude: Double)
    case deletePlace(id: String)
    case acquireDocumentLease
    case saveDocument(content: String, parentRevisionID: String?)
    case releaseDocumentLease
    case startCall(peerID: String)
    case answerCall(callID: String)
    case rejectCall(callID: String)
    case endCall(callID: String)
    case setForeground(Bool)
    case clearTripData
}

extension CoreCommand: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case pin
        case enabled
        case peerID
        case requestID
        case accept
        case conversationID
        case body
        case kind
        case path
        case title
        case note
        case latitude
        case longitude
        case id
        case content
        case parentRevisionID
        case callID
        case foreground
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .startTravel:
            try values.encode("startTravel", forKey: .type)
        case .endTravel:
            try values.encode("endTravel", forKey: .type)
        case .createGroup(let name):
            try values.encode("createGroup", forKey: .type)
            try values.encode(name, forKey: .name)
        case .joinGroup(let pin):
            try values.encode("joinGroup", forKey: .type)
            try values.encode(pin, forKey: .pin)
        case .leaveGroup:
            try values.encode("leaveGroup", forKey: .type)
        case .setLocationSharing(let enabled):
            try values.encode("setLocationSharing", forKey: .type)
            try values.encode(enabled, forKey: .enabled)
        case .requestPrecision(let peerID):
            try values.encode("requestPrecision", forKey: .type)
            try values.encode(peerID, forKey: .peerID)
        case .respondPrecision(let requestID, let accept):
            try values.encode("respondPrecision", forKey: .type)
            try values.encode(requestID, forKey: .requestID)
            try values.encode(accept, forKey: .accept)
        case .sendText(let conversationID, let body):
            try values.encode("sendText", forKey: .type)
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(body, forKey: .body)
        case .registerMedia(let kind, let path, let conversationID):
            try values.encode("registerMedia", forKey: .type)
            try values.encode(kind, forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(conversationID, forKey: .conversationID)
        case .cancelResource(let id):
            try values.encode("cancelResource", forKey: .type)
            try values.encode(id, forKey: .id)
        case .retryResource(let id):
            try values.encode("retryResource", forKey: .type)
            try values.encode(id, forKey: .id)
        case .createPlace(let title, let note, let latitude, let longitude):
            try values.encode("createPlace", forKey: .type)
            try values.encode(title, forKey: .title)
            try values.encode(note, forKey: .note)
            try values.encode(latitude, forKey: .latitude)
            try values.encode(longitude, forKey: .longitude)
        case .updatePlace(let id, let title, let note, let latitude, let longitude):
            try values.encode("updatePlace", forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(title, forKey: .title)
            try values.encode(note, forKey: .note)
            try values.encode(latitude, forKey: .latitude)
            try values.encode(longitude, forKey: .longitude)
        case .deletePlace(let id):
            try values.encode("deletePlace", forKey: .type)
            try values.encode(id, forKey: .id)
        case .acquireDocumentLease:
            try values.encode("acquireDocumentLease", forKey: .type)
        case .saveDocument(let content, let parentRevisionID):
            try values.encode("saveDocument", forKey: .type)
            try values.encode(content, forKey: .content)
            try values.encodeIfPresent(parentRevisionID, forKey: .parentRevisionID)
        case .releaseDocumentLease:
            try values.encode("releaseDocumentLease", forKey: .type)
        case .startCall(let peerID):
            try values.encode("startCall", forKey: .type)
            try values.encode(peerID, forKey: .peerID)
        case .answerCall(let callID):
            try values.encode("answerCall", forKey: .type)
            try values.encode(callID, forKey: .callID)
        case .rejectCall(let callID):
            try values.encode("rejectCall", forKey: .type)
            try values.encode(callID, forKey: .callID)
        case .endCall(let callID):
            try values.encode("endCall", forKey: .type)
            try values.encode(callID, forKey: .callID)
        case .setForeground(let foreground):
            try values.encode("setForeground", forKey: .type)
            try values.encode(foreground, forKey: .foreground)
        case .clearTripData:
            try values.encode("clearTripData", forKey: .type)
        }
    }
}

struct ModuleCommandEnvelope: Codable, Sendable {
    var module: String
    var command: JSONValue
}

indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct CoreErrorPayload: Codable, Sendable, Equatable {
    var code: String
    var message: String
}

struct CoreReply: Codable, Sendable {
    var snapshot: AppSnapshot?
    var error: CoreErrorPayload?
}
