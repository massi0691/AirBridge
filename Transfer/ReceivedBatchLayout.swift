//
//  ReceivedBatchLayout.swift
//  AirBridge
//

import Foundation

/// Contexte de réception d'un lot, transmis au stockage.
///
/// Sa seule présence signifie « ce fichier appartient à une sélection
/// multiple » : l'émetteur ne renseigne le lot que dans ce cas, donc le
/// stockage n'a aucun comptage à faire pour décider de créer un
/// sous-dossier.
struct ReceivedBatchContext: Sendable {

    let batchID: UUID

    /// Nom souhaité par l'émetteur, utilisé pour un dossier envoyé.
    /// `nil` pour une sélection de fichiers : le nom est alors dérivé de
    /// la date de réception.
    let folderName: String?

    /// Chemin à l'intérieur du lot, qui préserve l'arborescence d'un
    /// dossier envoyé. `nil` quand le fichier est à la racine du lot.
    let relativePath: String?

    init(
        batchID: UUID,
        folderName: String? = nil,
        relativePath: String? = nil
    ) {
        self.batchID = batchID
        self.folderName = folderName
        self.relativePath = relativePath
    }
}

/// Décide des noms et des chemins d'un lot reçu.
///
/// Le type est volontairement sans état ni dépendance plateforme : tout
/// ce qui touche au dossier de réception (sandbox iOS, ressource à portée
/// de sécurité macOS) reste dans `TransferStorage`, et cette logique-ci
/// reste vérifiable avec de simples dossiers temporaires.
///
/// Les noms traités viennent du réseau : ils sont considérés hostiles
/// jusqu'à preuve du contraire, d'où l'assainissement systématique.
enum ReceivedBatchLayout {

    /// Longueur maximale d'un composant, en octets UTF-8.
    ///
    /// La plupart des systèmes de fichiers refusent au-delà de 255 : un
    /// nom trop long ferait échouer l'écriture plutôt que produire une
    /// faille, mais autant le ramener à une taille écrivable.
    static let maximumComponentLength = 255

    // MARK: - Assainissement

    /// Ramène un nom reçu à un composant de chemin sûr, ou `nil` s'il
    /// n'en reste rien d'exploitable.
    ///
    /// Refuse ce qui permettrait de sortir du dossier de réception (`.`,
    /// `..`, séparateurs) et neutralise l'octet nul, qui tronquerait le
    /// chemin au niveau des appels système.
    static func sanitizedComponent(
        _ raw: String
    ) -> String? {

        let withoutNullBytes = raw.replacingOccurrences(
            of: "\0",
            with: ""
        )

        // Les deux séparateurs sont neutralisés : « \ » n'en est pas un
        // sur Apple, mais un pair d'une autre plateforme peut l'employer.
        let withoutSeparators = withoutNullBytes
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        let trimmed = withoutSeparators.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != ".." else {
            return nil
        }

        return truncated(trimmed)
    }

    /// Découpe un chemin relatif reçu en composants sûrs.
    ///
    /// Renvoie `nil` dès qu'un `..` apparaît : un chemin qui cherche à
    /// remonter est rejeté en entier plutôt que réparé, car « réparer »
    /// une tentative de traversée revient à en deviner l'intention.
    static func sanitizedRelativeComponents(
        _ raw: String?
    ) -> [String]? {

        guard let raw else {
            return nil
        }

        let withoutNullBytes = raw.replacingOccurrences(
            of: "\0",
            with: ""
        )

        let normalized = withoutNullBytes.replacingOccurrences(
            of: "\\",
            with: "/"
        )

        let rawComponents = normalized.split(
            separator: "/",
            omittingEmptySubsequences: true
        )

        var components: [String] = []

        for rawComponent in rawComponents {

            let component = String(rawComponent).trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            if component.isEmpty || component == "." {
                continue
            }

            guard component != ".." else {
                return nil
            }

            guard let safeComponent = sanitizedComponent(component) else {
                return nil
            }

            components.append(safeComponent)
        }

        return components.isEmpty ? nil : components
    }

