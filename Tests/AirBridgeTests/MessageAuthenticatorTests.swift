import XCTest
import CryptoKit
@testable import AirBridge

final class MessageAuthenticatorTests: XCTestCase {

    private var localDevice: Device!

    override func setUp() {
        super.setUp()
        localDevice = Device(
            id: UUID(),
            name: "TestLocal",
            model: "iPhone",
            systemVersion: "iOS 26"
        )
    }

    override func tearDown() {
        localDevice = nil
        super.tearDown()
    }

    // MARK: - Politique d'authentification

    /// Vérifie qu'un message sans signature est REJETÉ, y compris quand
    /// l'appelant passe `.optionalLegacy`.
    ///
    /// Note politique : `.optionalLegacy` n'est conservé que pour la
    /// compatibilité source d'anciens appelants. La v1 est désactivée
    /// (`ProtocolCompatibility.minimumSupportedVersion == 2`) et aucun
    /// mode permissif ne subsiste : un contrôle non signé ne peut pas
    /// muter l'état d'une session.
    func testUnsignedMessageIsRejectedEvenInLegacyMode() {
        let message = AirBridgeMessage(
            type: .hello,
            sender: localDevice,
            payload: nil,
            signature: nil
        )

        let anyKey = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertFalse(
            MessageAuthenticator.verify(
                message,
                requirement: .optionalLegacy,
                storePublicKey: nil,
                advertisedPublicKey: anyKey
            ),
            "Un message sans signature doit être rejeté, même en mode .optionalLegacy"
        )
    }

    /// Vérifie qu'un message sans signature est REJETÉ en mode strict
    /// `.required`. C'est le nouveau comportement par défaut.
    ///
    /// Note politique : la Phase C impose qu'un message soumis à une
    /// politique `.required` (cas de tous les messages de contrôle
    /// sensibles en v2) porte une signature valide. Sans signature,
    /// le message est rejeté.
    func testUnsignedMessageIsRejectedInRequiredMode() {
        let message = AirBridgeMessage(
            type: .hello,
            sender: localDevice,
            payload: nil,
            signature: nil
        )

        let anyKey = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertFalse(
            MessageAuthenticator.verify(
                message,
                requirement: .required,
                storePublicKey: nil,
                advertisedPublicKey: anyKey
            ),
            "Un message sans signature doit être rejeté en mode .required"
        )
    }

    /// Vérifie qu'un message signé avec la bonne clé est accepté
    /// en mode `.required`.
    func testSignedMessageVerifiesAgainstItsKey() throws {
        let identity = try SecureIdentityStore.ensureIdentity()

        let message = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("hello".utf8)
        )

        guard let signature = MessageAuthenticator.sign(message) else {
            XCTFail("La signature aurait dû être produite")
            return
        }

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
                storePublicKey: identity.publicKeyData,
                advertisedPublicKey: identity.publicKeyData
            ),
            "Le message doit être vérifié contre la clé publique de l'émetteur"
        )
    }

    /// Vérifie qu'un message signé avec une clé différente est rejeté
    /// en mode `.required`.
    func testSignedMessageFailsAgainstWrongKey() throws {
        _ = try SecureIdentityStore.ensureIdentity()
        let otherKey = P256.Signing.PrivateKey().publicKey.x963Representation

        let message = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("payload".utf8)
        )

        guard let signature = MessageAuthenticator.sign(message) else {
            XCTFail("La signature aurait dû être produite")
            return
        }

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
                storePublicKey: otherKey,
                advertisedPublicKey: otherKey
            ),
            "Une signature doit échouer contre une clé publique différente"
        )
    }

    /// Vérifie qu'un message modifié après signature ne vérifie plus
    /// en mode `.required`.
    func testTamperedMessageFailsVerification() throws {
        let identity = try SecureIdentityStore.ensureIdentity()

        let original = AirBridgeMessage(
            type: .transferRequest,
            sender: localDevice,
            payload: Data("original".utf8)
        )

        guard let signature = MessageAuthenticator.sign(original) else {
            XCTFail("La signature aurait dû être produite")
            return
        }

        // Modifier le payload après signature : la vérification doit échouer.
        let tampered = AirBridgeMessage(
            protocolVersion: original.protocolVersion,
            messageID: original.messageID,
            type: original.type,
            sender: original.sender,
            payload: Data("tampered".utf8),
            signature: signature
        )

        XCTAssertFalse(
            MessageAuthenticator.verify(
                tampered,
                requirement: .required,
                storePublicKey: identity.publicKeyData,
                advertisedPublicKey: identity.publicKeyData
            ),
            "Un message modifié après signature doit être rejeté"
        )
    }
}
