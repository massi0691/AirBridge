//
//  MessageAuthenticator.swift
//  AirBridge
//
//  Created by massi9106 on 26/08/2026.
//

import Foundation
import CryptoKit

/// Authentification cryptographique des messages de contrôle.
///
/// Les messages de contrôle (`hello`, `transferRequest`, `pairingRequest`,
/// etc.) sont signés avec la clé privée locale. Le récepteur vérifie la
/// signature avec la clé publique annoncée dans `sender`. Cela empêche
/// un attaquant de rejouer ou de falsifier des messages au nom d'un pair
/// de confiance.
///
/// Les chunks de fichier (`fileChunk`) ne sont PAS signés ici : ils
/// seraient signés un par un, ce qui coûte cher. La chaîne est protégée
/// par un `transferCompleted` signé à la fin du transfert.
enum MessageAuthenticator {

    /// Signe un message avec la clé privée locale.
    /// - Returns: Signature ECDSA P-256 au format IEEE P1363
    ///   (`ECDSASignature.rawRepresentation`, 64 octets), ou `nil` si
    ///   l'identité locale est indisponible.
    static func sign(_ message: AirBridgeMessage) -> Data? {
        let bytesToSign = canonicalBytes(for: message)
        return try? SecureIdentityStore.sign(bytesToSign)
    }

    /// Vérifie la signature d'un message en appliquant une politique
    /// d'authentification stricte.
    ///
    /// Cette méthode est le point d'entrée **unique** de la vérification
    /// de signature dans la chaîne de réception. Elle consulte la
    /// `AuthenticationRequirement` fournie par `AuthenticationPolicy` et
    /// choisit la clé publique à utiliser :
    ///
    /// - `.forbidden` : toujours `false` (un `fileChunk` v2 ne doit jamais
    ///   transiter ici).
    /// - `.optionalLegacy` : mode permissif v1, message non signé accepté
    ///   ; si une signature est présente, elle est vérifiée contre la
    ///   clé publique **annoncée** (en v1 la clé du pair n'est pas fiable
    ///   car non encore échangée de manière authentifiée).
    /// - `.required` : la signature doit être présente et valide contre
    ///   la clé publique du `PairingStore` si elle existe (priorité à la
    ///   clé de confiance persistée), sinon contre la clé publique
    ///   annoncée. **Aucune exception** : sans signature valide, le
    ///   message est rejeté.
    /// - `.requiredForKnownPeer` : la signature doit être présente et
    ///   valide contre la clé publique **annoncée** (cas du tout premier
    ///   contact, où le pair n'a pas encore été persisté).
    ///
    /// - Parameters:
    ///   - message: Message reçu.
    ///   - requirement: Niveau d'authentification décidé par
    ///     `AuthenticationPolicy`.
    ///   - storePublicKey: Clé publique persistée dans le `PairingStore`
    ///     pour ce pair, ou `nil` si le pair n'est pas encore connu.
    ///   - advertisedPublicKey: Clé publique annoncée dans le message
    ///     (par exemple via le payload d'un `pairingRequest`). `nil` si
    ///     la clé n'est pas disponible dans le message courant (limitation
    ///     connue tant que `Device.publicKeyData` n'existe pas).
    /// - Returns: `true` si le message passe le niveau d'authentification
    ///   requis, `false` sinon.
    static func verify(
        _ message: AirBridgeMessage,
        requirement: AuthenticationRequirement,
        storePublicKey: Data?,
        advertisedPublicKey: Data?
    ) -> Bool {
        switch requirement {
        case .forbidden:
            // Cas terminal : ce type de message ne doit jamais transiter.
            return false

        case .optionalLegacy:
            // Mode permissif v1 : message non signé accepté. Si une
            // signature est présente, on la vérifie contre la clé
            // publique *annoncée* (en v1 le store n'est pas fiable).
            guard let signature = message.signature else {
                return true
            }
            // Sans clé annoncée, on ne peut pas vérifier : rejet.
            guard let advertisedKey = advertisedPublicKey else {
                return false
            }
            let bytesToVerify = canonicalBytes(for: message)
            return SecureIdentityStore.verifySignature(
                signature,
                for: bytesToVerify,
                publicKeyData: advertisedKey
            )

        case .required:
            // Obligation stricte : la signature DOIT être présente et
            // valide. La clé du store est privilégiée : si elle existe,
            // elle fait foi (et toute signature faite avec une clé
            // différente — cas de la substitution d'identité — échoue).
            guard let signature = message.signature else {
                return false
            }
            // La clé du store prime sur la clé annoncée. Si aucune des
            // deux n'est disponible, le message ne peut pas être vérifié
            // et est rejeté.
            guard let keyToCheck = storePublicKey ?? advertisedPublicKey else {
                return false
            }
            let bytesToVerify = canonicalBytes(for: message)
            return SecureIdentityStore.verifySignature(
                signature,
                for: bytesToVerify,
                publicKeyData: keyToCheck
            )

        case .requiredForKnownPeer:
            // Premier contact : on fait confiance à la clé *annoncée*
            // (clé éphémère du pair, qui sera enregistrée si la procédure
            // de pairage aboutit). Sans clé annoncée, on ne peut pas
            // vérifier et le message est rejeté.
            guard let signature = message.signature else {
                return false
            }
            guard let advertisedKey = advertisedPublicKey else {
                return false
            }
            let bytesToVerify = canonicalBytes(for: message)
            return SecureIdentityStore.verifySignature(
                signature,
                for: bytesToVerify,
                publicKeyData: advertisedKey
            )
        }
    }

    /// Représentation canonique des octets signés d'un message.
    ///
    /// On signe la concaténation stable de : `type`, `messageID`, et le
    /// payload s'il existe. Cette construction ne dépend pas de
    /// `sender` (l'identité est déjà liée à la signature par construction).
    ///
    /// IMPORTANT : la forme binaire de `uuid_t` n'est pas portable entre
    /// plateformes (le padding interne peut varier entre iOS et macOS) ;
    /// on utilise donc un encodage `JSON` avec `outputFormatting =
    /// .sortedKeys` pour garantir un ordre de clés déterministe et
    /// indépendant de la machine. Le `UUID` est sérialisé en `String`
    /// (forme canonique `XXXXXXXX-XXXX-…`) et le `payload` (binaire)
    /// est sérialisé en base64.
    private static func canonicalBytes(
        for message: AirBridgeMessage
    ) -> Data {
        let fields = SignedMessageFields(
            type: message.type.rawValue,
            messageID: message.messageID.uuidString,
            payload: message.payload?.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Un `Encodable` aussi simple ne peut pas échouer.
        return try! encoder.encode(fields)
    }
}

/// Champs internes d'un message qui sont couverts par la signature.
///
/// Le `sender` n'est volontairement PAS inclus : l'identité de l'émetteur
/// est déjà liée à la signature par construction (la signature est
/// vérifiée avec la clé publique annoncée dans `sender`).
private struct SignedMessageFields: Encodable {
    /// `rawValue` du type de message.
    let type: String
    /// Forme canonique du `messageID` (UUID en hexadécimal avec tirets).
    let messageID: String
    /// `payload` encodé en base64, ou `nil` si le message n'en a pas.
    let payload: String?
}