    // MARK: - Nommage

    /// Nom du sous-dossier d'un lot reçu sans nom proposé.
    ///
    /// Le format est figé (`en_US_POSIX`, fuseau explicite) pour que le
    /// nom ne dépende ni de la langue ni des réglages de la machine, et
    /// que les tests restent stables.
    static func defaultFolderName(
        receivedAt: Date,
        timeZone: TimeZone = .current
    ) -> String {

        let formatter = DateFormatter()

        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"

        return "Réception_\(formatter.string(from: receivedAt))"
    }

    /// Nom de dossier retenu pour un lot : celui proposé par l'émetteur
    /// s'il survit à l'assainissement, sinon la date de réception.
    static func folderName(
        proposed: String?,
        receivedAt: Date,
        timeZone: TimeZone = .current
    ) -> String {

        if let proposed,
           let safeName = sanitizedComponent(proposed) {
            return safeName
        }

        return defaultFolderName(
            receivedAt: receivedAt,
            timeZone: timeZone
        )
    }

    // MARK: - Unicité

    /// URL libre pour `name` dans `directory`, en suffixant « 2 », « 3 »…
    /// tant que le nom est pris.
    ///
    /// L'extension est préservée : `photo.jpg` devient `photo 2.jpg` et
    /// non `photo.jpg 2`.
    static func uniqueURL(
        name: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {

        let originalURL = directory.appendingPathComponent(name)

        guard fileManager.fileExists(atPath: originalURL.path) else {
            return originalURL
        }

        let fileExtension = originalURL.pathExtension

        let baseName = originalURL
            .deletingPathExtension()
            .lastPathComponent

        var number = 2

        while true {

            let candidateName = fileExtension.isEmpty
                ? "\(baseName) \(number)"
                : "\(baseName) \(number).\(fileExtension)"

            let candidateURL = directory.appendingPathComponent(
                candidateName
            )

            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }

            number += 1
        }
    }

    // MARK: - Confinement

