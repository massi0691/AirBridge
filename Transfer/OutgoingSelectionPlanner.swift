//
//  OutgoingSelectionPlanner.swift
//  AirBridge
//

import Foundation

/// Lot prêt à être envoyé : un dossier choisi par l'utilisateur, ou les
/// fichiers isolés d'un même geste de sélection.
///
/// Le lot est la contrepartie émettrice de `ReceivedBatchContext` : ce qui
/// est décidé ici détermine le sous-dossier que le récepteur créera.
struct OutgoingSelectionPlan: Equatable, Sendable {

    /// Fichier du lot, avec sa place dans l'arborescence envoyée.
    struct File: Equatable, Sendable {

        let url: URL

        /// Chemin du fichier *à l'intérieur* du lot, séparé par « / ».
        ///
        /// Il ne répète pas le nom du dossier envoyé : celui-ci voyage
        /// dans `folderName`, et le récepteur compose les deux. Vaut
        /// `nil` pour un fichier isolé, qui n'a pas d'arborescence.
        let relativePath: String?
    }

    /// Nom annoncé pour le sous-dossier de réception.
    ///
    /// Renseigné pour un dossier envoyé, `nil` pour une sélection de
    /// fichiers : le récepteur nomme alors le dossier d'après sa propre
    /// date de réception.
    let folderName: String?

    /// Dossier choisi par l'utilisateur, `nil` pour des fichiers isolés.
    ///
    /// Conservé pour l'accès à portée de sécurité : le système accorde
    /// l'accès au dossier sélectionné, pas à chacun de ses fichiers. Lire
    /// un enfant suppose donc de tenir l'accès du dossier pendant toute la
    /// préparation du lot.
    let folderURL: URL?

    let files: [File]

    /// Un dossier forme toujours un lot, même s'il ne contient qu'un seul
    /// fichier : l'utilisateur a choisi un dossier, il doit en retrouver
    /// un à l'arrivée.
    ///
    /// Une sélection de fichiers, elle, ne forme un lot qu'à partir de
    /// deux, pour qu'un fichier isolé reste à plat dans le dossier de
    /// réception — comportement existant, inchangé.
    var announcesBatch: Bool {
        folderName != nil || files.count > 1
    }
}

/// Traduit une sélection de l'utilisateur — fichiers, dossiers, ou les
/// deux mélangés — en lots à envoyer.
///
/// La logique vit hors du cœur pour rester vérifiable avec de simples
/// dossiers temporaires, comme `ReceivedBatchLayout` côté réception.
///
/// Les URL viennent d'un sélecteur système ou d'un dépôt : elles peuvent
/// être à portée de sécurité, donc chaque accès disque est encadré. L'accès
/// n'est jamais exigé — il n'est pas accordé pour une URL ordinaire, ce qui
/// est le cas courant d'un fichier déjà dans le conteneur de l'app.
enum OutgoingSelectionPlanner {

    // MARK: - Planification

    /// Répartit une sélection en lots.
    ///
    /// Les fichiers isolés sont rassemblés en un seul lot, quel que soit
    /// leur nombre : les avoir choisis d'un même geste est précisément ce
    /// qui en fait une sélection. Chaque dossier forme au contraire son
    /// propre lot, donc son propre sous-dossier à l'arrivée.
    ///
    /// Un dossier vide ne produit aucun lot : il n'y a rien à envoyer, et
    /// annoncer un lot sans fichier laisserait un dossier vide chez le
    /// récepteur.
    static func plans(
        for urls: [URL],
        fileManager: FileManager = .default
    ) -> [OutgoingSelectionPlan] {

        var looseFileURLs: [URL] = []
        var folderURLs: [URL] = []

        for url in urls {

            if isDirectory(url, fileManager: fileManager) {
                folderURLs.append(url)

            } else {
                looseFileURLs.append(url)
            }
        }

        var plans: [OutgoingSelectionPlan] = []

        // Les fichiers isolés passent devant : ils sont immédiatement
        // envoyables, là où un dossier demande d'abord d'être parcouru.
        if !looseFileURLs.isEmpty {

            plans.append(
                OutgoingSelectionPlan(
                    folderName: nil,
                    folderURL: nil,
                    files: looseFileURLs.map {
                        OutgoingSelectionPlan.File(
                            url: $0,
                            relativePath: nil
                        )
                    }
                )
            )
        }

        for folderURL in folderURLs {

            let files = self.files(
                inFolderAt: folderURL,
                fileManager: fileManager
            )

            guard !files.isEmpty else {

                print(
                    "ℹ️ Dossier ignoré, aucun fichier à envoyer : \(folderURL.lastPathComponent)"
                )

                continue
            }

            plans.append(
                OutgoingSelectionPlan(
                    folderName: folderURL.lastPathComponent,
                    folderURL: folderURL,
                    files: files
                )
            )
        }

        return plans
    }

