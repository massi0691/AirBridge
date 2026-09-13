//
//  ReceivedBatchLimits.swift
//  AirBridge
//

import Foundation

/// Plafonds appliqués à ce qu'un pair peut annoncer.
///
/// Les tailles et les comptes viennent du réseau. Sans plafond, un pair
/// hostile — ou simplement un émetteur qui se trompe — peut annoncer un
/// fichier de plusieurs téraoctets ou un lot de cent mille entrées, et
/// remplir le disque avant qu'on s'en aperçoive.
///
/// Les valeurs sont volontairement généreuses : elles visent l'absurde, pas
/// l'inhabituel. Un usage légitime ne doit jamais les rencontrer.
enum ReceivedBatchLimits {

    /// Taille maximale d'un fichier reçu.
    ///
    /// Large devant une vidéo, étroit devant une annonce fantaisiste.
    static let maximumFileSize: Int64 = 64 * 1024 * 1024 * 1024

    /// Nombre maximal de fichiers dans un même lot.
    static let maximumFilesPerBatch = 10_000

    /// Volume total maximal d'un lot.
    static let maximumBatchSize: Int64 = 256 * 1024 * 1024 * 1024

    /// Vrai si une taille de fichier annoncée est plausible.
    ///
    /// Une taille négative n'existe pas : elle trahit soit un débordement,
    /// soit une annonce forgée.
    static func isAcceptableFileSize(
        _ fileSize: Int64
    ) -> Bool {

        fileSize >= 0 && fileSize <= maximumFileSize
    }

    /// Vrai si un lot peut encore accueillir un fichier de `fileSize`
    /// octets, sachant ce qu'il contient déjà.
    ///
    /// La vérification est incrémentale parce que les fichiers d'un lot
    /// arrivent un par un : le total ne se connaît qu'à la fin, donc il faut
    /// refuser dès le fichier qui fait dépasser.
    static func canAccept(
        fileSize: Int64,
        inBatchOf existingCount: Int,
        totalBytes existingBytes: Int64
    ) -> Bool {

        guard isAcceptableFileSize(fileSize) else {
            return false
        }

        guard existingCount < maximumFilesPerBatch else {
            return false
        }

        // Additionner sans déborder : deux tailles valides peuvent dépasser
        // `Int64` une fois cumulées.
        let (total, didOverflow) = existingBytes.addingReportingOverflow(
            fileSize
        )

        guard !didOverflow else {
            return false
        }

        return total <= maximumBatchSize
    }

    /// Explication destinée aux traces, quand une annonce est écartée.
    static func rejectionReason(
        fileSize: Int64,
        inBatchOf existingCount: Int,
        totalBytes existingBytes: Int64
    ) -> String {

        if fileSize < 0 {
            return "taille négative annoncée (\(fileSize))"
        }

        if fileSize > maximumFileSize {
            return "fichier de \(fileSize) octets au-delà du plafond "
                + "de \(maximumFileSize)"
        }

        if existingCount >= maximumFilesPerBatch {
            return "lot déjà à \(existingCount) fichiers, plafond "
                + "\(maximumFilesPerBatch)"
        }

        return "lot au-delà du volume autorisé de \(maximumBatchSize) octets"
    }
}
