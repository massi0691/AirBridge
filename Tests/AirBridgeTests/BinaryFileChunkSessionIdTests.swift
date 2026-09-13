//
//  BinaryFileChunkSessionIdTests.swift
//  AirBridgeTests
//
//  Tests du sessionId dans BinaryFileChunkPayload v2.
//
//  Le format binaire v2 a grandi de 29 à 45 octets d'en-tête : le
//  `sessionId` (16 octets) est désormais logé aux offsets 29..44 et lie
//  chaque chunk à la session active. Un chunk issu d'une autre session
//  (ou d'un attaquant) est rejeté à la réception par AirBridgeCore.
//

import XCTest
@testable import AirBridge

final class BinaryFileChunkSessionIdTests: XCTestCase {

    /// Le sessionId doit être préservé par un round-trip encode → decode.
    func testSessionIdEncodedAtOffset29() {
        let sessionId = UUID()
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(repeating: 0x42, count: 128),
            isLastChunk: false,
            sessionId: sessionId
        )

        let encoded = payload.encode()
        let decoded = try! BinaryFileChunkPayload.decode(encoded)

        XCTAssertEqual(
            decoded.sessionId, sessionId,
            "Le sessionId doit être préservé après encode/decode"
        )
    }

    /// Le header binaire v2 doit faire 45 octets : 4 (length) + 16 (transferID)
    /// + 8 (offset) + 1 (flags) + 16 (sessionId).
    func testSessionIdChangesHeaderSize() {
        XCTAssertEqual(
            BinaryFileChunkPayload.headerSize, 45,
            "L'en-tête binaire v2 doit faire 45 octets"
        )

        // Vérification croisée par encodage d'un payload vide.
        let empty = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(),
            isLastChunk: false,
            sessionId: UUID()
        )
        XCTAssertEqual(empty.encode().count, 45)
    }

    /// Les 16 octets à l'offset 29..45 doivent correspondre exactement
    /// à la représentation binaire du sessionId.
    func testEncodedDataContainsSessionIdBytes() {
        let sessionId = UUID(uuidString: "DEADBEEF-CAFE-1234-5678-90ABCDEF0123")!
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(count: 8),
            isLastChunk: false,
            sessionId: sessionId
        )

        let encoded = payload.encode()
        let sessionData = encoded.subdata(in: 29..<45)
        let extracted = sessionData.withUnsafeBytes { bytes in
            UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
        }
        XCTAssertEqual(
            extracted, sessionId,
            "Les 16 octets à l'offset 29 doivent encoder le sessionId"
        )
    }
}