    // MARK: - Parcours

    /// Fichiers contenus dans un dossier, à tous les niveaux.
    ///
    /// Seuls les fichiers réguliers sont retenus : les dossiers
    /// intermédiaires n'ont pas à être envoyés, le récepteur les recrée à
    /// partir des chemins relatifs. Les paquets (`.app`, `.rtfd`…) sont
    /// traités comme des fichiers uniques plutôt que parcourus, pour
    /// arriver intacts.
    ///
    /// L'ordre est stable et alphabétique par chemin relatif : la file
    /// d'attente est FIFO, donc c'est aussi l'ordre d'envoi, et un ordre
    /// reproductible rend le transfert observable et testable.
    static func files(
        inFolderAt folderURL: URL,
        fileManager: FileManager = .default
    ) -> [OutgoingSelectionPlan.File] {

        let hasAccess =
            folderURL.startAccessingSecurityScopedResource()

        defer {
            if hasAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [
                .isRegularFileKey
            ],
            options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants
            ]
        ) else {

            print(
                "❌ Dossier illisible : \(folderURL.path)"
            )

            return []
        }

        var files: [OutgoingSelectionPlan.File] = []

        for case let itemURL as URL in enumerator {

            let isRegularFile = (
                try? itemURL.resourceValues(
                    forKeys: [.isRegularFileKey]
                )
            )?.isRegularFile

            guard isRegularFile == true else {
                continue
            }

            guard let relativePath = relativePath(
                of: itemURL,
                under: folderURL
            ) else {

                print(
                    "⚠️ Fichier hors du dossier choisi, ignoré : \(itemURL.path)"
                )

                continue
            }

            files.append(
                OutgoingSelectionPlan.File(
                    url: itemURL,
                    relativePath: relativePath
                )
            )
        }

        return files.sorted {
            ($0.relativePath ?? "") < ($1.relativePath ?? "")
        }
    }

    // MARK: - Chemins

    /// Chemin de `fileURL` relativement à `folderURL`, ou `nil` si le
    /// fichier n'est pas réellement dessous.
    ///
    /// Les deux côtés sont résolus avant comparaison : un dossier
    /// temporaire arrive volontiers en `/var/…` alors que le parcours
    /// renvoie `/private/var/…`, et comparer les formes brutes ferait
    /// échouer tous les chemins.
    ///
    /// Le résultat sert de `relativePath` sur le réseau. Il est malgré
    /// tout réassaini à la réception : un chemin construit ici est sûr,
    /// mais le récepteur ne peut pas savoir d'où vient celui qu'il reçoit.
    static func relativePath(
        of fileURL: URL,
        under folderURL: URL
    ) -> String? {

        let folderComponents = resolvedComponents(folderURL)
        let fileComponents = resolvedComponents(fileURL)

        guard fileComponents.count > folderComponents.count,
              Array(
                  fileComponents.prefix(folderComponents.count)
              ) == folderComponents else {
            return nil
        }

        return fileComponents
            .dropFirst(folderComponents.count)
            .joined(separator: "/")
    }

    // MARK: - Détails

    static func isDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {

        let hasAccess =
            url.startAccessingSecurityScopedResource()

        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let isDirectory = (
            try? url.resourceValues(
                forKeys: [.isDirectoryKey]
            )
        )?.isDirectory {
            return isDirectory
        }

        // Une URL dont les attributs sont illisibles est retombée sur le
        // système de fichiers : mieux vaut cette réponse que rien, un
        // dossier pris pour un fichier produirait une copie absurde.
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            return false
        }

        return isDirectory.boolValue
    }

    private static func resolvedComponents(
        _ url: URL
    ) -> [String] {

        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
    }
}
