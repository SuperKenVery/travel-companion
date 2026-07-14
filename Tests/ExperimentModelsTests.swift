import XCTest
@testable import TravelCompanion

final class ExperimentModelsTests: XCTestCase {
    func testPercentilesInterpolateAndHandleEmptyInput() throws {
        XCTAssertNil(Percentiles.value([], percentile: 0.5))
        XCTAssertEqual(Percentiles.value([40, 10, 30, 20], percentile: 0.5), 25)
        let p95 = try XCTUnwrap(Percentiles.value([1, 2, 3, 4, 5], percentile: 0.95))
        XCTAssertEqual(p95, 4.8, accuracy: 0.0001)
    }

    func testControlMessageCodableAndExpiration() throws {
        let requestID = UUID()
        let message = ControlMessage(
            id: requestID,
            senderID: UUID(),
            sequence: 42,
            createdAt: .now.addingTimeInterval(-20),
            ttl: 10,
            kind: .locationRequest(desiredFreshness: 15, deadline: .now)
        )
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.id, requestID)
        XCTAssertTrue(decoded.isExpired)
    }

}
