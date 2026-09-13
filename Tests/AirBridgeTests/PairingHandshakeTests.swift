import XCTest
import CryptoKit
@testable import AirBridge

/// Tests d'intégration du handshake de pairage complet (initiation +
/// challenge + vérification cryptographique + enregistrement).
///
/// Ces tests n'exercent pas la couche réseau : ils passent directement
/// par `PairingHandshake` pour vérifier la logique de bout en bout, ce
/// qui isole les régressions cryptographiques des régressions de transport.
final class PairingHandshakeTests: XCTestCase {

    private var handshake: PairingHandshake!
    private var store: PairingStore!

    override func setUp() {
        super.setUp()
        store = PairingStore()
        handshake = PairingHandshake(pairingStore: store)
        clearUserDefaults()
    }

    override func tearDown() {
        clearUserDefaults()
        handshake = nil
        store = nil
        super.tearDown()
    }

    /// Cycle nominal : A envoie un challenge, B le signe et renvoie sa clé
    /// publique, A vérifie et enregistre B comme pair en attente.
    func testFullHandshakeRoundTrip() throws {
        let identityA = try SecureIdentityStore.ensureIdentity()
        _ = identityA // l'identité locale est implicite via SecureIdentityStore

        // Côté A : on génère un challenge et on le transmet à B.
        let challengeA = PairingHandshake.generateChallenge()
        XCTAssertEqual(challengeA.count, 32, "Le challenge doit faire 32 octets")

        // Côté B : B signe le challenge avec sa propre clé privée et
        // construit le payload de réponse.
        let keyB = P256.Signing.PrivateKey()
        let signatureB = try keyB.signature(for: challengeA).rawRepresentation

        let responsePayload = PairingPayload(
            peerID: UUID(),
            peerName: "B",
            publicKeyData: keyB.publicKey.x963Representation,
            challenge: challengeA,
            signature: signatureB,
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        // Côté A : A vérifie le payload reçu.
        let result = handshake.verifyPairingPayload(
            responsePayload,
            expectedChallenge: challengeA
        )

        switch result {
        case .success(let info):
            XCTAssertEqual(info.peerName, "B")
            XCTAssertEqual(info.peerPublicKeyData, keyB.publicKey.x963Representation)
            XCTAssertEqual(info.trustState, .pending, "Un pair nouvellement vérifié reste en attente de confirmation utilisateur")

        default:
            XCTFail("La vérification du payload de pairage aurait dû réussir, a retourné : \(result)")
        }
    }

    /// Une signature forgée (mauvaise clé privée) doit être rejetée.
    func testHandshakeRejectsForgedSignature() throws {
        let challengeA = PairingHandshake.generateChallenge()

        // B signe avec sa bonne clé…
        let keyB = P256.Signing.PrivateKey()
        let realSignature = try keyB.signature(for: challengeA).rawRepresentation

        // …mais un attaquant forge un payload avec une AUTRE clé privée
        // et la signature légitime : sans la clé privée de B, il ne peut
        // pas signer correctement le challenge.
        let attackerKey = P256.Signing.PrivateKey()
        let bogusPayload = PairingPayload(
            peerID: UUID(),
            peerName: "Imposteur",
            publicKeyData: attackerKey.publicKey.x963Representation,
            challenge: challengeA,
            signature: realSignature, // signée avec B, mais la clé publique est celle de l'attaquant
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        let result = handshake.verifyPairingPayload(
            bogusPayload,
            expectedChallenge: challengeA
        )

        switch result {
        case .success:
            XCTFail("Une signature incohérente avec la clé publique annoncée doit être rejetée")
        default:
            // OK : le résultat n'est pas un succès, la falsification est détectée.
            break
        }
    }

    /// Un challenge incorrect (réponse à un autre challenge) est détecté.
    func testHandshakeDetectsChallengeMismatch() throws {
        let keyB = P256.Signing.PrivateKey()
        let originalChallenge = PairingHandshake.generateChallenge()
        let otherChallenge = PairingHandshake.generateChallenge()
        XCTAssertNotEqual(originalChallenge, otherChallenge)

        // B signe l'autre challenge par erreur (ou un attaquant rejoue).
        let signature = try keyB.signature(for: otherChallenge).rawRepresentation
        let payload = PairingPayload(
            peerID: UUID(),
            peerName: "B",
            publicKeyData: keyB.publicKey.x963Representation,
            challenge: otherChallenge,
            signature: signature,
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        let result = handshake.verifyPairingPayload(
            payload,
            expectedChallenge: originalChallenge
        )
        if case .success = result {
            XCTFail("Un challenge incorrect ne doit pas mener à un succès")
        }
    }

    /// Une version de protocole non supportée est refusée.
    func testHandshakeRejectsUnsupportedProtocolVersion() {
        let keyB = P256.Signing.PrivateKey()
        let challenge = PairingHandshake.generateChallenge()
        let signature = (try? keyB.signature(for: challenge).rawRepresentation) ?? Data()

        let payload = PairingPayload(
            peerID: UUID(),
            peerName: "B",
            publicKeyData: keyB.publicKey.x963Representation,
            challenge: challenge,
            signature: signature,
            protocolVersion: 99
        )

        let result = handshake.verifyPairingPayload(
            payload,
            expectedChallenge: challenge
        )
        if case .success = result {
            XCTFail("Une version de protocole non supportée ne doit pas être acceptée")
        }
    }

    /// La détection d'auto-pairage : si le pair nous renvoie notre propre
    /// clé publique, le handshake est refusé.
    func testHandshakeDetectsSelfPairing() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let challenge = PairingHandshake.generateChallenge()
        let signature = try SecureIdentityStore.sign(challenge)

        let payload = PairingPayload(
            peerID: UUID(),
            peerName: "Moi-même",
            publicKeyData: identity.publicKeyData,
            challenge: challenge,
            signature: signature,
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        let result = handshake.verifyPairingPayload(
            payload,
            expectedChallenge: challenge
        )
        if case .success = result {
            XCTFail("Un auto-pairage doit être refusé")
        }
    }

    /// Le store doit être cohérent après un pairage réussi : le pair est
    /// consultable via `pairing(for:)`.
    func testSuccessfulHandshakePersistsPairing() throws {
        let keyB = P256.Signing.PrivateKey()
        let peerID = UUID()
        let challenge = PairingHandshake.generateChallenge()
        let signature = try keyB.signature(for: challenge).rawRepresentation

        let payload = PairingPayload(
            peerID: peerID,
            peerName: "iPhone de Test",
            publicKeyData: keyB.publicKey.x963Representation,
            challenge: challenge,
            signature: signature,
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        let result = handshake.verifyPairingPayload(
            payload,
            expectedChallenge: challenge
        )

        guard case .success(let info) = result else {
            XCTFail("La vérification aurait dû réussir")
            return
        }

        XCTAssertEqual(info.peerID, peerID)
        XCTAssertEqual(info.peerName, "iPhone de Test")
        XCTAssertEqual(info.trustState, .pending)

        // Le pair est désormais connu du store comme en attente.
        let reloaded = store.pairing(for: peerID)
        XCTAssertNotNil(reloaded, "Le pair doit être persisté après un handshake réussi")
        XCTAssertEqual(reloaded?.peerFingerprint, info.peerFingerprint)
    }

    // MARK: - Helpers

    /// Vérifie la canonicalisation : signer un message avec la clé privée
    /// locale puis le vérifier avec la clé publique locale doit réussir.
    /// Toute modification d'un champ couvert par la signature (type,
    /// messageID, payload) doit invalider la signature.
    ///
    /// Ce test protège contre les régressions de la canonicalisation :
    /// par exemple, un retour à `withUnsafeBytes(of: messageID.uuid)` ne
    /// produirait pas le même hash entre iOS et macOS (padding interne
    /// du tuple `uuid_t` non portable). L'encodage actuel via
    /// `JSONEncoder` + `.sortedKeys` sur un struct `SignedMessageFields`
    /// dédié garantit un ordre de clés déterministe et un format
    /// indépendant de la plateforme.
    func testCanonicalBytesAreDeterministic() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let message = AirBridgeMessage(
            type: .hello,
            sender: Device(
                id: UUID(),
                name: "TestDevice",
                model: "iPhone",
                systemVersion: "iOS 26"
            ),
            payload: Data("test payload".utf8)
        )

        guard let signature = MessageAuthenticator.sign(message) else {
            XCTFail("La signature aurait dû être produite")
            return
        }

        // Reconstruire le message signé pour la vérification
        let signed = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )

        // Vérifier que la signature est valide avec la clé publique de l'émetteur
        XCTAssertTrue(
            MessageAuthenticator.verify(
                signed,
                requirement: .required,
                storePublicKey: identity.publicKeyData,
                advertisedPublicKey: identity.publicKeyData
            ),
            "Un message signé avec notre clé doit être vérifiable par notre clé"
        )

        // Modifier le payload doit invalider la signature
        let tampered = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: Data("autre payload".utf8),
            signature: signature
        )
        XCTAssertFalse(
            MessageAuthenticator.verify(
                tampered,
                requirement: .required,
                storePublicKey: identity.publicKeyData,
                advertisedPublicKey: identity.publicKeyData
            ),
            "Un payload modifié après signature doit être rejeté"
        )

        // Modifier le messageID doit aussi invalider
        let tamperedID = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: UUID(),
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )
        XCTAssertFalse(
            MessageAuthenticator.verify(
                tamperedID,
                requirement: .required,
                storePublicKey: identity.publicKeyData,
                advertisedPublicKey: identity.publicKeyData
            ),
            "Un messageID modifié après signature doit être rejeté"
        )

        // Modifier le type doit aussi invalider
        let tamperedType = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: .error,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )
        XCTAssertFalse(
            MessageAuthenticator.verify(
                tamperedType,
                requirement: .required,
                storePublicKey: identity.publicKeyData,
                advertisedPublicKey: identity.publicKeyData
            ),
            "Un type modifié après signature doit être rejeté"
        )
    }

    // MARK: - Helpers

    private func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "airbridge.pairings.v1")
    }
}
