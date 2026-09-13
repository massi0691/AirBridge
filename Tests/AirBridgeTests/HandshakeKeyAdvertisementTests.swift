//
//  HandshakeKeyAdvertisementTests.swift
//  AirBridgeTests
//
//  Tests de non-régression pour le correctif « sender publie sa clé
//  long-terme dans `Device.publicKeyData` ».
//
//  Contexte du bug : avant ce correctif, `extractAdvertisedPublicKey`
//  ne trouvait la clé publique de signature que dans le payload des
//  messages `pairingRequest` / `pairingResponse`. Pour `hello` et
//  `keyExchange`, le récepteur ne pouvait donc pas vérifier la
//  signature du premier contact — d'où « Signature invalide pour
//  keyExchange » observé en Mac↔iPhone pendant l'appairage.
//
//  Le correctif ajoute `Device.publicKeyData` (optionnel pour la
//  rétro-compatibilité wire-format) et fait porter la clé long-terme
//  par chaque message sortant. `extractAdvertisedPublicKey` lit
//  désormais cette clé en priorité, avec un fallback sur le payload
//  pour les clients v1.
//
//  Les tests ci-dessous vérifient les trois scénarios critiques :
//   1. Round-trip JSON d'un `Device` avec et sans `publicKeyData`
//      (compatibilité ascendante).
//   2. Un message `hello` signé avec la clé long-terme portée par
//      `sender.publicKeyData` est vérifiable par un tiers qui n'a
//      que `sender.publicKeyData` (pas de store).
//   3. Un message `keyExchange` signé avec la clé long-terme portée
//      par `sender.publicKeyData` est vérifiable — c'est précisément
//      le scénario qui échouait avant le correctif.
//

import XCTest
import CryptoKit
@testable import AirBridge

final class HandshakeKeyAdvertisementTests: XCTestCase {

    private var peerID: UUID!
    private var peerPrivateKey: P256.Signing.PrivateKey!

    override func setUp() {
        super.setUp()
        peerID = UUID()
        peerPrivateKey = P256.Signing.PrivateKey()
    }

    override func tearDown() {
        peerID = nil
        peerPrivateKey = nil
        super.tearDown()
    }

    // MARK: - Device Codable — rétro-compatibilité wire-format

    /// Un `Device` avec `publicKeyData` doit s'encoder / décoder sans
    /// perte. Vérifie que le champ optionnel est bien porté sur le
    /// réseau.
    func testDeviceRoundTripWithPublicKeyData() throws {
        let keyData = peerPrivateKey.publicKey.x963Representation
        let original = Device(
            id: peerID,
            name: "iPhone de Massi",
            model: "iPhone",
            systemVersion: "26.5",
            publicKeyData: keyData
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(Device.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.publicKeyData, keyData)
    }

    /// Un JSON sans le champ `publicKeyData` doit être accepté (les
    /// anciens clients n'embarquent pas encore la clé). Le `Device`
    /// résultant a `publicKeyData == nil`.
    ///
    /// C'est la garantie de rétro-compatibilité : un client v1 peut
    /// toujours envoyer un `Device` à un client v2 sans casser le
    /// décodage.
    func testDeviceDecodesLegacyJSONWithoutPublicKeyData() throws {
        let legacyJSON = """
        {
            "id": "\(peerID.uuidString)",
            "name": "iPhone Legacy",
            "model": "iPhone",
            "systemVersion": "26.0"
        }
        """
            .data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            Device.self,
            from: legacyJSON
        )

        XCTAssertEqual(decoded.id, peerID)
        XCTAssertEqual(decoded.name, "iPhone Legacy")
        XCTAssertNil(
            decoded.publicKeyData,
            "Un Device legacy sans publicKeyData doit décoder en nil, " +
            "pas échouer ni tenter une valeur par défaut farfelue"
        )
    }

