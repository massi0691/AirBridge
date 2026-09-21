//
//  ReceptionRejection.swift
//  AirBridge
//
//  Description d'un message de contrôle écarté à la réception.
//

import Foundation

/// Cause d'un contrôle écarté par le pipeline de réception sécurisé.
///
/// `ConnectionManager` rejette un message quand la signature ne peut pas
/// être vérifiée, quand le pair n'est pas encore appairé, ou quand un
/// rejeu est détecté. Ces rejets sont **silencieux pour l'utilisateur** :
/// sans cette valeur, un émetteur dont le `transferAccepted` a été écarté
/// resterait indéfiniment « En attente » sans rien pouvoir diagnostiquer.
///
/// `nonisolated` : valeur pure, lue depuis l'interface (MainActor) comme
/// depuis les tests, sans dépendre de l'isolation par défaut du projet
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
nonisolated struct ReceptionRejection: Sendable, Equatable {

    /// Famille de rejet, stable et testable (le libellé, lui, est
    /// destiné à l'affichage).
    enum Kind: String, Sendable, Equatable {
        /// Le message ne porte pas de clé publique long-terme.
        case missingPublicKey
        /// L'identité du payload diffère de celle du sender.
        case identityMismatch
        /// Signature absente ou invalide contre la clé attendue.
        case signatureInvalid
        /// Pair jamais enregistré dans le `PairingStore` : aucun contrôle
        /// sensible ne peut être authentifié tant que le pairage n'a pas
        /// abouti (`transferAccepted`, `transferRejected`, …).
        case peerNotPaired
        /// Clé publique annoncée différente de celle enregistrée.
        case keyMismatch
        /// Message déjà vu dans la fenêtre anti-rejeu.
        case replay
        /// Contrôle reçu avant la fin du handshake ECDH.
        case secureSessionNotReady
    }

    let kind: Kind
    let messageType: String
    let peerName: String?
    let date: Date

    /// Explication destinée à l'écran de diagnostic : elle nomme le type
    /// de message écarté et la cause, puis indique l'action à effectuer.
    var userFacingMessage: String {
        let target = messageType.isEmpty ? "un contrôle" : messageType

        switch kind {
        case .missingPublicKey:
            return "\(target) écarté : le pair n’a pas présenté sa clé publique. "
                + "Redémarrez AirBridge sur les deux appareils."
        case .identityMismatch:
            return "\(target) écarté : identité du payload différente de celle du pair."
        case .signatureInvalid:
            return "\(target) écarté : signature invalide. Le pair utilise peut-être "
                + "une autre identité qu’au moment du pairage."
        case .peerNotPaired:
            return "\(target) écarté : l’appareil n’est pas encore appairé. "
                + "Relancez la connexion (radar) pour refaire le pairage, puis l’envoi."
        case .keyMismatch:
            return "\(target) écarté : la clé de l’appareil a changé depuis le pairage. "
                + "Oubliez l’appareil dans Réglages ▸ Appareils appairés, puis réappairez."
        case .replay:
            return "\(target) écarté : message déjà reçu (protection anti-rejeu)."
        case .secureSessionNotReady:
            return "\(target) écarté : reçu avant la fin de la session sécurisée (ECDH)."
        }
    }

    init(
        kind: Kind,
        messageType: String,
        peerName: String? = nil,
        date: Date = Date()
    ) {
        self.kind = kind
        self.messageType = messageType
        self.peerName = peerName
        self.date = date
    }
}
