//
//  AuthenticationPolicyTests.swift
//  AirBridgeTests
//

import XCTest
@testable import AirBridge

final class AuthenticationPolicyTests: XCTestCase {

    // MARK: - Compatibilité v1

    /// La v1 est définitivement désactivée (`ProtocolCompatibility.
    /// minimumSupportedVersion == 2`) : un message annonçant une version
    /// antérieure ne bénéficie d'aucun mode permissif. La politique exige
    /// une signature qu'aucun pair v1 ne peut fournir, ce qui revient à un
    /// refus — et empêche un downgrade silencieux depuis une session v2.
    func testV1IsNeverPermissive() {
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
                        .required,
                        "En v1, \(type) avec pair=\(trustState) cléMatch=\(keyMatches) doit rester strict (aucun mode permissif)"
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

    /// Un pair explicitement bloqué ne fait plus progresser aucune session :
    /// la politique renvoie `.forbidden`, que la signature soit valide ou
    /// non. C'est plus strict que `.required` — le message n'est même pas
    /// vérifié.
    func testV2BlockedPeerForbidden() {
        for keyMatches in [true, false] {
            let requirement = AuthenticationPolicy.authenticationRequirement(
                for: .transferRequest,
                protocolVersion: 2,
                peerTrustState: .blocked,
                peerPublicKeyMatches: keyMatches
            )
            XCTAssertEqual(requirement, .forbidden)
        }
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

    /// Un pair inconnu **peut** annoncer un transfert : `transferRequest`
    /// figure dans la liste blanche du premier contact, la signature est
    /// vérifiée contre la clé annoncée puis la confirmation utilisateur
    /// décide. En revanche sa réponse (`transferAccepted`) exige une clé
    /// déjà enregistrée — d'où la barrière de pairage côté émetteur
    /// (`AirBridgeCore.sendApprovalRequestIfNeeded`), sans laquelle
    /// l'acceptation du destinataire était écartée et l'envoi restait
    /// « En attente ».
    func testV2UnknownPeerCanRequestButNotAcceptTransfer() {
        XCTAssertEqual(
            AuthenticationPolicy.authenticationRequirement(
                for: .transferRequest,
                protocolVersion: 2,
                peerTrustState: .unknown,
                peerPublicKeyMatches: false
            ),
            .requiredForKnownPeer,
            "Une annonce de transfert d'un pair inconnu s'appuie sur la clé annoncée"
        )

        XCTAssertEqual(
            AuthenticationPolicy.authenticationRequirement(
                for: .transferAccepted,
                protocolVersion: 2,
                peerTrustState: .unknown,
                peerPublicKeyMatches: false
            ),
            .required,
            "L'acceptation d'un pair inconnu exige une clé persistée (donc rejetée)"
        )
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
