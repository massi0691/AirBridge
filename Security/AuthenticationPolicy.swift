//
//  AuthenticationPolicy.swift
//  AirBridge
//
//  Created by massi9106 on 27/08/2026.
//

import Foundation

/// Niveau d'authentification requis pour accepter un message de contrôle.
///
/// Cette énumération décrit, pour un message donné, l'effort d'authentification
/// attendu : obligation stricte, obligation adoucie pour les pairs déjà
/// connus, acceptation sans signature pour la compatibilité ascendante, ou
/// interdiction pure et simple d'un type de message particulier.
enum AuthenticationRequirement: Sendable, Equatable {

    /// Le message doit porter une signature valide contre la clé publique
    /// attendue du pair. Tout message non signé ou mal signé est rejeté.
    case required

    /// Le message doit être signé, mais la vérification peut accepter un
    /// pair encore inconnu du store : la clé publique annoncée dans le
    /// message est utilisée directement (cas typique du tout premier
    /// contact, où le pair n'a pas encore été persisté).
    case requiredForKnownPeer

    /// Le message est accepté même s'il n'est pas signé. Réservé à la
    /// compatibilité ascendante avec les pairs v1 qui n'embarquaient pas
    /// de signature sur leurs messages de contrôle.
    case optionalLegacy

    /// Le message ne doit jamais être traité sur cette version de
    /// protocole. Utilisé pour les `fileChunk` en v2 : les chunks sont
    /// protégés par le `transferCompleted` signé en fin de chaîne, pas
    /// message par message.
    case forbidden
}

/// Politique d'authentification des messages de contrôle.
///
/// Centralise la décision « ce message doit-il être signé ? » en fonction
/// du type de message, de la version de protocole, de l'état de confiance
/// du pair dans le `PairingStore`, et de la cohérence entre la clé publique
/// annoncée et celle persistée.
///
/// L'objectif est double :
/// 1. **Préserver la compatibilité v1** : un pair v1 (sans signature) doit
///    continuer à pouvoir dialoguer avec cette application tant qu'il n'a
///    pas migré. Tous les messages de contrôle v1 sont donc marqués
///    `optionalLegacy`.
/// 2. **Durcir progressivement la v2** : un pair v2 annoncé ne peut émettre
///    de message de contrôle *non signé* (sauf cas explicitement listé
///    pour le premier contact) ni de `fileChunk` (le flux binaire est
///    protégé globalement par le `transferCompleted`).
///
/// Le résultat de cette politique est ensuite appliqué par le vérificateur
/// de signature, qui choisit entre « vérifier contre la clé du store »,
/// « vérifier contre la clé annoncée » ou « accepter en mode permissif ».
///
/// `nonisolated` : ce type est une table de règles pures, consultée depuis
/// le cœur `@MainActor` comme depuis du code hors acteur principal
/// (décodage, vérifications précoces). Sans cette annotation, l'isolation
/// par défaut du projet (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
/// interdirait ces lectures.
nonisolated enum AuthenticationPolicy {

    /// Messages de contrôle sensibles en v2.
    ///
    /// Ce sont les messages qui peuvent faire muter l'état du protocole
    /// (démarrer un transfert, l'accepter, le finaliser, l'annuler, le
    /// reprendre) ou qui établissent l'identité des interlocuteurs
    /// (`hello`, `pairing*`). Ils doivent être signés.
    ///
    /// Les `fileChunk` sont volontairement exclus : leur authenticité est
    /// prouvée collectivement par le `transferCompleted` signé en fin de
    /// chaîne, pas individuellement.
    private static let sensitiveControlMessages: Set<AirBridgeMessageType> = [
        .hello,
        .acknowledgement,
        .ping,
        .pong,
        .pairingRequest,
        .pairingResponse,
        .keyExchange,
        .keyExchangeAck,
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

    /// Messages de contrôle autorisés avant pairage complet en v2.
    ///
    /// Pendant la phase de découverte initiale, un pair n'est pas encore
    /// enregistré dans le `PairingStore`. Les messages de cette liste
    /// peuvent être vérifiés contre la clé publique *annoncée* dans le
    /// message lui-même (clé éphémère du pair), ce qui suffit à empêcher
    /// un rejeu ou une falsification sur le premier contact.
    ///
    /// Tous les autres messages de contrôle sensibles exigent un pair déjà
    /// connu du store ; à défaut, ils sont rejetés.
    private static let messagesAllowedBeforePairing: Set<AirBridgeMessageType> = [
        .hello,
        .acknowledgement,
        .ping,
        .pong,
        .pairingRequest,
        .pairingResponse,
        .keyExchange,
        .keyExchangeAck
    ]

    /// Décide le niveau d'authentification requis pour un message.
    ///
    /// - Parameters:
    ///   - type: Type du message reçu.
    ///   - protocolVersion: Version de protocole annoncée par l'émetteur.
    ///   - peerTrustState: État de confiance connu du pair dans le
    ///     `PairingStore` (`.unknown` si le pair n'y figure pas).
    ///   - peerPublicKeyMatches: `true` si la clé publique annoncée dans
    ///     le message correspond exactement à celle persistée pour ce pair.
    /// - Returns: Le niveau d'authentification à appliquer avant d'accepter
    ///   le message.
    static func authenticationRequirement(
        for type: AirBridgeMessageType,
        protocolVersion: Int,
        peerTrustState: TrustState,
        peerPublicKeyMatches: Bool
    ) -> AuthenticationRequirement {

        // v1 : tout message de contrôle reste en mode permissif. La
        // signature était absente du protocole, l'exiger briserait la
        // compatibilité ascendante.
        if protocolVersion < 2 {
            return .optionalLegacy
        }

        // v2 : les chunks ne sont JAMAIS signés individuellement.
        // La chaîne est protégée par le `transferCompleted` final signé.
        if type == .fileChunk {
            return .forbidden
        }

        // v2, message de contrôle sensible, pair trusted avec clé qui
        // correspond : on exige la signature contre la clé du store.
        if peerTrustState == .trusted, peerPublicKeyMatches {
            return .required
        }

        // v2, message de contrôle sensible, pair connu (pending ou
        // blocked) dans le store mais clé publique annoncée qui ne
        // correspond pas à celle enregistrée : on exige la signature
        // contre la clé du store (qui rejettera). Une clé annoncée
        // différente = tentative de substitution d'identité.
        if peerTrustState == .pending
            || peerTrustState == .blocked {
            return .required
        }

        // v2, pair inconnu du store : on n'autorise que les messages de
        // premier contact. La signature est vérifiée contre la clé
        // *annoncée* dans le message (clé éphémère du pair, qui sera
        // enregistrée si la procédure de pairage aboutit).
        if messagesAllowedBeforePairing.contains(type) {
            return .requiredForKnownPeer
        }

        // v2, pair inconnu et message sensible hors liste blanche :
        // exigence stricte, qui sera rejetée à la vérification faute
        // de clé publique enregistrée.
        return .required
    }

    /// Indique si un type de message est un message de contrôle sensible
    /// en v2.
    ///
    /// Exposé pour les diagnostics et les tests : la liste est
    /// intentionnellement conservative (les `fileChunk` n'en font pas
    /// partie, pas plus que `error` qui n'est pas un état protocolaire
    /// durable).
    static func isSensitiveControlMessage(
        _ type: AirBridgeMessageType,
        protocolVersion: Int
    ) -> Bool {
        guard protocolVersion >= 2 else { return false }
        return sensitiveControlMessages.contains(type)
    }
}