    /// Un `Device` avec `publicKeyData: nil` explicite doit aussi
    /// être accepté. Vérifie qu'on distingue bien « champ absent »
    /// de « champ présent à nil » (les deux doivent aboutir au même
    /// état).
    func testDeviceDecodesExplicitNullPublicKeyData() throws {
        let json = """
        {
            "id": "\(peerID.uuidString)",
            "name": "iPhone",
            "model": "iPhone",
            "systemVersion": "26.5",
            "publicKeyData": null
        }
        """
            .data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            Device.self,
            from: json
        )

        XCTAssertNil(decoded.publicKeyData)
    }

    // MARK: - Régression hello — premier contact

    /// Reproduit le scénario du bug : un `hello` arrive, signé avec
    /// la clé long-terme du pair. La clé est maintenant portée par
    /// `sender.publicKeyData`. Le récepteur peut vérifier la
    /// signature en mode `.requiredForKnownPeer` (premier contact,
    /// pas encore de store).
    ///
    /// Avant le correctif, ce cas ne pouvait pas être vérifié car
    /// `extractAdvertisedPublicKey` retournait `nil` pour `hello`.
    /// Après le correctif, la clé du sender est lue directement.
    func testHelloVerifiesViaSenderPublicKeyData() throws {
        // Sender publie sa clé long-terme dans `Device.publicKeyData`.
        let sender = Device(
            id: peerID,
            name: "Peer",
            model: "iPhone",
            systemVersion: "26.5",
            publicKeyData: peerPrivateKey.publicKey.x963Representation
        )

        let message = AirBridgeMessage(
            type: .hello,
            sender: sender,
            payload: nil
        )

        // Le peer signe son hello avec sa clé long-terme.
        let canonical = try canonicalBytesForSigning(message)
        let signature = try peerPrivateKey.signature(for: canonical)
            .rawRepresentation

        let signed = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )

        // On extrait la clé annoncée depuis `sender.publicKeyData`
        // (chemin emprunté par `extractAdvertisedPublicKey`).
        let advertised = signed.sender.publicKeyData
        XCTAssertNotNil(advertised, "sender.publicKeyData doit être renseigné")

        XCTAssertTrue(
            MessageAuthenticator.verify(
                signed,
                requirement: .requiredForKnownPeer,
                storePublicKey: nil,
                advertisedPublicKey: advertised
            ),
            "Un hello signé doit vérifier contre la clé long-terme " +
            "portée par sender.publicKeyData"
        )
    }

    // MARK: - Régression keyExchange — scénario qui échouait

    /// Reproduit précisément le bug observé en Mac↔iPhone :
    /// « Signature invalide pour keyExchange ».
    ///
    /// Avant le correctif, `extractAdvertisedPublicKey` extrayait
    /// depuis `KeyExchangePayload.publicKeyData` (la clé ECDH
    /// éphémère, 65 octets P-256 uncompressed). Le récepteur tentait
    /// alors de vérifier la signature du `keyExchange` contre une
    /// clé qui n'avait jamais signé ce message — résultat : rejet
    /// systématique.
    ///
    /// Après le correctif, la clé long-terme arrive via
    /// `sender.publicKeyData` et la vérification aboutit.
    func testKeyExchangeVerifiesViaSenderPublicKeyData() throws {
        let longTermKeyData = peerPrivateKey.publicKey.x963Representation
        let sender = Device(
            id: peerID,
            name: "Peer",
            model: "iPhone",
            systemVersion: "26.5",
            publicKeyData: longTermKeyData
        )

        // Le payload keyExchange contient une clé ECDH **éphémère**
        // (autre que la clé long-terme). Elle sert à la dérivation
        // de la clé de session, pas à la vérification de signature.
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let payload = KeyExchangePayload(
            publicKey: ephemeralKey.publicKey,
            sessionId: UUID()
        )
        let payloadData = try JSONEncoder().encode(payload)

        let message = AirBridgeMessage(
            type: .keyExchange,
            sender: sender,
            payload: payloadData
        )

        // Le peer signe le keyExchange avec sa clé **long-terme**.
        let canonical = try canonicalBytesForSigning(message)
        let signature = try peerPrivateKey.signature(for: canonical)
            .rawRepresentation

        let signed = AirBridgeMessage(
            protocolVersion: message.protocolVersion,
            messageID: message.messageID,
            type: message.type,
            sender: message.sender,
            payload: message.payload,
            signature: signature
        )

        // Le récepteur lit la clé depuis `sender.publicKeyData`
        // (clé long-terme), pas depuis le payload (clé éphémère).
        let advertised = signed.sender.publicKeyData
        XCTAssertNotNil(advertised)
        XCTAssertNotEqual(
            advertised,
            payload.publicKeyData,
            "La clé long-terme du sender ne doit PAS être confondue " +
            "avec la clé ECDH éphémère du payload"
        )

        XCTAssertTrue(
            MessageAuthenticator.verify(
                signed,
                requirement: .requiredForKnownPeer,
                storePublicKey: nil,
                advertisedPublicKey: advertised
            ),
            "Un keyExchange signé avec la clé long-terme doit " +
            "vérifier contre sender.publicKeyData"
        )

        // Et la vérification avec la clé **éphémère** du payload
        // (l'ancien comportement bogué) doit échouer, démontrant
        // pourquoi le fallback historique était cassé.
        XCTAssertFalse(
            MessageAuthenticator.verify(
                signed,
                requirement: .requiredForKnownPeer,
                storePublicKey: nil,
                advertisedPublicKey: payload.publicKeyData
            ),
            "La vérification contre la clé éphémère du payload doit " +
            "échouer : ce n'est pas la clé qui a signé le message"
        )
    }

    // MARK: - Fallback gracieux — ancien client sans publicKeyData

    /// Un sender legacy (v1) qui n'embarque pas `publicKeyData` doit
    /// pouvoir être décodé. Le récepteur tombe alors sur
    /// `extractAdvertisedPublicKey(...) == nil` et la vérification
    /// échoue proprement (pas de crash). C'est le comportement
    /// documenté avant le correctif, préservé pour la
    /// rétro-compatibilité.
    func testLegacySenderWithoutPublicKeyDataIsHandledGracefully() throws {
        let sender = Device(
            id: peerID,
            name: "Legacy Peer",
            model: "iPhone",
            systemVersion: "26.0"
        )
        XCTAssertNil(
            sender.publicKeyData,
            "Un Device construit sans publicKeyData doit l'exposer à nil"
        )

        // Message sans payload (cas hello legacy).
        let message = AirBridgeMessage(
            type: .hello,
            sender: sender,
            payload: nil,
            signature: nil
        )

        // Pas de clé annoncée, pas de signature → rejet propre, pas
        // de crash. C'est la conséquence attendue de la branche
        // `.requiredForKnownPeer` quand `advertisedPublicKey == nil`.
        XCTAssertFalse(
            MessageAuthenticator.verify(
                message,
                requirement: .requiredForKnownPeer,
                storePublicKey: nil,
                advertisedPublicKey: nil
            ),
            "Un hello legacy non signé sans clé annoncée doit être " +
            "rejeté (pas de crash)"
        )
    }

    // MARK: - Helper

    /// Réplique les octets canoniques produits par
    /// `MessageAuthenticator.canonicalBytes(for:)`. Répliqué ici pour
    /// permettre la signature de test avec une clé privée tierce.
    private func canonicalBytesForSigning(
        _ message: AirBridgeMessage
    ) throws -> Data {
        struct SignedFields: Encodable {
            let type: String
            let messageID: String
            let payload: String?
        }
        let fields = SignedFields(
            type: message.type.rawValue,
            messageID: message.messageID.uuidString,
            payload: message.payload?.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fields)
    }
}
