//
//  AuthenticationPolicyTests.swift
//  AirBridgeTests
//

import XCTest
@testable import AirBridge

final class AuthenticationPolicyTests: XCTestCase {

    // MARK: - Compatibilité v1

    /// En v1, la signature n'existait pas. Tous les messages de contrôle
    /// doivent donc être acceptés en mode permissif, quel que soit le type
    /// ou l'état de confiance du pair.
    func testV1OptionalLegacy() {
        // Messages de contrôle représentatifs
        let controlTypes: [AirBridgeMessageType] = [
            .hello,
            .acknowledgement,
            .transferRequest,
            .transferCompleted,
            .pairingRequest,
            .fileChunk
        ]

        for type in controlTypes {
            for trustState in TrustState.allCases {
                for keyMatches in [true, false] {
                    let requirement = AuthenticationPolicy.authenticationRequirement(
                        for: type,
                        protocolVersion: 1,
                        peerTrustState: trustState,
                        peerPublicKeyMatches: keyMatches
                    )
                    XCTAssertEqual(
                        requirement,
                        .optionalLegacy,
                        "En v1, \(type) avec pair=\(trustState) cléMatch=\(keyMatches) doit rester permissif"
                    )
                }
            }
        }
    }

    // MARK: - v2 : fileChunk toujours forbidden

    /// En v2, les chunks ne sont JAMAIS signés individuellement : leur
    /// authenticité est prouvée collectivement par le `transferCompleted`.
    /// Exiger une signature chunk par chunk briserait le flux binaire.
    func testV2FileChunkForbidden() {
        for trustState in TrustState.allCases {
            for keyMatches in [true, false] {
                let requirement = AuthenticationPolicy.authenticationRequirement(
                    for: .fileChunk,
                    protocolVersion: 2,
                    peerTrustState: trustState,
                    peerPublicKeyMatches: keyMatches
                )
                XCTAssertEqual(
                    requirement,
                    .forbidden,
                    "En v2, un fileChunk ne doit jamais être traité (pair=\(trustState))"
                )
            }
        }
    }

    // MARK: - v2 : pair trusted + clé match → required

    /// Cas nominal : pair de confiance ET clé publique annoncée qui
    /// correspond à celle persistée. On exige la signature contre la clé
    /// du store pour tous les messages de contrôle sensibles.
    func testV2TrustedPeerRequired() {
        let sensitiveTypes: [AirBridgeMessageType] = [
            .hello,
            .acknowledgement,
            .ping,
            .pong,
            .pairingRequest,
            .pairingResponse,
            .transferRequest,
            .transferAccepted,
            .transferRejected,
            .transferCompleted,
            .transferSucceeded,
            .transferFailed,
            .transferCancelled,
            .resumeRequest,
            .resumeAccepted
        ]

        for type in sensitiveTypes {
            let requirement = AuthenticationPolicy.authenticationRequirement(
                for: type,
                protocolVersion: 2,
                peerTrustState: .trusted,
                peerPublicKeyMatches: true
            )
            XCTAssertEqual(
                requirement,
                .required,
                "\(type) avec pair trusted et clé match doit exiger une signature"
            )
        }
    }

    // MARK: - v2 : pair pending ou blocked → required

