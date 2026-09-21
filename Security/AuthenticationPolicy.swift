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
/// attendu : obligation stricte, obligation adoucie pour le premier contact,
/// ou interdiction pure et simple d'un type de message particulier. La valeur
/// historique `optionalLegacy` n'est plus permissive.
enum AuthenticationRequirement: Sendable, Equatable {

    /// Le message doit porter une signature valide contre la clé publique
    /// attendue du pair. Tout message non signé ou mal signé est rejeté.
    case required

    /// Le message doit être signé, mais la vérification peut accepter un
    /// pair encore inconnu du store : la clé publique annoncée dans le
    /// message est utilisée directement (cas typique du tout premier
    /// contact, où le pair n'a pas encore été persisté).
    case requiredForKnownPeer

    /// Ancienne valeur conservée pour la compatibilité source. Elle n'est
    /// jamais produite par la policy v2 et `MessageAuthenticator` refuse
    /// également un message non signé dans ce mode.
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
/// L'objectif est strict : la v2 est la seule version acceptée et aucun
/// contrôle non signé ne doit être traité. Un pair inconnu peut uniquement
/// présenter une identité signée (et demander un transfert soumis à
/// approbation) ; toutes les mutations suivantes exigent la clé persistée.
/// Les `fileChunk` sont traités par le chiffrement de session et ne passent
/// jamais par la vérification de signature par message.
///
/// Le résultat de cette politique est ensuite appliqué par le vérificateur
/// de signature, qui choisit entre « vérifier contre la clé du store »,
/// « vérifier contre la clé annoncée » ou refuser.
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
    /// peuvent être vérifiés contre la clé publique long-terme
    /// *annoncée* dans le message lui-même, ce qui suffit à authentifier
    /// le premier contact avant sa persistance.
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
        .keyExchangeAck,
        // Un pair inconnu peut demander un transfert : la signature
        // authentifie le message, puis la confirmation utilisateur décide
        // si le transfert est accepté. Les autres mutations restent
        // réservées à une session déjà connue.
        .transferRequest
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

        // Toute version antérieure à v2 est rejetée par
        // `ProtocolCompatibility`. Ne jamais réintroduire ici une
        // acceptation permissive : un message v1 non signé pourrait être
        // forgé au nom d'un pair de confiance.
        if protocolVersion < ProtocolCompatibility.currentVersion {
            return .required
        }

        // Un pair bloqué ne doit plus faire progresser une session déjà
        // ouverte. La signature reste techniquement valide, mais l'état
        // métier interdit tout nouveau message avant le routage.
        if peerTrustState == .blocked {
            return .forbidden
        }

        // v2 : les chunks ne sont JAMAIS signés individuellement.
        // La chaîne est protégée par le `transferCompleted` final signé.
        if type == .fileChunk {
            return .forbidden
        }

        // Un pair déjà trusted dont la clé annoncée diverge ne doit
        // jamais repasser par la liste blanche du premier contact. La
        // signature sera vérifiée contre la clé persistée et échouera si
        // la clé a réellement changé.
        if peerTrustState == .trusted, !peerPublicKeyMatches {
            return .required
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
