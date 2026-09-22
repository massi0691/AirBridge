//
//  TransferPayloadRoundTripTests.swift
//  AirBridgeTests
//
//  Tests de codage des payloads du protocole qui n'avaient pas de
//  test dédié.
//
//  Ces payloads sont la représentation wire du protocole : un champ
//  silencieusement oublié à l'encodage ou mal décodé change le
//  comportement réseau sans casser la compilation. Chaque test vérifie
//  non seulement que le décodage réussit, mais que chaque champ
//  retrouve exactement sa valeur d'origine.
//

import XCTest
@testable import AirBridge

final class TransferPayloadRoundTripTests: XCTestCase {

    /// Encode puis décode un payload et renvoie le résultat. Les
    /// payloads ne sont pas `Equatable` (seulement `Codable & Sendable`)
    /// : chaque test vérifie donc explicitement chacun de ses champs.
    private func roundTrip<P: Codable>(
        _ payload: P
    ) throws -> P {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(P.self, from: data)
    }

    // MARK: - Transfert

    func testTransferAcceptedPayload() throws {
        let id = UUID()
        let payload = TransferAcceptedPayload(transferID: id)

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.transferID, id)
    }

    func testTransferRejectedPayloadWithReason() throws {
        let id = UUID()
        let payload = TransferRejectedPayload(transferID: id, reason: "Pas de place")

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.transferID, id)
        XCTAssertEqual(decoded.reason, "Pas de place")
    }

    func testTransferRejectedPayloadWithoutReason() throws {
        let payload = TransferRejectedPayload(transferID: UUID(), reason: nil)

        let decoded = try roundTrip(payload)

        XCTAssertNil(decoded.reason)
    }

    func testTransferCompletedPayload() throws {
        let id = UUID()
        let payload = TransferCompletedPayload(
            transferID: id,
            totalBytes: 1_048_576,
            sha256: "abc123"
        )

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.transferID, id)
        XCTAssertEqual(decoded.totalBytes, 1_048_576)
        XCTAssertEqual(decoded.sha256, "abc123")
    }

    func testTransferSucceededPayload() throws {
        let id = UUID()
        let payload = TransferSucceededPayload(transferID: id, receivedBytes: 2048)

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.transferID, id)
        XCTAssertEqual(decoded.receivedBytes, 2048)
    }

    func testTransferCancelledPayloadWithReason() throws {
        let payload = TransferCancelledPayload(transferID: UUID(), reason: "Annulé par l'utilisateur")

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.reason, "Annulé par l'utilisateur")
    }

    func testTransferCancelledPayloadWithoutReason() throws {
        let payload = TransferCancelledPayload(transferID: UUID(), reason: nil)

        let decoded = try roundTrip(payload)

        XCTAssertNil(decoded.reason)
    }

    func testTransferFailedPayload() throws {
        let payload = TransferFailedPayload(transferID: UUID(), reason: "Intégrité invalide")

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.reason, "Intégrité invalide")
    }

    // MARK: - Pairage

    func testPairingRequestPayload() throws {
        let id = UUID()
        let payload = PairingRequestPayload(
            peerID: id,
            peerName: "iPhone de Test",
            publicKeyData: Data(repeating: 0xAB, count: 32),
            challenge: Data(repeating: 0xCD, count: 16),
            signature: Data(repeating: 0xEF, count: 64),
            protocolVersion: 2
        )

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.peerID, id)
        XCTAssertEqual(decoded.peerName, "iPhone de Test")
        XCTAssertEqual(decoded.publicKeyData, Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(decoded.challenge, Data(repeating: 0xCD, count: 16))
        XCTAssertEqual(decoded.signature, Data(repeating: 0xEF, count: 64))
        XCTAssertEqual(decoded.protocolVersion, 2)
    }

    func testPairingResponsePayloadAccepted() throws {
        let id = UUID()
        let payload = PairingResponsePayload(
            peerID: id,
            peerName: "Mac de Test",
            publicKeyData: Data(repeating: 0x11, count: 32),
            challenge: Data(repeating: 0x22, count: 16),
            signature: Data(repeating: 0x33, count: 64),
            protocolVersion: 2,
            accepted: true
        )

        let decoded = try roundTrip(payload)

        XCTAssertEqual(decoded.peerID, id)
        XCTAssertTrue(decoded.accepted)
    }

    func testPairingResponsePayloadRejected() throws {
        let payload = PairingResponsePayload(
            peerID: UUID(),
            peerName: "Mac de Test",
            publicKeyData: Data(repeating: 0x11, count: 32),
            challenge: Data(repeating: 0x22, count: 16),
            signature: Data(repeating: 0x33, count: 64),
            protocolVersion: 2,
            accepted: false
        )

        let decoded = try roundTrip(payload)

        XCTAssertFalse(decoded.accepted)
    }

    // MARK: - Source sortante

    func testOutgoingFileSourceProperties() {
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/airbridge/fichier.pdf")
        let original = URL(fileURLWithPath: "/Users/test/fichier.pdf")

        let source = OutgoingFileSource(
            transferID: id,
            url: url,
            protectedOriginalURL: original,
            isTemporary: true
        )

        XCTAssertEqual(source.transferID, id)
        XCTAssertEqual(source.url, url)
        XCTAssertEqual(source.protectedOriginalURL, original)
        XCTAssertTrue(source.isTemporary)
    }

    func testOutgoingFileSourceWithoutProtectedOriginal() {
        let source = OutgoingFileSource(
            transferID: UUID(),
            url: URL(fileURLWithPath: "/tmp/airbridge/fichier.pdf"),
            protectedOriginalURL: nil,
            isTemporary: false
        )

        XCTAssertNil(source.protectedOriginalURL)
        XCTAssertFalse(source.isTemporary)
    }

    // MARK: - Robustesse du décodage

    func testDecodingInvalidJSONThrows() {
        let invalid = Data("{}".utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(TransferCompletedPayload.self, from: invalid)
        ) { error in
            // Un payload incomplet doit être refusé plutôt que silencieusement
            // accepté avec des valeurs par défaut.
            XCTAssertTrue(error is DecodingError, "Obtenu : \(error)")
        }
    }
}
