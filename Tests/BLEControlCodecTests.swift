import Foundation
import XCTest
@testable import TravelCompanion

final class BLEControlCodecTests: XCTestCase {
    func testEncryptedFragmentedRoundTrip() throws {
        let codec = BLEControlCodec()
        let original = ControlMessage(
            senderID: UUID(),
            sequence: 7,
            ttl: 60,
            kind: .callOffer(callID: UUID(), displayName: String(repeating: "同行", count: 60))
        )
        let encrypted = try codec.encode(original)
        let packets = codec.fragment(encrypted, messageID: original.id, maximumPacketSize: 48)
        XCTAssertGreaterThan(packets.count, 1)

        let fragments = try packets.reversed().map(codec.parse)
        XCTAssertTrue(fragments.allSatisfy { $0.messageID == original.id })
        let reassembled = fragments.sorted { $0.index < $1.index }.reduce(into: Data()) {
            $0.append($1.payload)
        }
        XCTAssertEqual(try codec.decode(reassembled), original)
    }

    func testTamperFailsAuthentication() throws {
        let codec = BLEControlCodec()
        let message = ControlMessage(senderID: UUID(), sequence: 1, kind: .ack(messageID: UUID()))
        var encrypted = try codec.encode(message)
        encrypted[encrypted.index(before: encrypted.endIndex)] ^= 0x01
        XCTAssertThrowsError(try codec.decode(encrypted))
    }
}

