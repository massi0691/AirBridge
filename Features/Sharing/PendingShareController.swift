//
//  PendingShareController.swift
//  AirBridge
//
//  Lot stationné par une extension de partage (Finder macOS / Share
//  Extension iOS) dans `group.com.airbridge.shared/PendingShares/`,
//  présenté dans l'interface d'envoi existante, sans envoi automatique.
//
//  Libre de toute couche de transfert : ce contrôleur ne modifie ni le
//  moteur ni le contrat de transfert. Il observe seulement, en lecture,
//  la liste des transferts sortants déjà exposée par le Core, pour
//  décider quand un fichier de lot est livré et peut être retiré.
//

import Foundation
import Observation
import os

/// Lot de fichiers prêt à être présenté dans la surface d'envoi.
struct PendingShareItem: Identifiable, Equatable {
    /// Signature unique du lot (URLs triées) : clé de déduplication entre
    /// les multiples chemins de remise (URL scheme, notification Darwin,
    /// balayage) du même lot.
    let id: String

    /// Fichiers du lot (le manifeste est exclu).
    let urls: [URL]
}

/// Bilan d'un balayage de purge.
struct PendingSharePruneResult: Equatable {
    var deletedFiles = 0
    var removedBatchDirectories = 0
    var errors: [PendingSharePruneError] = []
}

/// Erreur unitaire d'une suppression de lot, journalisée puis remontée.
struct PendingSharePruneError: Error, Equatable {
    let url: URL
    let reason: String

    var localizedDescription: String {
        "\(url.path) : \(reason)"
    }
}

@MainActor
@Observable
final class PendingShareController {

    /// Identifiant de l'App Group partagé avec les extensions
    /// (`ShareExtension` iOS, `FinderService` macOS).
    static let appGroupIdentifier = "group.com.airbridge.shared"

    private let logger = Logger(
        subsystem: "com.airbridge",
        category: "share.pending"
    )

    /// Lot actuellement affiché dans la feuille d'envoi.
    private(set) var item: PendingShareItem?

    /// Signatures déjà présentées. Un lot n'est présenté qu'une fois :
    /// toute remise redondante (URL scheme + notification Darwin +
    /// balayage) est ignorée, donc un envoi ne peut jamais être déclenché
    /// deux fois pour la même sélection.
    private var presentedSignatures: Set<String> = []

    // MARK: - Signature

    /// Signature canonique d'une liste de fichiers : URL absolues triées.
    static func signature(for urls: [URL]) -> String {
        urls
            .map(\.absoluteString)
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Présentation

    /// Présente un lot dans la feuille d'envoi, exactement une fois.
    ///
    /// N'effectue AUCUNE suppression : la simple présentation ou la
    /// fermeture de l'interface ne libère jamais de fichier. Le seul
    /// point de suppression est `pruneDeliveredBatches`.
    func present(urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard item == nil else { return }

        let signature = Self.signature(for: files)
        guard !presentedSignatures.contains(signature) else { return }

        presentedSignatures.insert(signature)
        item = PendingShareItem(id: signature, urls: files)
        logger.info("Lot présenté (\(files.count) fichier(s))")
    }

    /// Ferme la feuille. Les fichiers restent stationnés dans l'App Group :
    /// ils peuvent encore être envoyés (nouvelle tentative) ou nettoyés
    /// par le balayage une fois livrés.
    func dismissed() {
        item = nil
        logger.info("Feuille fermée — fichiers conservés")
    }

    /// Rapport d'un envoi tenté par l'utilisateur.
    ///
    /// - `imported == true`  : le moteur a importé au moins un fichier du
    ///   lot dans son propre temporaire. Aucune suppression ici : les
    ///   fichiers dont l'envoi est en cours (ou a échoué) restent
    ///   nécessaires ; ils ne partent qu'une fois leur transfert arrivé
    ///   à terme, via `pruneDeliveredBatches`.
    /// - `imported == false` : aucun fichier importé (aucun appareil,
    ///   copie en échec). Le lot reste intégralement stationné.
    func finish(imported: Bool) {
        if imported {
            logger.info("Envoi accepté — lot conservé jusqu'à livraison")
        } else {
            logger.warning("Envoi non consommé — fichiers conservés pour retry")
        }
        item = nil
    }

    // MARK: - Appartenance au dossier PendingShares de l'App Group

    /// Racine canonique `PendingShares` du conteneur App Group fourni.
    static func pendingSharesRoot(in containerURL: URL) -> URL {
        containerURL
            .appendingPathComponent("PendingShares", isDirectory: true)
            .standardizedFileURL
    }

    /// Vérifie que `url` est un fichier d'un lot de `PendingShares` :
    /// fichier régulier, fils direct d'un sous-dossier immédiat de la
    /// racine, nommé par un UUID (`<root>/<UUID>/<fichier>` — exactement
    /// deux composants). L'appartenance est établie sur le chemin canonique
    /// complet ; la seule présence de "/PendingShares/" dans une chaîne
    /// n'est jamais utilisée.
    ///
    /// - Parameters:
    ///   - url: l'URL à contrôler.
    ///   - rootPath: chemin canonique de la racine (cf.
    ///     `pendingSharesRoot(in:)`).
    /// - Returns: `(batchID, fileName)` si l'URL est bien un fichier de lot,
    ///   sinon `nil`.
    static func batchFileMatch(
        _ url: URL,
        rootPath: String
    ) -> (batchID: String, fileName: String)? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }

