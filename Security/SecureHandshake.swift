//
//  SecureHandshake.swift
//  AirBridge
//
//  Created by massi9106 on 27/08/2026.
//
//  Handshake de sécurité : Diffie-Hellman sur courbe P-256, dérivation
//  HKDF-SHA256 d'une clé symétrique 256 bits liée à l'identifiant de
//  session. Le résultat est installé dans les deux gestionnaires
//  (`OutgoingTransferManager`, `IncomingTransferManager`) via
//  `ChunkStreamCipher`, qui applique ensuite ChaCha20-Poly1305 à chaque
//  chunk binaire v2.
//
//  Format du payload `KeyExchangePayload` : clé publique P-256 brute
//  (65 octets, format `0x04 || X || Y`). Aucun nonce ni signature ici :
//  la signature de bout en bout est portée par l'`AirBridgeMessage`
//  parent (Ed25519 / ECDSA P-256 selon la politique d'authentification
//  en vigueur), donc un attaquant ne peut pas réécrire la clé publique
//  sans invalider la signature.
//

import Foundation
import CryptoKit

/// Erreurs du handshake de sécurité.
enum SecureHandshakeError: Error, CustomStringConvertible {
    case publicKeyDecodeFailed
    case sharedSecretDerivationFailed
    case symmetricKeyDerivationFailed

    var description: String {
        switch self {
        case .publicKeyDecodeFailed:
            return "Impossible de décoder la clé publique du pair"
        case .sharedSecretDerivationFailed:
            return "Échec du calcul du secret partagé ECDH"
        case .symmetricKeyDerivationFailed:
            return "Échec de la dérivation HKDF de la clé de session"
        }
    }
}

/// Payload de l'échange de clés.
///
/// Transporte uniquement la clé publique éphémère P-256 (65 octets, format
/// uncompressed `0x04 || X || Y`). Le `sessionId` est lié par la couche
/// `AirBridgeMessage` (id du message côté émetteur) plutôt que par le
/// payload.
struct KeyExchangePayload: Codable, Sendable {
    let publicKeyData: Data
    let sessionId: UUID

    init(publicKey: P256.KeyAgreement.PublicKey, sessionId: UUID) {
        self.publicKeyData = publicKey.rawRepresentation
        self.sessionId = sessionId
    }
}

/// Réalise un handshake ECDH P-256 ponctuel et dérive la clé symétrique
/// 256 bits qui servira au chiffrement des chunks (`ChunkStreamCipher`).
///
/// L'instance n'a pas d'état partagé au-delà de la clé privée éphémère
/// générée à l'initialisation : chaque appel à `deriveSessionKey(from:)`
/// est indépendant et stateless côté public (la clé privée reste interne).
struct SecureHandshake: Sendable {

    /// Clé privée éphémère générée à l'initialisation.
    private let privateKey: P256.KeyAgreement.PrivateKey

    init() {
        self.privateKey = P256.KeyAgreement.PrivateKey()
    }

    /// Clé publique à transmettre au pair (65 octets, format uncompressed).
    var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    /// Clé publique au format `P256.KeyAgreement.PublicKey` utilisable
    /// directement par `KeyExchangePayload`.
    var publicKey: P256.KeyAgreement.PublicKey {
        privateKey.publicKey
    }

    /// Dérive la clé symétrique de session à partir de la clé publique
    /// éphémère du pair.
    ///
    /// La dérivation utilise HKDF-SHA256 avec :
    ///   - sel = `sessionId` (16 octets du UUID)
    ///   - info = `"airbridge-v2-session"` (ASCII, 20 octets)
    ///   - longueur de sortie = 32 octets (256 bits)
    ///
    /// Lier la clé au `sessionId` empêche un attaquant qui aurait rejoué
    /// la clé publique du pair dans une autre session de retrouver la
    /// même clé symétrique : chaque session possède son propre sel.
    func deriveSessionKey(
        from peerPublicKeyData: Data,
        sessionId: UUID
    ) throws -> SymmetricKey {
        let peerKey: P256.KeyAgreement.PublicKey
        do {
            peerKey = try P256.KeyAgreement.PublicKey(
                rawRepresentation: peerPublicKeyData
            )
        } catch {
            throw SecureHandshakeError.publicKeyDecodeFailed
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
                with: peerKey
            )
        } catch {
            throw SecureHandshakeError.sharedSecretDerivationFailed
        }

        let salt = withUnsafeBytes(of: sessionId.uuid) { Data($0) }
        let sharedInfo = Data("airbridge-v2-session".utf8)

        let symmetricKey: SymmetricKey
        do {
            symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: sharedInfo,
                outputByteCount: 32
            )
        } catch {
            throw SecureHandshakeError.symmetricKeyDerivationFailed
        }

        return symmetricKey
    }
}
