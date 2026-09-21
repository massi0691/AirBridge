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
/// signature avec la clé publique annoncée dans `sender` puis, pour un
/// pair connu, avec la clé persistée. Cela empêche un attaquant de rejouer
/// ou de falsifier des messages au nom d'un pair de confiance.
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
    /// - `.optionalLegacy` : ancienne valeur conservée pour compatibilité
    ///   source, mais un message non signé reste rejeté ; une signature
    ///   présente est vérifiée contre la clé publique **annoncée**.
    /// - `.required` : la signature doit être présente et valide contre
    ///   la clé publique du `PairingStore`. Si aucune clé n'est persistée,
    ///   le message est rejeté : aucune mutation ne peut choisir sa propre
    ///   identité. **Aucune exception** : sans signature valide, le message
    ///   est rejeté.
    /// - `.requiredForKnownPeer` : la signature doit être présente et
    ///   valide contre la clé publique long-terme **annoncée** (cas du tout
    ///   premier contact, où le pair n'a pas encore été persisté).
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
            // Valeur conservée uniquement pour la compatibilité source avec
            // d'anciens appelants. Elle ne constitue plus un mode permissif:
            // un contrôle non signé est toujours rejeté, y compris si un
            // appelant contourne `ProtocolCompatibility`.
            guard let signature = message.signature,
                  let advertisedKey = advertisedPublicKey else {
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
            // Un message hors liste de premier contact exige une identité
            // déjà persistée. Ne jamais retomber sur la clé annoncée ici :
            // cela permettrait à un pair inconnu de forger une mutation
            // d'état en choisissant lui-même son identité.
            guard let keyToCheck = storePublicKey else {
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
    /// L'identité fait partie de la signature v2. On lie donc le contenu à
    /// la combinaison `(version, sender.id, clé publique annoncée)` et non
    /// seulement à la clé utilisée au moment de la vérification. Cela
    /// empêche de réutiliser une signature avec un autre UUID ou une autre
    /// clé publique dans l'enveloppe du message.
    ///
    /// IMPORTANT : la forme binaire de `uuid_t` n'est pas portable entre
    /// plateformes ; JSON trié est utilisé pour obtenir une représentation
    /// déterministe. Les UUID sont des chaînes canoniques et les données
    /// binaires sont encodées en base64.
    static func canonicalBytes(
        for message: AirBridgeMessage
    ) -> Data {
        let fields = SignedMessageFields(
            protocolVersion: message.protocolVersion,
            type: message.type.rawValue,
            messageID: message.messageID.uuidString,
            senderID: message.sender.id.uuidString,
            senderPublicKey: message.sender.publicKeyData?.base64EncodedString(),
            payload: message.payload?.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Un `Encodable` aussi simple ne peut pas échouer.
        return try! encoder.encode(fields)
    }
}

/// Champs internes d'un message qui sont couverts par la signature.
private struct SignedMessageFields: Encodable {
    let protocolVersion: Int
    let type: String
    let messageID: String
    let senderID: String
    let senderPublicKey: String?
    let payload: String?
}