    /// Un pair pending (clé annoncée != stockée) doit se voir exiger la
    /// signature. C'est la clé du store qui vérifiera, et elle rejettera
    /// si la clé ne correspond pas : protection contre la substitution
    /// d'identité.
    func testV2PendingPeerRequired() {
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: .transferRequest,
            protocolVersion: 2,
            peerTrustState: .pending,
            peerPublicKeyMatches: false
        )
        XCTAssertEqual(requirement, .required)
    }

    /// Un pair explicitement bloqué doit être rejeté avec exigence de
    /// signature (qui échouera puisque le store ne valide pas les bloqués).
    func testV2BlockedPeerRequired() {
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: .transferRequest,
            protocolVersion: 2,
            peerTrustState: .blocked,
            peerPublicKeyMatches: false
        )
        XCTAssertEqual(requirement, .required)
    }

    // MARK: - v2 : pair unknown + messages de premier contact

    /// Lors du premier contact, le pair n'est pas encore dans le store.
    /// Pour les messages d'identification (`hello`, `ack`, `ping`, `pong`,
    /// `pairing*`), on autorise la vérification contre la clé *annoncée*
    /// dans le message (clé éphémère du pair).
    func testV2UnknownPeerAllowlistRequiredForKnownPeer() {
        let firstContactTypes: [AirBridgeMessageType] = [
            .hello,
            .acknowledgement,
            .ping,
            .pong,
            .pairingRequest,
            .pairingResponse
        ]

        for type in firstContactTypes {
            let requirement = AuthenticationPolicy.authenticationRequirement(
                for: type,
                protocolVersion: 2,
                peerTrustState: .unknown,
                peerPublicKeyMatches: false
            )
            XCTAssertEqual(
                requirement,
                .requiredForKnownPeer,
                "\(type) avec pair unknown doit accepter la clé annoncée"
            )
        }
    }

    /// Un pair inconnu qui tente d'envoyer un message sensible *hors*
    /// liste blanche (par exemple une demande de transfert avant tout
    /// pairage) doit se voir exiger une signature. Comme aucune clé
    /// n'est enregistrée pour ce pair, la vérification rejettera le
    /// message : c'est le comportement attendu.
    func testV2UnknownPeerOtherRequired() {
        let prePairingForbiddenTypes: [AirBridgeMessageType] = [
            .transferRequest,
            .transferAccepted,
            .transferRejected,
            .transferCompleted,
            .transferSucceeded,
            .transferFailed,
            .transferCancelled,
            .resumeRequest,
            .resumeAccepted
        ]

        for type in prePairingForbiddenTypes {
            let requirement = AuthenticationPolicy.authenticationRequirement(
                for: type,
                protocolVersion: 2,
                peerTrustState: .unknown,
                peerPublicKeyMatches: false
            )
            XCTAssertEqual(
                requirement,
                .required,
                "\(type) avec pair unknown hors liste blanche doit exiger une signature (qui sera rejetée faute de clé)"
            )
        }
    }

    // MARK: - Helper isSensitiveControlMessage

    /// Le helper isSensitiveControlMessage doit retourner true pour tous
    /// les messages de contrôle qui mutent l'état du protocole en v2, et
    /// false pour les `fileChunk` (protégés par `transferCompleted`) et
    /// `error` (pas un état protocolaire durable).
    func testIsSensitiveControlMessage() {
        // En v2 : true pour tous les messages de la liste sensible
        let sensitiveTypes: [AirBridgeMessageType] = [
            .hello,
            .acknowledgement,
            .ping,
            .pong,
            .pairingRequest,
            .pairingResponse,
            .transferRequest,
            .transferAccepted,
            .transferRejected,
            .transferCompleted,
            .transferSucceeded,
            .transferFailed,
            .transferCancelled,
            .resumeRequest,
            .resumeAccepted
        ]

        for type in sensitiveTypes {
            XCTAssertTrue(
                AuthenticationPolicy.isSensitiveControlMessage(type, protocolVersion: 2),
                "\(type) doit être sensible en v2"
            )
        }

        // En v2 : false pour fileChunk et error
        XCTAssertFalse(
            AuthenticationPolicy.isSensitiveControlMessage(.fileChunk, protocolVersion: 2),
            "fileChunk ne fait pas partie des messages sensibles (protégé par transferCompleted)"
        )
        XCTAssertFalse(
            AuthenticationPolicy.isSensitiveControlMessage(.error, protocolVersion: 2),
            "error n'est pas un état protocolaire durable"
        )

        // En v1 : tout est false (la notion de message sensible n'existe qu'en v2)
        for type in AirBridgeMessageType.allCases {
            XCTAssertFalse(
                AuthenticationPolicy.isSensitiveControlMessage(type, protocolVersion: 1),
                "En v1, aucun message n'est marqué sensible (la signature n'existait pas)"
            )
        }
    }
}

// MARK: - Helper d'introspection des types

extension AirBridgeMessageType {
    /// Liste exhaustive des cas pour itérer dessus dans les tests.
    static var allCases: [AirBridgeMessageType] {
        [
            .hello,
            .acknowledgement,
            .transferRequest,
            .transferAccepted,
            .transferRejected,
            .transferCancelled,
            .fileChunk,
            .transferCompleted,
            .transferSucceeded,
            .transferFailed,
            .resumeRequest,
            .resumeAccepted,
            .ping,
            .pong,
            .error,
            .pairingRequest,
            .pairingResponse
        ]
    }
}
