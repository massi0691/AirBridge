//
//  TransferChunkSizing.swift
//  AirBridge
//

import Foundation

/// Choisit la taille des morceaux d'un envoi selon la taille du fichier.
///
/// La taille d'un morceau n'apparaît nulle part dans le protocole : le
/// récepteur lit une trame préfixée de sa longueur, écrit les octets à
/// l'`offset` annoncé, et la finalisation ne compare que le total reçu au
/// total annoncé. Un émetteur qui grossit ses morceaux reste donc
/// compréhensible par un récepteur inchangé — c'est le seul levier de débit
/// qui ne touche pas au format d'échange.
///
/// Grossir les morceaux amortit tout ce qui se paie *par morceau* : deux
/// sérialisations JSON, deux encodages base64, une trame, et un aller-retour
/// asynchrone jusqu'à l'acteur principal. Sur un fichier d'un gigaoctet,
/// passer de 64 Kio à 512 Kio ramène ces 16 384 répétitions à 2 048.
enum TransferChunkSizing {

    /// En dessous de ce seuil, le découpage ne coûte presque rien : la
    /// taille d'origine est conservée telle quelle, pour que les petits
    /// transferts gardent le comportement déjà validé.
    static let mediumFileThreshold: Int64 = 1 * 1024 * 1024

    /// Au-delà, on est dans le domaine des vidéos et des archives, où le
    /// coût par morceau domine le transfert.
    static let largeFileThreshold: Int64 = 64 * 1024 * 1024

    static let smallFileChunkSize = 64 * 1024
    static let mediumFileChunkSize = 256 * 1024

    /// Plafond optimisé pour les gros fichiers (vidéos, archives).
    ///
    /// Un morceau traverse l'encodage en gonflant d'environ 78 % — deux
    /// base64 successifs — et plusieurs copies coexistent le temps de la
    /// sérialisation. À 2 Mio le pic reste de l'ordre de ~10-15 Mio,
    /// acceptable sur iPhone moderne ; cela divise par 4 le nombre de chunks
    /// vs 512 Kio et réduit d'autant l'overhead JSON/base64/Task.
    static let largeFileChunkSize = 2 * 1024 * 1024

    /// Taille de morceau retenue pour un fichier de `fileSize` octets.
    ///
    /// Une taille inconnue ou absurde retombe sur la plus petite valeur :
    /// se tromper vers le bas ne coûte que du débit, se tromper vers le
    /// haut coûterait de la mémoire.
    static func chunkSize(forFileSize fileSize: Int64) -> Int {

        guard fileSize > 0 else {
            return smallFileChunkSize
        }

        if fileSize < mediumFileThreshold {
            return smallFileChunkSize
        }

        if fileSize < largeFileThreshold {
            return mediumFileChunkSize
        }

        return largeFileChunkSize
    }
}