        let relative = path.dropFirst(rootPath.count + 1)
        let components = relative.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard components.count == 2 else { return nil }

        let batchID = String(components[0])
        guard isUUID(batchID) else { return nil }

        return (batchID, String(components[1]))
    }

    static func isUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Nettoyage (unique point de suppression)

    /// Supprime les fichiers de lot livrés, puis les répertoires de lot
    /// qui n'ont plus aucun fichier nécessaire.
    ///
    /// Règle de rétention, fichier par fichier : un fichier de lot n'est
    /// supprimé QUE s'il est livré, c'est-à-dire s'il apparaît comme
    /// `sourceFileURL` d'un transfert sortant terminé (`completed`) fourni
    /// dans `deliveredSourceURLs`. Tant que son transfert est en cours, a
    /// échoué ou a été annulé — ou qu'aucun transfert n'a jamais été créé
    /// (import en échec) — le fichier est conservé : c'est lui qu'une
    /// nouvelle tentative relirait. Un lot partiellement envoyé garde ainsi
    /// ses fichiers non livrés.
    ///
    /// Le répertoire d'un lot (manifeste inclus) n'est retiré qu'une fois
    /// qu'aucun fichier non livré ne s'y trouve : tout lot qui contient
    /// encore un fichier nécessaire ou un manifeste sans fichier livrable
    /// reste en place. La suppression d'un répertoire complet emporte donc
    /// aussi son `manifest.json` — le manifeste est un marqueur de
    /// complétion, pas une donnée utilisateur.
    ///
    /// Appelé UNIQUEMENT par le balayage des lots dans `AirBridgeApp`
    /// (premier rendu, `scenePhase.active`, observateur Darwin, après un
    /// `finish(imported: true)`). Jamais à la présentation, à la fermeture
    /// de la feuille, ni au démarrage d'un transfert.
    ///
    /// - Parameters:
    ///   - deliveredSourceURLs: fichiers déjà livrés (sourceFileURL des
    ///     transferts sortants `completed`, exposés par le Core).
    ///   - containerURL: conteneur App Group ; `nil` pour résoudre
    ///     `group.com.airbridge.shared` (paramétrable pour les tests).
    ///   - fileManager: paramétrable pour les tests.
    @discardableResult
    func pruneDeliveredBatches(
        deliveredSourceURLs: Set<URL>,
        containerURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> PendingSharePruneResult {
        var result = PendingSharePruneResult()

        let container = containerURL ?? fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        )
        guard let container else {
            logger.error("Purge impossible : conteneur App Group indisponible")
            return result
        }

        let rootPath = Self.pendingSharesRoot(in: container).path

        // Comparaison par chemin canonique (== sourceFileURL du Core).
        let deliveredPaths = Set(
            deliveredSourceURLs.map { $0.standardizedFileURL.path }
        )

        let batchDirectories: [URL]
        do {
            batchDirectories = try fileManager.contentsOfDirectory(
                at: Self.pendingSharesRoot(in: container),
                includingPropertiesForKeys: nil
            )
        } catch {
            logger.error("Purge impossible : \(error.localizedDescription, privacy: .public)")
            result.errors.append(
                PendingSharePruneError(url: Self.pendingSharesRoot(in: container), reason: error.localizedDescription)
            )
            return result
        }

        for batchDirectory in batchDirectories {
            // Ne traiter que les lots réellement créés par nos extensions
            // (dossier nommé par UUID). Tout le reste est ignoré.
            guard Self.isUUID(batchDirectory.lastPathComponent) else { continue }

            let batchFiles: [URL]
            do {
                batchFiles = try fileManager.contentsOfDirectory(
                    at: batchDirectory,
                    includingPropertiesForKeys: nil
                )
            } catch {
                logger.error("Lot illisible \(batchDirectory.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)")
                result.errors.append(
                    PendingSharePruneError(url: batchDirectory, reason: error.localizedDescription)
                )
                continue
            }

            // Fichiers du lot, manifeste exclu de la rétention par fichier.
            let filesToConsider = batchFiles.filter {
                $0.lastPathComponent != "manifest.json"
            }

            // Aucun fichier : rien ne dépend du répertoire (ou il n'abrite
            // qu'un manifeste). Il peut être retiré tel quel.
            guard !filesToConsider.isEmpty else {
                result.removedBatchDirectories += removeBatchDirectory(
                    batchDirectory,
                    fileManager: fileManager,
                    into: &result
                )
                continue
            }

            var hasLiveFiles = false
            for fileURL in filesToConsider {
                // Point 3 : appartenance réelle au dossier du lot, sur le
                // chemin canonique, jamais par substring.
                guard Self.batchFileMatch(
                    fileURL,
                    rootPath: rootPath
                ) != nil else {
                    logger.warning("Fichier hors structure de lot ignoré : \(fileURL.lastPathComponent, privacy: .public)")
                    hasLiveFiles = true
                    continue
                }

                let memberPath = fileURL.standardizedFileURL.path
                guard deliveredPaths.contains(memberPath) else {
                    hasLiveFiles = true
                    continue
                }

                if let error = removeFile(fileURL, fileManager: fileManager) {
                    hasLiveFiles = true
                    result.errors.append(error)
                } else {
                    result.deletedFiles += 1
                }
            }

            if !hasLiveFiles {
                result.removedBatchDirectories += removeBatchDirectory(
                    batchDirectory,
                    fileManager: fileManager,
                    into: &result
                )
            }
        }

        return result
    }

    /// Supprime un fichier de lot. `nil` en cas de succès.
    private func removeFile(
        _ url: URL,
        fileManager: FileManager
    ) -> PendingSharePruneError? {
        do {
            try fileManager.removeItem(at: url)
            logger.info("Fichier livré retiré du lot : \(url.lastPathComponent, privacy: .public)")
            return nil
        } catch {
            logger.error("Impossible de retirer \(url.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            return PendingSharePruneError(
                url: url,
                reason: error.localizedDescription
            )
        }
    }

    /// Supprime un répertoire de lot et tout son contenu, dont son
    /// manifeste. `1` en cas de succès, `0` sinon (erreur ajoutée à
    /// `result`).
    private func removeBatchDirectory(
        _ directory: URL,
        fileManager: FileManager,
        into result: inout PendingSharePruneResult
    ) -> Int {
        do {
            try fileManager.removeItem(at: directory)
            logger.info("Lot retiré (manifeste inclus) : \(directory.lastPathComponent, privacy: .public)")
            return 1
        } catch {
            logger.error("Impossible de retirer le lot \(directory.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            result.errors.append(
                PendingSharePruneError(
                    url: directory,
                    reason: error.localizedDescription
                )
            )
            return 0
        }
    }
}