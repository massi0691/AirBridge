//
//  TransferStorage.swift
//  AirBridge
//

import Foundation
import OSLog

@MainActor
final class TransferStorage {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "transfer.storage"
    )

    private let receivedFolderStore: ReceivedFolderStore

    /// Sous-dossier déjà créé pour un lot, avec le dossier de réception
    /// qui l'accueillait.
    ///
    /// Sans cette mémoire, chaque fichier d'une même sélection créerait
    /// son propre dossier « Réception_… 2 », « … 3 » : le lot n'en forme
    /// qu'un, créé au premier fichier et réutilisé ensuite.
    ///
    /// Le dossier de réception est conservé avec l'URL pour détecter un
    /// changement de destination en cours de lot : le dossier mémorisé ne
    /// vaut plus rien si l'utilisateur a choisi un autre emplacement.
    private var batchFolders: [UUID: (base: URL, folder: URL)] = [:]

    init(
        receivedFolderStore: ReceivedFolderStore
    ) {
        self.receivedFolderStore = receivedFolderStore
    }

    func save(
        temporaryFileURL: URL,
        fileName: String,
        batch: ReceivedBatchContext? = nil
    ) throws -> URL {

        let destinationDirectory: URL

        #if os(iOS)

        destinationDirectory = URL.documentsDirectory

        #elseif os(macOS)

        if let selectedDirectory = receivedFolderStore.selectedDirectory {
            // Le dossier choisi reste prioritaire et conserve son accès
            // security-scoped pendant toute l'opération.
            let hasAccess =
                selectedDirectory
                    .startAccessingSecurityScopedResource()

            guard hasAccess else {
                throw TransferManagerError
                    .receivedDirectoryAccessDenied
            }

            defer {
                selectedDirectory
                    .stopAccessingSecurityScopedResource()
            }

            destinationDirectory = selectedDirectory
        } else {
            // Sans préférence enregistrée, la réception reste utilisable
            // en repliant vers le dossier Downloads de l'utilisateur.
            destinationDirectory = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
        }

        #else

        destinationDirectory =
            URL.documentsDirectory

        #endif

        try validateDirectory(
            destinationDirectory
        )

        let destinationURL = try resolveDestinationURL(
            fileName: fileName,
            batch: batch,
            in: destinationDirectory
        )

        // Juste avant le déplacement, et pas plus tôt : c'est l'état du
        // système de fichiers à cet instant qui décide où `rename` écrira.
        try validateNoSymlinkOnPath(
            to: destinationURL,
            from: destinationDirectory
        )

        try FileManager.default.moveItem(
            at: temporaryFileURL,
            to: destinationURL
        )

        logger.info("Fichier déplacé vers : \(destinationURL.path, privacy: .public)")

        return destinationURL
    }

    /// Oublie les sous-dossiers mémorisés.
    ///
    /// Appelé au nettoyage de session : les lots en cours sont abandonnés,
    /// donc leurs dossiers n'ont plus à être réutilisés.
    func forgetBatchFolders() {
        batchFolders.removeAll()
    }
}

// MARK: - Destination

private extension TransferStorage {

