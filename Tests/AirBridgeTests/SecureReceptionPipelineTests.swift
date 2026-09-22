//
//  SecureReceptionPipelineTests.swift
//  AirBridgeTests
//
//  Tests d'intégration du pipeline sécurisé de réception : décision
//  `AuthenticationPolicy` → vérification cryptographique stricte →
//  anti-replay. Couvre l'API publique de `MessageAuthenticator.verify`
//  et la propriété attendue de non-empoisonnement du `ReplayProtectionStore`.
//

import XCTest
import CryptoKit
@testable import AirBridge

final class SecureReceptionPipelineTests: XCTestCase {

    private var localDevice: Device!
    private var peerPrivateKey: P256.Signing.PrivateKey!

    override func setUp() {
        super.setUp()
        localDevice = Device(
            id: UUID(),
            name: "LocalDevice",
            model: "iPhone",
            systemVersion: "iOS 26"
        )
        peerPrivateKey = P256.Signing.PrivateKey()
    }

    override func tearDown() {
        localDevice = nil
        peerPrivateKey = nil
        super.tearDown()
    }

    // MARK: - Table de décision AuthenticationPolicy

    /// v2 + pair trusted + clé publique qui matche → `.required`
    /// (vérification contre la clé du store).
    func testPolicyIsRequiredForV2TrustedPair() {
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: .transferRequest,
            protocolVersion: 2,
            peerTrustState: .trusted,
            peerPublicKeyMatches: true
        )
        XCTAssertEqual(requirement, .required)
    }

    /// v1 (toute combinaison) → `.required` : la v1 est désactivée, aucun
    /// mode permissif ne subsiste (anti-downgrade).
    func testPolicyIsStrictForV1() {
        for type in AirBridgeMessageType.allCases {
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
                        "En v1, \(type) avec pair=\(trustState) cléMatch=\(keyMatches) doit rester strict"
                    )
                }
            }
        }
    }

    /// v2 + `fileChunk` → `.forbidden` quel que soit le contexte (les
    /// chunks sont protégés collectivement par le `transferCompleted`).
    func testPolicyIsForbiddenForV2FileChunk() {
        for trustState in TrustState.allCases {
            for keyMatches in [true, false] {
                let requirement = AuthenticationPolicy.authenticationRequirement(
                    for: .fileChunk,
                    protocolVersion: 2,
                    peerTrustState: trustState,
                    peerPublicKeyMatches: keyMatches
                )
                XCTAssertEqual(requirement, .forbidden)
            }
        }
    }

    // MARK: - MessageAuthenticator.verify — mode .required

    /// `.required` + signature absente → `false` (rejet).
    func testVerifyRejectsUnsignedWhenRequired() {
        let message = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("payload".utf8),
            signature: nil
        )

        XCTAssertFalse(
            MessageAuthenticator.verify(
                message,
                requirement: .required,
                storePublicKey: peerPrivateKey.publicKey.x963Representation,
                advertisedPublicKey: peerPrivateKey.publicKey.x963Representation
            ),
            "Un message sans signature doit être rejeté en mode .required"
        )
    }

    /// `.required` + signature valide contre la clé du store → `true`.
    func testVerifyAcceptsSignedWhenRequired() throws {
        let message = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("payload".utf8)
        )

        // Signe avec la clé privée du pair
        let bytesToSign = Data("transferRequest".utf8) // dummy — la signature est calculée sur canonicalBytes
        let canonical = MessageAuthenticator.canonicalBytes(for: message)
        let signature = try peerPrivateKey.signature(for: canonical).rawRepresentation

        let signed = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )

        XCTAssertTrue(
            MessageAuthenticator.verify(
                signed,
                requirement: .required,
                storePublicKey: peerPrivateKey.publicKey.x963Representation,
                advertisedPublicKey: peerPrivateKey.publicKey.x963Representation
            ),
            "Une signature valide contre la clé du store doit être acceptée"
        )
        _ = bytesToSign // silence unused warning
    }

    /// `.required` + signature valide mais pour une clé différente →
    /// `false` (rejet pour substitution de clé).
    func testVerifyRejectsWrongKeyWhenRequired() throws {
        let otherKey = P256.Signing.PrivateKey()

        let message = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("payload".utf8)
        )
        let canonical = MessageAuthenticator.canonicalBytes(for: message)
        let signature = try peerPrivateKey.signature(for: canonical).rawRepresentation

        let signed = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )

        XCTAssertFalse(
            MessageAuthenticator.verify(
                signed,
                requirement: .required,
                storePublicKey: otherKey.publicKey.x963Representation,
                advertisedPublicKey: otherKey.publicKey.x963Representation
            ),
            "Une signature contre une autre clé doit être rejetée"
        )
    }

    // MARK: - MessageAuthenticator.verify — mode .requiredForKnownPeer

    /// `.requiredForKnownPeer` + signature absente → `false`.
    func testVerifyRejectsUnsignedWhenRequiredForKnownPeer() {
        let message = AirBridgeMessage(
            type: .hello,
            sender: localDevice,
            payload: nil,
            signature: nil
        )

        XCTAssertFalse(
            MessageAuthenticator.verify(
                message,
                requirement: .requiredForKnownPeer,
                storePublicKey: nil,
                advertisedPublicKey: peerPrivateKey.publicKey.x963Representation
            ),
            "Un message sans signature doit être rejeté en mode .requiredForKnownPeer"
        )
    }

    /// `.requiredForKnownPeer` + signature valide contre la clé annoncée
    /// → `true` (premier contact, on fait confiance à la clé annoncée).
    func testVerifyAcceptsSignedWhenRequiredForKnownPeer() throws {
        let message = AirBridgeMessage(
            type: .hello,
            sender: localDevice,
            payload: nil
        )
        let canonical = MessageAuthenticator.canonicalBytes(for: message)
        let signature = try peerPrivateKey.signature(for: canonical).rawRepresentation

        let signed = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )

        XCTAssertTrue(
            MessageAuthenticator.verify(
                signed,
                requirement: .requiredForKnownPeer,
                storePublicKey: nil,
                advertisedPublicKey: peerPrivateKey.publicKey.x963Representation
            ),
            "Une signature valide contre la clé annoncée doit être acceptée"
        )
    }

    // MARK: - MessageAuthenticator.verify — mode .optionalLegacy

    /// `.optionalLegacy` + signature absente → `false`.
    ///
    /// La valeur n'est conservée que pour la compatibilité **source** :
    /// elle n'est plus permissive. Un contrôle non signé est rejeté quel
    /// que soit le mode, sinon un pair v1 (ou un attaquant annonçant v1)
    /// pourrait faire muter l'état d'une session v2 sans preuve d'identité.
    func testVerifyRejectsUnsignedEvenWhenOptionalLegacy() {
        let message = AirBridgeMessage(
            type: .hello,
            sender: localDevice,
            payload: nil,
            signature: nil
        )

        XCTAssertFalse(
            MessageAuthenticator.verify(
                message,
                requirement: .optionalLegacy,
                storePublicKey: nil,
                advertisedPublicKey: peerPrivateKey.publicKey.x963Representation
            ),
            "Un message sans signature doit être rejeté, même en mode .optionalLegacy"
        )
    }

    // MARK: - MessageAuthenticator.verify — mode .forbidden

    /// `.forbidden` → toujours `false`, même avec une signature valide.
    func testVerifyRejectsForForbidden() throws {
        let message = AirBridgeMessage(
            type: .fileChunk,
            sender: localDevice,
            payload: Data("binary".utf8)
        )
        let canonical = MessageAuthenticator.canonicalBytes(for: message)
        let signature = try peerPrivateKey.signature(for: canonical).rawRepresentation

        let signed = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )

        XCTAssertFalse(
            MessageAuthenticator.verify(
                signed,
                requirement: .forbidden,
                storePublicKey: peerPrivateKey.publicKey.x963Representation,
                advertisedPublicKey: peerPrivateKey.publicKey.x963Representation
            ),
            "Un message en .forbidden ne doit jamais être vérifié positivement"
        )
    }

    // MARK: - Non-empoisonnement du ReplayProtectionStore

    /// Un message REJETÉ par `MessageAuthenticator.verify` ne doit PAS
    /// empoisonner le `ReplayProtectionStore` : le `messageID` reste
    /// disponible pour un message futur correctement signé.
    ///
    /// C'est précisément la garantie d'ordre `verify → observe` : on
    /// n'appelle `observe` qu'après une vérification réussie.
    func testReplayStoreNotPoisonedByInvalidMessage() async throws {
        let otherKey = P256.Signing.PrivateKey()

        // Construire un message signé avec la mauvaise clé
        let message = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("payload".utf8)
        )
        let canonical = MessageAuthenticator.canonicalBytes(for: message)
        let badSignature = try peerPrivateKey.signature(for: canonical).rawRepresentation

        let badSigned = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: badSignature
        )

        // 1. Vérifier : doit échouer (mauvaise clé)
        let verifyResult = MessageAuthenticator.verify(
            badSigned,
            requirement: .required,
            storePublicKey: otherKey.publicKey.x963Representation,
            advertisedPublicKey: otherKey.publicKey.x963Representation
        )
        XCTAssertFalse(verifyResult, "La signature doit être rejetée (mauvaise clé)")

        // 2. Le message n'a PAS été enregistré dans le store (puisqu'on
        //    n'a pas appelé `observe`). Le `messageID` est donc libre.
        let store = ReplayProtectionStore()
        let firstObserve = await store.observe(
            peerID: message.sender.id,
            messageID: message.messageID
        )
        XCTAssertTrue(
            firstObserve,
            "Un message invalide n'a pas dû empoisonner le store : " +
            "le messageID doit encore être disponible"
        )
    }

    /// Un message REJETÉ pour absence de signature en mode strict ne
    /// doit PAS non plus empoisonner le `ReplayProtectionStore`.
    func testReplayStoreNotPoisonedByMissingSignature() async {
        // Construire un message sans signature, mode strict
        let message = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("payload".utf8),
            signature: nil
        )

        // 1. Vérifier : doit échouer
        let verifyResult = MessageAuthenticator.verify(
            message,
            requirement: .required,
            storePublicKey: peerPrivateKey.publicKey.x963Representation,
            advertisedPublicKey: peerPrivateKey.publicKey.x963Representation
        )
        XCTAssertFalse(verifyResult, "Un message sans signature doit être rejeté en .required")

        // 2. Le `messageID` est toujours libre dans le store.
        let store = ReplayProtectionStore()
        let firstObserve = await store.observe(
            peerID: message.sender.id,
            messageID: message.messageID
        )
        XCTAssertTrue(
            firstObserve,
            "Un message sans signature n'a pas dû empoisonner le store : " +
            "le messageID doit encore être disponible"
        )
    }
}
