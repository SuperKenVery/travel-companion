import Foundation
import XCTest
@testable import TravelCompanion

final class PersistenceTests: XCTestCase {
    func testEventStoreDeduplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ValidationEventStore(directory: root)
        let event = ReplicatedTextEvent(id: UUID(), senderID: UUID(), sequence: 1, body: "hello", createdAt: .now)
        let firstInsert = await store.append(event)
        let secondInsert = await store.append(event)
        let events = await store.allEvents()
        XCTAssertTrue(firstInsert)
        XCTAssertFalse(secondInsert)
        XCTAssertEqual(events, [event])
    }

    func testChunkedResourceIntegrityAndCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResourceTransferStore(root: root)
        let (manifest, fileURL) = try await store.prepareOutgoing(byteCount: 256 * 1_024, chunkSize: 16 * 1_024)
        let chunks = try await store.chunks(for: manifest, fileURL: fileURL)
        let missing = try await store.accept(manifest)
        XCTAssertEqual(missing.count, chunks.count)
        var completion: ResourceTransferStore.Completion?
        for chunk in chunks.reversed() {
            completion = try await store.accept(chunk) ?? completion
        }
        XCTAssertEqual(completion?.byteCount, manifest.byteCount)
        XCTAssertNotNil(completion?.url)
    }
}
