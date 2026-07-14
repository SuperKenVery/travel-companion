import Foundation
import OSLog

private let experimentRecordLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "ExperimentRecord"
)

actor ExperimentLogStore {
    private let rootURL: URL
    private let logURL: URL
    private var records: [ExperimentRecord] = []
    private var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        rootURL = documents.appending(path: "Diagnostics", directoryHint: .isDirectory)
        logURL = rootURL.appending(path: "experiment-records.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let localDecoder = JSONDecoder()
        localDecoder.dateDecodingStrategy = .iso8601
        decoder = localDecoder
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: logURL),
           let text = String(data: data, encoding: .utf8) {
            records = text.split(separator: "\n").compactMap { line in
                try? localDecoder.decode(ExperimentRecord.self, from: Data(line.utf8))
            }
        }
    }

    func append(_ record: ExperimentRecord) {
        records.append(record)
        writeToOSLog(record)
        if let encoded = try? encoder.encode(record) {
            var line = encoded
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                }
            } else {
                try? line.write(to: logURL, options: .atomic)
            }
        }
        yieldUpdate()
    }

    func recent(limit: Int = 200) -> [ExperimentRecord] {
        return Array(records.suffix(limit).reversed())
    }

    func summaries() -> [MetricSummary] {
        let groups = Dictionary(grouping: records) { "\($0.kind.rawValue)|\($0.name)" }
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            let attempts = group.filter { $0.outcome != .info && $0.outcome != .skipped }
            let successful = attempts.filter { $0.outcome == .success }
            let latencies = successful.compactMap(\.latencyMilliseconds)
            return MetricSummary(
                kind: first.kind,
                name: first.name,
                count: attempts.count,
                successRate: attempts.isEmpty ? 0 : Double(successful.count) / Double(attempts.count),
                p50Milliseconds: Percentiles.value(latencies, percentile: 0.50),
                p95Milliseconds: Percentiles.value(latencies, percentile: 0.95),
                totalBytes: group.compactMap(\.byteCount).reduce(0, +)
            )
        }
        .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    func clear() {
        records.removeAll()
        try? FileManager.default.removeItem(at: logURL)
        yieldUpdate()
    }

    func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(id) }
        }
        return stream
    }

    private func yieldUpdate() {
        for continuation in updateContinuations.values {
            continuation.yield(())
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    private func writeToOSLog(_ record: ExperimentRecord) {
        let kind = record.kind.rawValue
        let outcome = record.outcome.rawValue
        let latency = record.latencyMilliseconds.map { String(format: "%.3f", $0) } ?? "none"
        let byteCount = record.byteCount.map(String.init) ?? "none"
        let metadata = record.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let message = "record kind=\(kind) name=\(record.name) phase=\(record.phase) outcome=\(outcome) latencyMilliseconds=\(latency) byteCount=\(byteCount) metadata={\(metadata)}"

        switch record.outcome {
        case .failure, .timeout:
            experimentRecordLogger.error("\(message, privacy: .public)")
        case .success, .info, .skipped:
            experimentRecordLogger.notice("\(message, privacy: .public)")
        }
    }

    func exportArchive(deviceMetadata: [String: String]) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let export = rootURL.appending(path: "travel-validation-\(stamp).json")
        let payload = ExportPayload(
            generatedAt: .now,
            device: deviceMetadata,
            summaries: summaries(),
            records: records
        )
        let exportEncoder = JSONEncoder()
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        exportEncoder.dateEncodingStrategy = .iso8601
        try exportEncoder.encode(payload).write(to: export, options: .atomic)
        return export
    }
}

private struct ExportPayload: Codable {
    let generatedAt: Date
    let device: [String: String]
    let summaries: [MetricSummary]
    let records: [ExperimentRecord]
}
