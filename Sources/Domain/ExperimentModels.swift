import Foundation

enum ExperimentKind: String, Codable, CaseIterable, Sendable {
    case capability
    case wifiAware
    case bluetooth
    case location
    case uwb
    case call
    case lifecycle
    case energy
}

enum ExperimentOutcome: String, Codable, Sendable {
    case info
    case success
    case failure
    case timeout
    case skipped
}

struct ExperimentRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: ExperimentKind
    let name: String
    let phase: String
    let outcome: ExperimentOutcome
    let latencyMilliseconds: Double?
    let byteCount: Int?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        kind: ExperimentKind,
        name: String,
        phase: String,
        outcome: ExperimentOutcome,
        latencyMilliseconds: Double? = nil,
        byteCount: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.name = name
        self.phase = phase
        self.outcome = outcome
        self.latencyMilliseconds = latencyMilliseconds
        self.byteCount = byteCount
        self.metadata = metadata
    }
}

struct MetricSummary: Codable, Identifiable, Sendable, Hashable {
    var id: String { "\(kind.rawValue):\(name)" }
    let kind: ExperimentKind
    let name: String
    let count: Int
    let successRate: Double
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let totalBytes: Int
}

enum Percentiles {
    static func value(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, min(Double(sorted.count - 1), percentile * Double(sorted.count - 1)))
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = rank - Double(lower)
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * fraction)
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return (Double(parts.seconds) * 1_000) + (Double(parts.attoseconds) / 1e15)
    }
}

