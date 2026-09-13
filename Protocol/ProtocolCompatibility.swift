//
//  ProtocolCompatibility.swift
//  AirBridge
//

import Foundation

/// Décide si un message reçu relève d'une version du protocole que cette
/// application sait lire.
///
/// `AirBridgeMessage` transporte un `protocolVersion` depuis l'origine, mais
/// personne ne le lisait : un pair d'une version inconnue était traité comme
/// compatible, et ses messages décodés au hasard de ce que `JSONDecoder`
/// acceptait. Refuser explicitement vaut mieux que mal interpréter.
///
/// Ce type est aussi le point d'accroche d'une future version 2 : c'est ici
/// que se déclarera la plage acceptée le jour où le format des morceaux
/// changera.
/// `nonisolated` : ce type est une table de constantes consultée depuis le
/// cœur `@MainActor` comme depuis du code hors acteur principal (encodage,
/// métadonnées persistées). Sans lui, l'isolation par défaut du projet
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) interdirait ces lectures.
nonisolated enum ProtocolCompatibility {

    /// Version émise par cette application.
    static let currentVersion = 2

    /// Version la plus ancienne encore comprise.
    ///
    /// La v1 utilisait JSON/base64 pour les chunks. La v2 utilise un format
    /// binaire direct pour fileChunk (pas de base64, pas de JSON).
    static let minimumSupportedVersion = 1

    /// Vrai si un message annonçant `version` peut être décodé.
    ///
    /// Une version plus récente est refusée plutôt que tentée : elle peut
    /// avoir changé la forme d'un contenu que nous croirions comprendre.
    static func isSupported(
        _ version: Int
    ) -> Bool {

        version >= minimumSupportedVersion
            && version <= currentVersion
    }

    /// Explication destinée aux traces, quand un message est écarté.
    static func rejectionReason(
        for version: Int
    ) -> String {

        if version > currentVersion {
            return "version \(version) plus récente que \(currentVersion) : "
                + "mettez à jour cette application"
        }

        return "version \(version) trop ancienne, minimum "
            + "\(minimumSupportedVersion)"
    }
}