    /// Vérifie que `url` reste bien à l'intérieur de `directory`.
    ///
    /// Dernier rempart : l'assainissement devrait déjà l'avoir garanti,
    /// mais la vérification porte sur le chemin réellement calculé, donc
    /// elle couvre aussi une erreur de composition.
    ///
    /// Les liens symboliques sont résolus des deux côtés : sans cela, un
    /// lien posé dans le dossier de réception et pointant ailleurs
    /// garderait le préfixe attendu tout en faisant écrire dehors.
    static func isContained(
        _ url: URL,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {

        let resolvedDirectory = resolvedPath(
            of: directory,
            fileManager: fileManager
        )

        let resolvedURL = resolvedPath(
            of: url,
            fileManager: fileManager
        )

        let prefix = resolvedDirectory.hasSuffix("/")
            ? resolvedDirectory
            : resolvedDirectory + "/"

        return resolvedURL.hasPrefix(prefix)
    }

    /// Vrai si aucun maillon du chemin menant à `url` n'est un lien
    /// symbolique, en partant de `directory` sans l'inclure.
    ///
    /// `isContained` compare des chaînes de caractères ; il ne dit rien de
    /// ce que le système de fichiers fera de ces chaînes *ensuite*. Entre la
    /// vérification et l'écriture, un dossier intermédiaire peut être
    /// remplacé par un lien pointant ailleurs — et `rename`, sous
    /// `moveItem`, suit les liens des composants intermédiaires même s'il
    /// ne suit pas celui du dernier. Le fichier reçu atterrirait alors hors
    /// du dossier de réception.
    ///
    /// La descente exclut `directory` : cette racine est celle que
    /// l'utilisateur a désignée, et ce qu'il y a au-dessus ne nous regarde
    /// pas — `/tmp` est lui-même un lien sur macOS. Ce qu'on vérifie, c'est
    /// tout ce que la réception crée en dessous.
    ///
    /// La garantie reste partielle : il subsiste un intervalle, court, entre
    /// le dernier examen et l'écriture. Le fermer demanderait de descendre le
    /// chemin avec `openat(…, O_NOFOLLOW)` puis d'appeler `renameat` sur le
    /// descripteur obtenu, ce qui sort de ce que `FileManager` sait faire.
    static func containsNoSymbolicLink(
        pathTo url: URL,
        from directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {

        let rootPath = directory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path

        guard targetPath.hasPrefix(rootPath + "/") else {
            return false
        }

        let relativePath = targetPath.dropFirst(rootPath.count + 1)

        var current = directory.standardizedFileURL

        for component in relativePath.split(separator: "/") {

            current.appendPathComponent(String(component))

            // `attributesOfItem` ne suit pas le dernier lien du chemin
            // qu'on lui donne : c'est bien le maillon lui-même qu'on
            // examine, et non sa cible.
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: current.path
            ) else {

                // Ce maillon n'existe pas encore ; ceux d'en dessous non
                // plus. Il n'y a plus rien à suivre.
                return true
            }

            if attributes[.type] as? FileAttributeType
                == .typeSymbolicLink {
                return false
            }
        }

        return true
    }

    /// Chemin de `url` liens résolus, y compris quand la destination
    /// n'existe pas encore.
    ///
    /// `resolvingSymlinksInPath()` ne résout rien du tout dès que le
    /// dernier composant est absent — or c'est le cas courant ici, puisque
    /// l'on valide une destination avant de l'écrire. On remonte donc
    /// jusqu'au premier ancêtre présent, on le résout, puis on rattache le
    /// reste : ce reste n'existe pas, il ne peut donc pas être un lien.
    private static func resolvedPath(
        of url: URL,
        fileManager: FileManager
    ) -> String {

        var ancestor = url.standardizedFileURL
        var trailing: [String] = []

        // `attributesOfItem` ne suit pas le dernier lien : un lien cassé
        // compte donc comme présent, et sera résolu au lieu d'être pris
        // pour un simple nom.
        while
            (try? fileManager.attributesOfItem(
                atPath: ancestor.path
            )) == nil,
            ancestor.pathComponents.count > 1 {

            trailing.insert(
                ancestor.lastPathComponent,
                at: 0
            )

            ancestor = ancestor.deletingLastPathComponent()
        }

        var resolved = resolvedAncestor(
            ancestor,
            fileManager: fileManager
        )

        for component in trailing {
            resolved.appendPathComponent(component)
        }

        return resolved.standardizedFileURL.path
    }

    /// Suit la chaîne de liens d'un ancêtre existant, lien cassé compris.
    ///
    /// Un lien peut désigner une cible relative, donc chaque saut est
    /// résolu depuis le dossier du lien. Le nombre de sauts est borné : une
    /// boucle de liens ne doit pas figer la réception.
    private static func resolvedAncestor(
        _ url: URL,
        fileManager: FileManager
    ) -> URL {

        var current = url.standardizedFileURL
        var hops = 0

        while
            hops < 32,
            let destination = try? fileManager.destinationOfSymbolicLink(
                atPath: current.path
            ) {

            current = URL(
                fileURLWithPath: destination,
                relativeTo: current.deletingLastPathComponent()
            )
            .standardizedFileURL

            hops += 1
        }

        return current.resolvingSymlinksInPath()
    }

    // MARK: - Détails

    /// Tronque sur les octets UTF-8 sans couper un caractère en deux.
    private static func truncated(
        _ name: String
    ) -> String {

        guard name.utf8.count > maximumComponentLength else {
            return name
        }

        let fileExtension = (name as NSString).pathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"

        let budget = maximumComponentLength - suffix.utf8.count

        guard budget > 0 else {
            return String(name.prefix(1))
        }

        var base = (name as NSString)
            .deletingPathExtension as String

        while base.utf8.count > budget, !base.isEmpty {
            base.removeLast()
        }

        return base.isEmpty
            ? String(name.prefix(1))
            : base + suffix
    }
}
