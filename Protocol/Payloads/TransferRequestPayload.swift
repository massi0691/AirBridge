//
//  TransferRequestPayload.swift
//  AirBridge
//
//  Created by massi9106 on 24/07/2026.
//

import Foundation

struct TransferRequestPayload: Codable, Sendable {

    let transferID: UUID
    let fileName: String
    let fileSize: Int64
    let contentType: String?

    /// Sélection d'origine, présente uniquement quand elle contient
    /// plusieurs fichiers : le récepteur les rassemble alors dans un seul
    /// sous-dossier. Absent pour un fichier isolé, qui reste à plat.
    let batchID: UUID?

    /// Nom souhaité pour le sous-dossier, renseigné lors de l'envoi d'un
    /// dossier. Laissé vide pour une sélection de fichiers : le récepteur
    /// nomme alors le dossier d'après sa propre date de réception.
    let batchFolderName: String?

    /// Chemin du fichier à l'intérieur du lot, qui préserve l'arborescence
    /// d'un dossier envoyé. Vide quand le fichier est à la racine du lot.
    ///
    /// Valeur non fiable : elle vient du réseau et doit être assainie
    /// avant tout accès disque.
    let relativePath: String?

    init(
        transferID: UUID = UUID(),
        fileName: String,
        fileSize: Int64,
        contentType: String? = nil,
        batchID: UUID? = nil,
        batchFolderName: String? = nil,
        relativePath: String? = nil
    ) {
        self.transferID = transferID
        self.fileName = fileName
        self.fileSize = fileSize
        self.contentType = contentType
        self.batchID = batchID
        self.batchFolderName = batchFolderName
        self.relativePath = relativePath
    }
}