    /// Calcule où écrire le fichier reçu.
    ///
    /// Sans lot, le fichier reste à plat dans le dossier de réception :
    /// c'est le comportement d'un fichier isolé, inchangé. Avec un lot,
    /// il rejoint le sous-dossier du lot, à l'emplacement que décrit son
    /// chemin relatif.
    func resolveDestinationURL(
        fileName: String,
        batch: ReceivedBatchContext?,
        in destinationDirectory: URL
    ) throws -> URL {

        // Le nom vient du réseau, y compris pour un fichier isolé : il est
        // assaini dans tous les cas, pas seulement en présence d'un lot.
        let safeFileName =
            ReceivedBatchLayout.sanitizedComponent(fileName)
                ?? "Fichier reçu"

        guard let batch else {

            let destinationURL = ReceivedBatchLayout.uniqueURL(
                name: safeFileName,
                in: destinationDirectory
            )

            try validateContainment(
                destinationURL,
                in: destinationDirectory
            )

            return destinationURL
        }

        let batchFolderURL = try batchFolder(
            for: batch,
            in: destinationDirectory
        )

        let relativeComponents =
            ReceivedBatchLayout.sanitizedRelativeComponents(
                batch.relativePath
            )

        // Le dernier composant du chemin relatif est le fichier lui-même,
        // les précédents sont l'arborescence à recréer.
        let intermediateComponents =
            relativeComponents?.dropLast() ?? []

        let leafName = relativeComponents?.last ?? safeFileName

        var targetDirectory = batchFolderURL

        for component in intermediateComponents {
            targetDirectory = targetDirectory
                .appendingPathComponent(component)
        }

        try validateContainment(
            targetDirectory,
            in: batchFolderURL,
            allowingSameDirectory: true
        )

        if !intermediateComponents.isEmpty {
            try FileManager.default.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
        }

        let destinationURL = ReceivedBatchLayout.uniqueURL(
            name: leafName,
            in: targetDirectory
        )

        try validateContainment(
            destinationURL,
            in: batchFolderURL
        )

        return destinationURL
    }

    /// Sous-dossier du lot, créé au premier fichier puis réutilisé.
    func batchFolder(
        for batch: ReceivedBatchContext,
        in destinationDirectory: URL
    ) throws -> URL {

        if let memorized = batchFolders[batch.batchID],
           memorized.base == destinationDirectory,
           FileManager.default.fileExists(
               atPath: memorized.folder.path
           ) {
            return memorized.folder
        }

        let folderName = ReceivedBatchLayout.folderName(
            proposed: batch.folderName,
            receivedAt: Date()
        )

        let folderURL = ReceivedBatchLayout.uniqueURL(
            name: folderName,
            in: destinationDirectory
        )

        try validateContainment(
            folderURL,
            in: destinationDirectory
        )

        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )

        batchFolders[batch.batchID] = (
            base: destinationDirectory,
            folder: folderURL
        )

        logger.info("Sous-dossier de réception créé : \(folderURL.path, privacy: .public)")

        return folderURL
    }

    func validateContainment(
        _ url: URL,
        in directory: URL,
        allowingSameDirectory: Bool = false
    ) throws {

        if allowingSameDirectory,
           url.standardizedFileURL.path
               == directory.standardizedFileURL.path {
            return
        }

        guard ReceivedBatchLayout.isContained(
            url,
            in: directory
        ) else {

            logger.error("Chemin de réception hors du dossier autorisé : \(url.path, privacy: .public)")

            throw TransferManagerError
                .receivedDirectoryAccessDenied
        }
    }
}

// MARK: - Vérifications

private extension TransferStorage {

    func validateDirectory(
        _ directory: URL
    ) throws {

        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue else {

            logger.error("Le dossier de réception n’existe plus : \(directory.path, privacy: .public)")

            throw TransferManagerError
                .receivedDirectoryNotFound
        }
    }

    /// Refuse le déplacement si un maillon du chemin de destination est
    /// devenu un lien symbolique depuis la validation de confinement.
    ///
    /// Appelé juste avant `moveItem`, et pas plus tôt : c'est l'état du
    /// système de fichiers à cet instant qui décide où `rename` écrira. La
    /// règle elle-même vit dans `ReceivedBatchLayout`, avec le reste de ce
    /// qui touche aux chemins reçus.
    func validateNoSymlinkOnPath(
        to destinationURL: URL,
        from root: URL
    ) throws {

        guard ReceivedBatchLayout.containsNoSymbolicLink(
            pathTo: destinationURL,
            from: root
        ) else {

            logger.error("Lien symbolique sur le chemin de réception : \(destinationURL.path, privacy: .public)")

            throw TransferManagerError
                .receivedDirectoryAccessDenied
        }
    }
}
