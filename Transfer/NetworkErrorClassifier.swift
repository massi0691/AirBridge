//
//  NetworkErrorClassifier.swift
//  AirBridge
//

import Foundation
import Network

/// Décision centrale : une erreur donnée signale-t-elle une perte de
/// liaison récupérable, ou un échec définitif ?
///
/// Une déconnexion Wi-Fi, une mise en veille ou un pair hors de portée
/// n'invalident pas les octets déjà transférés : le transfert doit passer
/// à `.interrupted` (reprisable) et non `.failed` (terminal). Cette
/// classification est le point unique où cette décision est prise, pour
/// que tous les pipelines (envoi, réception, callbacks de session)
/// réagissent de la même manière.
/// `nonisolated` : utilisé par le `ChunkSink` actor (phase 2-bis)
/// en plus de MainActor. Le classifier est un arbre de décisions pur
/// sans état mutable, il est donc sûr à partager.
nonisolated enum NetworkErrorClassifier {

    /// Vrai si l'erreur décrit une interruption réseau temporaire.
    ///
    /// `ECANCELED` (« Operation canceled ») est traité comme une
    /// interruption uniquement dans la mesure où c'est la perte de session
    /// qui provoque l'annulation des envois en vol : le pipeline s'annule
    /// lui-même quand la connexion tombe. L'annulation volontaire de
    /// l'utilisateur n'emprunte jamais ce chemin — elle passe par
    /// `cancelTransfer()`, qui ne consulte pas cette classification.
    nonisolated static func isRecoverableNetworkInterruption(_ error: Error) -> Bool {
        // Erreurs levées par nos propres gardes (session absente au moment
        // de l'envoi) : la liaison est perdue mais le transfert reste
        // reprisable.
        if error is ConnectionManager.ConnectionManagerError {
            return true
        }

        if let outgoingError = error as? OutgoingTransferManager
            .OutgoingTransferManagerError {
            switch outgoingError {
            case .encodingError:
                // Une erreur d'encodage locale (fichier illisible, payload
                // malformé) n'est pas une perte de liaison : elle se
                // reproduira à l'identique à chaque tentative.
                return false
            case .sendError(let underlying):
                // Emballage d'une erreur d'envoi : c'est la cause brute qui
                // décide (ECONNRESET → récupérable, cause métier → non).
                return isRecoverableNetworkInterruption(underlying)
            case .noActiveConnection, .secureSessionNotReady:
                // Gardes de session : la liaison sécurisée n'est pas encore
                // disponible ou vient de tomber (clé ECDH / sessionId absents,
                // connexion perdue). Les octets déjà transférés restent
                // reprenables une fois la session rétablie — même traitement
                // que `ConnectionManagerError` ci-dessus.
                return true
            case .sourceNotFound, .fileNotFound:
                // Gardes de source : la source a été libérée avec la session,
                // mais rien n'invalide les octets déjà transférés.
                return true
            default:
                // Cas non répertorié (le switch reste exhaustif si
                // `OutgoingTransferManagerError` s'enrichit) : rien ne prouve
                // une perte de liaison, on applique donc la règle par défaut
                // de la fonction — échec définitif — plutôt qu'une reprise
                // vouée à rééchouer à l'identique.
                return false
            }
        }

        if let urlError = error as? URLError {
            return isRecoverable(urlCode: urlError.code)
        }

        if let nwError = error as? NWError {
            return isRecoverable(posixCode: POSIXErrorCode(rawValue: Int32(nwError.errorCode)))
        }

        if let posixError = error as? POSIXError {
            return isRecoverable(posixCode: posixError.code)
        }

        let nsError = error as NSError

        if nsError.domain == NSPOSIXErrorDomain {
            return isRecoverable(posixCode: POSIXErrorCode(rawValue: Int32(nsError.code)))
        }

        // Les erreurs réseau de bas niveau (Network.framework) remontent
        // souvent sous le domaine générique sans code POSIX exploitable :
        // le message texte reste alors le seul signal fiable.
        return matchesKnownNetworkMessage(nsError.localizedDescription)
    }

    /// Codes POSIX décrivant une liaison rompue ou injoignable.
    nonisolated private static func isRecoverable(posixCode: POSIXErrorCode?) -> Bool {
        guard let posixCode else { return false }

        switch posixCode {
        case .ECONNRESET, .ENOTCONN, .ETIMEDOUT,
             .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN,
             .ECANCELED, .EPIPE:
            return true

        default:
            return false
        }
    }

    /// Codes URLError couvrant les mêmes situations, vues depuis URLSession.
    nonisolated private static func isRecoverable(urlCode: URLError.Code) -> Bool {
        switch urlCode {
        case .networkConnectionLost, .notConnectedToInternet,
             .cannotFindHost, .cannotConnectToHost,
             .timedOut, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed:
            return true

        default:
            return false
        }
    }

    /// Messages connus d'interruption, tels que Network.framework les
    /// formule. La comparaison est insensible à la casse et par préfixe :
    /// les descriptions sont parfois complétées (« Connection reset by
    /// peer », « No route to host »…).
    nonisolated private static func matchesKnownNetworkMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()

        let knownPatterns = [
            "no route to host",
            "network connection lost",
            "connection reset",
            "connection refused",
            "not connected",
            "socket is not connected",
            "broken pipe",
            "timed out",
            "operation canceled",
            "operation cancelled",
            "host unreachable",
            "network is down"
        ]

        return knownPatterns.contains { lowered.contains($0) }
    }
}
