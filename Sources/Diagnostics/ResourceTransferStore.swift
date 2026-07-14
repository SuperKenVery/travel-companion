import CryptoKit
import Foundation

actor ResourceTransferStore {
    struct Completion: Sendable {
        let resourceID: UUID
        let url: URL
        let byteCount: Int
    }

    private let rootURL: URL
    private var manifests: [UUID: ResourceManifest] = [:]
    private var startedAt: [UUID: ContinuousClock.Instant] = [:]

    init(fileManager: FileManager = .default, root customRoot: URL? = nil) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = customRoot ?? base.appending(path: "Validation/Transfers", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func prepareOutgoing(byteCount: Int, chunkSize: Int = 64 * 1024) throws -> (ResourceManifest, URL) {
        let id = UUID()
        let directory = directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "outgoing.bin")
        let data = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ 17) })
        try data.write(to: fileURL, options: .atomic)
        let chunks = data.chunked(maximumSize: chunkSize)
        let manifest = ResourceManifest(
            id: id,
            name: "validation-\(byteCount).bin",
            byteCount: byteCount,
            chunkSize: chunkSize,
            chunkDigests: chunks.map { Data(SHA256.hash(data: $0)) },
            digest: Data(SHA256.hash(data: data))
        )
        manifests[id] = manifest
        try JSONEncoder().encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)
        return (manifest, fileURL)
    }

    func chunks(for manifest: ResourceManifest, fileURL: URL, indexes: [Int]? = nil) throws -> [ResourceChunk] {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let all = data.chunked(maximumSize: manifest.chunkSize)
        let selected = indexes ?? Array(all.indices)
        return try selected.map { index in
            guard all.indices.contains(index) else { throw TransferError.invalidChunkIndex }
            return ResourceChunk(
                resourceID: manifest.id,
                index: index,
                data: all[index],
                digest: Data(SHA256.hash(data: all[index]))
            )
        }
    }

    func accept(_ manifest: ResourceManifest) throws -> [Int] {
        manifests[manifest.id] = manifest
        startedAt[manifest.id] = ContinuousClock.now
        let directory = directory(for: manifest.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)
        return missingIndexes(for: manifest)
    }

    func accept(_ chunk: ResourceChunk) throws -> Completion? {
        guard let manifest = manifests[chunk.resourceID],
              manifest.chunkDigests.indices.contains(chunk.index),
              Data(SHA256.hash(data: chunk.data)) == chunk.digest,
              chunk.digest == manifest.chunkDigests[chunk.index]
        else { throw TransferError.integrityFailure }

        let destination = directory(for: chunk.resourceID).appending(path: "chunk-\(chunk.index)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try chunk.data.write(to: destination, options: .atomic)
        }

        guard missingIndexes(for: manifest).isEmpty else { return nil }
        let completed = directory(for: chunk.resourceID).appending(path: "completed.bin")
        FileManager.default.createFile(atPath: completed.path, contents: nil)
        let handle = try FileHandle(forWritingTo: completed)
        defer { try? handle.close() }
        for index in manifest.chunkDigests.indices {
            let data = try Data(contentsOf: directory(for: chunk.resourceID).appending(path: "chunk-\(index)"))
            try handle.write(contentsOf: data)
        }
        let completedData = try Data(contentsOf: completed, options: .mappedIfSafe)
        guard completedData.count == manifest.byteCount,
              Data(SHA256.hash(data: completedData)) == manifest.digest
        else { throw TransferError.integrityFailure }
        return Completion(resourceID: manifest.id, url: completed, byteCount: completedData.count)
    }

    func missingIndexes(for manifest: ResourceManifest) -> [Int] {
        manifest.chunkDigests.indices.filter { index in
            !FileManager.default.fileExists(
                atPath: directory(for: manifest.id).appending(path: "chunk-\(index)").path
            )
        }
    }

    private func directory(for id: UUID) -> URL {
        rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    enum TransferError: Error {
        case invalidChunkIndex
        case integrityFailure
    }
}

private extension Data {
    func chunked(maximumSize: Int) -> [Data] {
        guard maximumSize > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumSize).map { offset in
            subdata(in: offset..<Swift.min(offset + maximumSize, count))
        }
    }
}
