import Foundation
import XCTest
@testable import TravelCompanion

final class CoreModelsTests: XCTestCase {
    func testCommandEncodingUsesStableTaggedShape() throws {
        let data = try JSONEncoder().encode(
            CoreCommand.respondPrecision(requestID: "request-1", accept: true)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "respondPrecision")
        XCTAssertEqual(object["requestID"] as? String, "request-1")
        XCTAssertEqual(object["accept"] as? Bool, true)
    }

    func testResourceProgressIsBounded() {
        let partial = ResourceSnapshot(
            id: "resource",
            mimeType: "image/heic",
            localPath: nil,
            byteCount: 100,
            transferredBytes: 140,
            state: "transferring"
        )
        let empty = ResourceSnapshot(
            id: "empty",
            mimeType: "application/octet-stream",
            localPath: nil,
            byteCount: 0,
            transferredBytes: 0,
            state: "queued"
        )

        XCTAssertEqual(partial.progress, 1)
        XCTAssertEqual(empty.progress, 0)
    }

    func testEmptySnapshotRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            AppSnapshot.self,
            from: encoder.encode(AppSnapshot.empty)
        )

        XCTAssertEqual(decoded, .empty)
    }
}
