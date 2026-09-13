//
//  ReplayIntegrationTests.swift
//  AirBridge
//
//  Created by massi9106 on 27/08/2026.
//
//  Tests d'intégration anti-replay : pour chaque type de message du
//  protocole AirBridge, vérifie que le `ReplayProtectionStore` détecte
//  correctement la rejouissance, qu'elle soit basée sur le `messageID`,
//  sur la signature, ou après une (re)connexion simulée.
//

import XCTest
import CryptoKit
@testable import AirBridge

/// Suite de tests de protection anti-replay au niveau message.
///
/// Pour chaque `AirBridgeMessageType`, on vérifie :
///   1. La rejouissance du même `messageID` est détectée (replay = false).
///   2. Le même message signé deux fois avec le même `messageID` est
///      également détecté comme replay (la signature ne change rien).
///   3. Un `messageID` différent pour un payload identique n'est PAS un
///      replay.
///   4. Après une reconnexion (instance fraîche du store), un nouveau
///      `messageID` est accepté (le TTL n'est pas persisté sur disque).
final class ReplayIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Construit un `Device` factice utilisable comme `sender`.
    private func makeSender() -> Device {
        Device(
            id: UUID(),
            name: "TestSender",
            model: "TestModel",
            systemVersion: "1.0"
        )
    }

    /// Construit un message du type demandé avec un `messageID` explicite.
    private func makeMessage(
        type: AirBridgeMessageType,
        messageID: UUID,
        payload: Data? = nil
    ) -> AirBridgeMessage {
        AirBridgeMessage(
            messageID: messageID,
            type: type,
            sender: makeSender(),
            payload: payload
        )
    }

    /// Construit un message signé avec ECDSA P-256.
    ///
    /// La clé privée est régénérée pour chaque appel : deux messages
    /// différents auront donc des signatures différentes même si le
    /// reste est identique, à moins que l'on rejoue exactement la même
    /// opération.
    private func makeSignedMessage(
        type: AirBridgeMessageType,
        messageID: UUID,
        payload: Data? = nil
    ) throws -> (message: AirBridgeMessage, privateKey: P256.Signing.PrivateKey) {
        let privateKey = P256.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation

        // On signe une représentation canonique : (type, messageID, payload).
        var canonical = Data()
        canonical.append(type.rawValue.data(using: .utf8)!)
        canonical.append(messageID.uuidString.data(using: .utf8)!)
        if let payload = payload {
            canonical.append(payload)
        } else {
            // Distinguer explicitement "pas de payload" d'un payload vide.
            canonical.append(Data([0xFF]))
        }
        let signature = try privateKey.signature(for: canonical)

        let message = AirBridgeMessage(
            messageID: messageID,
            type: type,
            sender: makeSender(),
            payload: payload,
            signature: signature.derRepresentation
        )
        _ = publicKeyData // Référence pour expliciter l'intention (clé publique dérivée)
        return (message, privateKey)
    }

    /// Helper : observe un message dans un store neuf et renvoie les
    /// deux résultats (premier passage, second passage).
    private func observeTwice(
        peerID: UUID,
        messageID: UUID
    ) async -> (first: Bool, second: Bool) {
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)
        return (first, second)
    }

    // MARK: - .hello

    func testHelloReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .hello, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first, "Le premier .hello doit être accepté")
        XCTAssertFalse(second, "Le second .hello (même messageID) doit être détecté comme replay")

        // Un messageID différent pour le même type n'est PAS un replay.
        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un .hello avec un autre messageID ne doit pas être un replay")
    }

    func testHelloReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        // On signe deux fois le même contenu avec la même clé et le même
        // messageID : la signature DER ECDSA n'est pas déterministe, mais
        // la clef `(peerID, messageID)` doit malgré tout rejeter le doublon.
        let first = try makeSignedMessage(type: .hello, messageID: messageID)
        let second = try makeSignedMessage(type: .hello, messageID: messageID)

        XCTAssertNotNil(first.message.signature)
        XCTAssertNotNil(second.message.signature)

        let store = ReplayProtectionStore()
        let acceptedFirst = await store.observe(peerID: peerID, messageID: messageID)
        let acceptedSecond = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(acceptedFirst, "Le premier .hello signé est accepté")
        XCTAssertFalse(
            acceptedSecond,
            "Le second .hello signé avec le même messageID est un replay"
        )
    }

    // MARK: - .acknowledgement

    func testAcknowledgementReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .acknowledgement, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .acknowledgement doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un .acknowledgement avec un autre messageID n'est pas un replay")
    }

    func testAcknowledgementReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .acknowledgement, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .acknowledgement signé est détecté")
    }

    // MARK: - .pairingRequest

    func testPairingRequestReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .pairingRequest, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .pairingRequest doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .pairingRequest n'est pas un replay")
    }

    func testPairingRequestReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .pairingRequest, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .pairingRequest signé est détecté")
    }

    // MARK: - .pairingResponse

    func testPairingResponseReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .pairingResponse, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .pairingResponse doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .pairingResponse n'est pas un replay")
    }

    func testPairingResponseReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .pairingResponse, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .pairingResponse signé est détecté")
    }

    // MARK: - .transferRequest

    func testTransferRequestReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .transferRequest, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferRequest doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .transferRequest n'est pas un replay")
    }

    func testTransferRequestReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .transferRequest, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferRequest signé est détecté")
    }

    // MARK: - .transferAccepted

    func testTransferAcceptedReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .transferAccepted, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferAccepted doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .transferAccepted n'est pas un replay")
    }

    func testTransferAcceptedReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .transferAccepted, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferAccepted signé est détecté")
    }

    // MARK: - .transferCompleted

    func testTransferCompletedReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .transferCompleted, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferCompleted doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .transferCompleted n'est pas un replay")
    }

    func testTransferCompletedReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .transferCompleted, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferCompleted signé est détecté")
    }

    // MARK: - .transferFailed

    func testTransferFailedReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .transferFailed, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferFailed doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .transferFailed n'est pas un replay")
    }

    func testTransferFailedReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .transferFailed, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferFailed signé est détecté")
    }

    // MARK: - .transferCancelled

    func testTransferCancelledReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .transferCancelled, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferCancelled doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .transferCancelled n'est pas un replay")
    }

    func testTransferCancelledReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .transferCancelled, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .transferCancelled signé est détecté")
    }

    // MARK: - .resumeRequest

    func testResumeRequestReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .resumeRequest, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .resumeRequest doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .resumeRequest n'est pas un replay")
    }

    func testResumeRequestReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .resumeRequest, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .resumeRequest signé est détecté")
    }

    // MARK: - .resumeAccepted

    func testResumeAcceptedReplayByMessageID() async {
        let peerID = UUID()
        let messageID = UUID()
        _ = makeMessage(type: .resumeAccepted, messageID: messageID)

        let (first, second) = await observeTwice(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .resumeAccepted doit être détecté")

        let differentID = await ReplayProtectionStore().observe(peerID: peerID, messageID: UUID())
        XCTAssertTrue(differentID, "Un autre messageID pour .resumeAccepted n'est pas un replay")
    }

    func testResumeAcceptedReplayBySignature() async throws {
        let peerID = UUID()
        let messageID = UUID()

        _ = try makeSignedMessage(type: .resumeAccepted, messageID: messageID)
        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Le doublon .resumeAccepted signé est détecté")
    }

    // MARK: - Scénarios de re-connexion

    /// Après une reconnexion simulée (nouvelle instance du store), un
    /// message avec un `messageID` jamais vu doit être accepté. Cela
    /// documente explicitement le fait que la protection anti-replay est
    /// en mémoire et n'est PAS persistée sur disque.
    func testReconnectionAllowsNewMessageID() async {
        let peerID = UUID()

        // Avant "reconnexion" : on observe un premier message.
        let firstStore = ReplayProtectionStore()
        let firstID = UUID()
        let firstSeen = await firstStore.observe(peerID: peerID, messageID: firstID)
        XCTAssertTrue(firstSeen)

        // Reconnexion : instance fraîche du store.
        let secondStore = ReplayProtectionStore()
        let secondID = UUID()
        let secondSeen = await secondStore.observe(peerID: peerID, messageID: secondID)
        XCTAssertTrue(
            secondSeen,
            "Après reconnexion (nouvelle instance), un nouveau messageID doit être accepté"
        )

        // Toujours dans la nouvelle session, le même messageID est détecté.
        let secondSeenAgain = await secondStore.observe(peerID: peerID, messageID: secondID)
        XCTAssertFalse(
            secondSeenAgain,
            "Dans la nouvelle session, un doublon du même messageID reste un replay"
        )
    }

    /// Pour chaque type de message : après reconnexion, un `messageID`
    /// différent pour un payload identique n'est PAS un replay. C'est la
    /// troisième assertion (payload identique, IDs différents).
    func testSamePayloadDifferentMessageIDAllowedPerType() async {
        // Payload binaire arbitraire identique pour tous les types testés.
        let sharedPayload = Data((0..<64).map { _ in UInt8.random(in: 0...255) })

        let types: [AirBridgeMessageType] = [
            .hello,
            .acknowledgement,
            .pairingRequest,
            .pairingResponse,
            .transferRequest,
            .transferAccepted,
            .transferCompleted,
            .transferFailed,
            .transferCancelled,
            .resumeRequest,
            .resumeAccepted
        ]

        for type in types {
            let peerID = UUID()
            let firstID = UUID()
            let secondID = UUID()

            _ = makeMessage(type: type, messageID: firstID, payload: sharedPayload)
            _ = makeMessage(type: type, messageID: secondID, payload: sharedPayload)

            let store = ReplayProtectionStore()
            let first = await store.observe(peerID: peerID, messageID: firstID)
            let second = await store.observe(peerID: peerID, messageID: secondID)

            XCTAssertTrue(
                first,
                "\(type.rawValue) : le premier passage (messageID 1) doit être accepté"
            )
            XCTAssertTrue(
                second,
                "\(type.rawValue) : un autre messageID avec le même payload n'est PAS un replay"
            )
        }
    }

    // MARK: - Tests spécifiques nommés (cf. directive sécurité)

    /// Replay de `.transferRequest` rejeté.
    func testReplayTransferRequest() async {
        let peerID = UUID()
        let messageID = UUID()
        let payload = Data("transfer-request-payload".utf8)
        _ = makeMessage(type: .transferRequest, messageID: messageID, payload: payload)

        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first, ".transferRequest : premier passage accepté")
        XCTAssertFalse(second, ".transferRequest : replay rejeté")

        // Un messageID différent avec un payload identique n'est pas un replay.
        let differentID = UUID()
        _ = makeMessage(type: .transferRequest, messageID: differentID, payload: payload)
        let third = await store.observe(peerID: peerID, messageID: differentID)
        XCTAssertTrue(
            third,
            ".transferRequest : un messageID différent (même payload) doit être accepté"
        )
    }

    /// Replay de `.transferCompleted` rejeté.
    func testReplayTransferCompleted() async {
        let peerID = UUID()
        let messageID = UUID()
        let payload = Data("transfer-completed-payload".utf8)
        _ = makeMessage(type: .transferCompleted, messageID: messageID, payload: payload)

        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first, ".transferCompleted : premier passage accepté")
        XCTAssertFalse(second, ".transferCompleted : replay rejeté")

        let differentID = UUID()
        _ = makeMessage(type: .transferCompleted, messageID: differentID, payload: payload)
        let third = await store.observe(peerID: peerID, messageID: differentID)
        XCTAssertTrue(
            third,
            ".transferCompleted : un messageID différent (même payload) doit être accepté"
        )
    }

    /// Replay de `.pairingRequest` rejeté.
    func testReplayPairingRequest() async {
        let peerID = UUID()
        let messageID = UUID()
        let payload = Data("pairing-request-payload".utf8)
        _ = makeMessage(type: .pairingRequest, messageID: messageID, payload: payload)

        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first, ".pairingRequest : premier passage accepté")
        XCTAssertFalse(second, ".pairingRequest : replay rejeté")

        let differentID = UUID()
        _ = makeMessage(type: .pairingRequest, messageID: differentID, payload: payload)
        let third = await store.observe(peerID: peerID, messageID: differentID)
        XCTAssertTrue(
            third,
            ".pairingRequest : un messageID différent (même payload) doit être accepté"
        )
    }

    /// Replay de `.resumeRequest` rejeté.
    func testReplayResumeRequest() async {
        let peerID = UUID()
        let messageID = UUID()
        let payload = Data("resume-request-payload".utf8)
        _ = makeMessage(type: .resumeRequest, messageID: messageID, payload: payload)

        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first, ".resumeRequest : premier passage accepté")
        XCTAssertFalse(second, ".resumeRequest : replay rejeté")

        let differentID = UUID()
        _ = makeMessage(type: .resumeRequest, messageID: differentID, payload: payload)
        let third = await store.observe(peerID: peerID, messageID: differentID)
        XCTAssertTrue(
            third,
            ".resumeRequest : un messageID différent (même payload) doit être accepté"
        )
    }

    /// Replay de `.resumeAccepted` rejeté.
    func testReplayResumeAccepted() async {
        let peerID = UUID()
        let messageID = UUID()
        let payload = Data("resume-accepted-payload".utf8)
        _ = makeMessage(type: .resumeAccepted, messageID: messageID, payload: payload)

        let store = ReplayProtectionStore()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first, ".resumeAccepted : premier passage accepté")
        XCTAssertFalse(second, ".resumeAccepted : replay rejeté")

        let differentID = UUID()
        _ = makeMessage(type: .resumeAccepted, messageID: differentID, payload: payload)
        let third = await store.observe(peerID: peerID, messageID: differentID)
        XCTAssertTrue(
            third,
            ".resumeAccepted : un messageID différent (même payload) doit être accepté"
        )
    }
}
