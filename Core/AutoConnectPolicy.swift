//
//  AutoConnectPolicy.swift
//  AirBridge
//
//  Politique de connexion automatique, extraite d'`AirBridgeCore` pour
//  être testable en isolation (sans session réseau réelle).
//
//  Trois motifs de connexion automatique coexistent :
//   1. reprises de transfert interrompus en attente vers ce pair ;
//   2. pair de confiance (pairage confirmé) ;
//   3. envoi ciblé programmé depuis la feuille de partage / l'extension
//      Finder (« envoyer à <dernier appareil> »).
//
//  La préférence utilisateur `autoConnectEnabled` (Réglages ▸
//  « Connexion automatique ») ne masque QUE le motif n° 2 : une reprise
//  de transfert ou un envoi explicitement demandé par l'utilisateur ne
//  dépendent pas de cette option.
//

import Foundation

/// Décision rendue pour une redécouverte Bonjour donnée.
nonisolated enum AutoConnectDecision: Equatable, Sendable {
    /// La connexion doit être tentée immédiatement.
    case connect

    /// La connexion est refusée, pour un motif explicite (logs + tests).
    case skip(reason: AutoConnectSkipReason)
}

/// Motif de refus d'une connexion automatique.
nonisolated enum AutoConnectSkipReason: Equatable, Sendable {
    /// L'utilisateur a désactivé la connexion automatique (motif
    /// « confiance » uniquement — voir `AutoConnectPolicy`).
    case settingDisabled

    /// Une session est déjà active : une seule session à la fois.
    case sessionActive

    /// Le pair est bloqué.
    case peerBlocked

    /// L'utilisateur s'est déconnecté de ce pair explicitement et le
    /// couplet de présence n'a pas encore observé son départ du réseau.
    case userDisconnected

    /// Fenêtre d'anti-rafale / backoff pas encore écoulée.
    /// (`remaining` = secondes restantes, pour les logs.)
    case backoff(remaining: TimeInterval)

    /// Ni pair de confiance, ni reprise en attente, ni envoi ciblé :
    /// rien à faire pour ce pair.
    case notInteresting
}

/// Règles pures de la connexion automatique.
///
/// Aucun accès réseau, aucune mutation d'état : la fonction `evaluate`
/// est un test de décisions pures, ce qui permet de couvrir les cas
/// critiques (réglage désactivé, pair bloqué, déconnexion explicite,
/// backoff exponentiel) sans instancier `ConnectionManager`.
nonisolated enum AutoConnectPolicy {

    // MARK: - Préférence utilisateur

    /// Clé `UserDefaults` de la préférence « Connexion automatique ».
    static let enabledPreferenceKey = "autoConnectEnabled"

    /// Vrai (par défaut) tant que l'utilisateur n'a pas explicitement
    /// désactivé la connexion automatique.
    static func isEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: enabledPreferenceKey) as? Bool ?? true
    }

    // MARK: - Backoff

    /// Intervalle de base entre deux tentatives automatiques vers un
    /// même pair (secondes).
    static let baseRetryInterval: TimeInterval = 15

    /// Plafond du backoff exponentiel (secondes). Au-delà, une session
    /// instable n'est plus harcelée à chaque événement Bonjour.
    static let maxRetryInterval: TimeInterval = 240

    /// Backoff exponentiel plafonné : 15 s, 30 s, 60 s, 120 s, 240 s…
    /// `failureCount` = nombre de sessions avortées depuis le dernier
    /// succès vers ce pair (0 = première tentative).
    static func retryInterval(
        afterFailureCount failureCount: Int
    ) -> TimeInterval {
        let clamped = max(0, failureCount)
        // 2^clamped sans débordement : au-delà de 60, le plafond est
        // atteint de toute façon.
        let multiplier = clamped >= 60
            ? TimeInterval.greatestFiniteMagnitude
            : pow(2.0, Double(clamped))
        let delay = baseRetryInterval * multiplier
        return min(delay, maxRetryInterval)
    }

    // MARK: - Décision

    /// Évalue si une connexion automatique doit être tentée.
    ///
    /// - Parameters:
    ///   - hasSession: une session est déjà active.
    ///   - hasPendingResume: des transferts interrompus attendent ce pair.
    ///   - isTrusted: le pair est marqué de confiance.
    ///   - isBlocked: le pair est bloqué.
    ///   - isUserDisconnected: déconnexion explicite encore en vigueur.
    ///   - autoConnectEnabled: préférence utilisateur.
    ///   - lastAttempt: dernière tentative automatique vers ce pair.
    ///   - failureCount: échecs consécutifs depuis le dernier succès.
    ///   - now: horodatage courant (injecté pour les tests).
    static func evaluate(
        hasSession: Bool,
        hasPendingResume: Bool,
        isTrusted: Bool,
        isBlocked: Bool,
        isUserDisconnected: Bool,
        autoConnectEnabled: Bool,
        lastAttempt: Date?,
        failureCount: Int,
        now: Date = Date()
    ) -> AutoConnectDecision {
        if hasSession {
            return .skip(reason: .sessionActive)
        }
        if isBlocked {
            return .skip(reason: .peerBlocked)
        }
        if isUserDisconnected {
            return .skip(reason: .userDisconnected)
        }

        // Intérêt pour ce pair : reprise en attente (toujours active,
        // indépendante du réglage) OU pair de confiance (uniquement si
        // le réglage l'autorise).
        if !hasPendingResume && !isTrusted {
            return .skip(reason: .notInteresting)
        }
        if !hasPendingResume && isTrusted && !autoConnectEnabled {
            // L'utilisateur a coupé la connexion automatique : distinguer
            // ce refus d'une paire « sans intérêt » dans les logs/tests.
            return .skip(reason: .settingDisabled)
        }

        // Anti-rafale / backoff.
        if let lastAttempt {
            let interval = retryInterval(afterFailureCount: failureCount)
            let elapsed = now.timeIntervalSince(lastAttempt)
            if elapsed < interval {
                return .skip(reason: .backoff(remaining: interval - elapsed))
            }
        }

        return .connect
    }
}
