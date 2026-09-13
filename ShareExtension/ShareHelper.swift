//
//  ShareHelper.swift
//  AirBridge
//
//  Helper centralisé pour le partage de fichiers depuis les extensions
//  (Share Extension iOS, Finder Service macOS, Drag & Drop).
//
//  Ce module fournit :
//  - Le parsing des URL schemes personnalisés
//  - L'extraction des fichiers depuis les providers
//  - La notification à l'application principale
//

import Foundation

#if os(macOS)
import AppKit
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - URL Scheme Constants

/// URL scheme utilisé pour communiquer avec l'application principale.
public enum AirBridgeURLScheme {
    public static let scheme = "airbridge"
    public static let receiveHost = "receive"
    public static let statusHost = "status"

    /// Crée une URL pour demander à l'application principale de
    /// recevoir des fichiers.
    /// - Parameter urls: URLs des fichiers à transférer.
    /// - Returns: URL formatée pour le scheme airbridge://
    public static func makeReceiveURL(urls: [URL]) -> URL? {
        let urlStrings = urls.map { $0.absoluteString }
        let joined = urlStrings.joined(separator: "|")
        guard let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(scheme)://\(receiveHost)?files=\(encoded)") else {
            return nil
        }
        return url
    }

    /// Crée une URL pour demander à l'application principale de
    /// recevoir un lot de fichiers déjà copiés dans le conteneur
    /// App Group (répertoire `PendingShares/<batchID>`).
    ///
    /// Contrairement aux URLs de fichiers encodées dans la query
    /// (fragiles : chemins sandbox privés, longueur), on ne transmet
    /// que l'identifiant du lot : l'application résout elle-même le
    /// répertoire correspondant dans son conteneur partagé.
    /// - Parameter batchID: UUID du lot écrit dans `PendingShares/`.
    /// - Returns: URL formatée pour le scheme airbridge://
    public static func makeReceiveURL(batchID: String) -> URL? {
        guard let encoded = batchID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(scheme)://\(receiveHost)?batch=\(encoded)") else {
            return nil
        }
        return url
    }

    /// Parse une URL airbridge:// pour extraire les fichiers.
    /// - Parameter url: URL à parser.
    /// - Returns: Liste des URLs de fichiers, ou nil si le format est invalide.
    public static func parseReceiveURL(_ url: URL) -> [URL]? {
        guard url.scheme == scheme,
              url.host == receiveHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let filesParam = components.queryItems?.first(where: { $0.name == "files" })?.value,
              let decoded = filesParam.removingPercentEncoding else {
            return nil
        }

        let urlStrings = decoded.split(separator: "|").map(String.init)
        return urlStrings.compactMap { URL(string: String($0)) }
    }
}

// MARK: - File Provider

/// Fournisseur de fichiers pour les extensions.
/// Gère l'extraction et le chargement des fichiers depuis les NSItemProvider.
public final class AirBridgeFileProvider {

    public enum FileProviderError: Error, LocalizedError {
        case noItemsFound
        case loadFailed(String)
        case unsupportedType
        case fileTooLarge(Int64)

        public var errorDescription: String? {
            switch self {
            case .noItemsFound:
                return "Aucun fichier à partager"
            case .loadFailed(let message):
                return "Impossible de charger le fichier : \(message)"
            case .unsupportedType:
                return "Type de fichier non supporté"
            case .fileTooLarge(let size):
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = .file
                return "Fichier trop volumineux : \(formatter.string(fromByteCount: size))"
            }
        }
    }

    /// Taille maximale acceptée pour un fichier (500 Mo).
    public static let maxFileSize: Int64 = 500 * 1024 * 1024

    #if os(iOS)
    /// Charge les fichiers depuis les items d'extension iOS.
    ///
    /// Les fichiers sont **copiés dans le répertoire du conteneur
    /// App Group** passé en paramètre (et non dans le temp privé de
    /// l'extension) afin que l'application principale, processus
    /// séparé, puisse y accéder via l'App Group.
    /// - Parameter items: Items d'extension (NSExtensionItem).
    /// - Parameter destinationDirectory: Répertoire (App Group) où
    ///   copier les fichiers reçus.
    /// - Returns: URLs (dans `destinationDirectory`) des fichiers chargés.
    public static func loadFiles(
        from items: [Any],
        destinationDirectory: URL
    ) async throws -> [URL] {
        var results: [URL] = []

        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        for item in items {
            if let extItem = item as? NSExtensionItem {
                for provider in extItem.attachments ?? [] {
                    if let url = try await loadFile(
                        from: provider,
                        into: destinationDirectory
                    ) {
                        results.append(url)
                    }
                }
            } else if let provider = item as? NSItemProvider {
                if let url = try await loadFile(
                    from: provider,
                    into: destinationDirectory
                ) {
                    results.append(url)
                }
            }
        }

        guard !results.isEmpty else {
            throw FileProviderError.noItemsFound
        }

        return results
    }

    /// Charge un fichier depuis un NSItemProvider.
    private static func loadFile(
        from provider: NSItemProvider,
        into directory: URL
    ) async throws -> URL? {
        // Essayer d'abord les types fichiers
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                    if let error = error {
                        continuation.resume(throwing: FileProviderError.loadFailed(error.localizedDescription))
                        return
                    }

                    guard let url = url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Copier vers le conteneur App Group, avec un nom
                    // unique pour éviter les collisions entre lots.
                    do {
                        let destURL = uniqueDestination(
                            in: directory,
                            named: url.lastPathComponent
                        )

                        // Supprimer l'existant si présent
                        try? FileManager.default.removeItem(at: destURL)
                        try FileManager.default.copyItem(at: url, to: destURL)

                        continuation.resume(returning: destURL)
                    } catch {
                        continuation.resume(throwing: FileProviderError.loadFailed(error.localizedDescription))
                    }
                }
            }
        }

        // Essayer les types images / vidéo. On privilégie la
        // représentation FICHIER (simple copie, pas de décodage complet
        // en mémoire — photos et vidéos volumineuses sortent vite du
        // budget mémoire d'une extension et tueraient le lot à mi-copie).
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return try await loadAsFileOrData(
                from: provider,
                typeIdentifier: UTType.image.identifier,
                into: directory
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return try await loadAsFileOrData(
                from: provider,
                typeIdentifier: UTType.movie.identifier,
                into: directory
            )
        }

        return nil
    }

    /// Charge un fichier image/vidéo en préférant la représentation
    /// fichier, avec repli sur le chargement par data. Taille vérifiée
    /// avant copie sur les deux chemins.
    private static func loadAsFileOrData(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directory: URL
    ) async throws -> URL? {
        if let fileURL = try await loadFileRepresentation(
            from: provider,
            typeIdentifier: typeIdentifier,
            into: directory
        ) {
            return fileURL
        }
        // Repli : certains providers exposent un `public.image` sans
        // représentation fichier exploitable (nil sans erreur).
        return try await loadAsData(
            from: provider,
            typeIdentifier: typeIdentifier,
            into: directory
        )
    }

    /// Tente `loadFileRepresentation` (copie de la ressource sans
    /// décodage en mémoire). `nil` si le provider n'offre pas de fichier
    /// pour ce type.
    private static func loadFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directory: URL
    ) async throws -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let url, url.isFileURL {
                    do {
                        // Vérifier la taille avant de copier (le budget
                        // 500 Mo de `loadAsData` s'applique ici aussi).
                        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                           let size = values.fileSize,
                           Int64(size) > maxFileSize {
                            continuation.resume(throwing: FileProviderError.fileTooLarge(Int64(size)))
                            return
                        }
                        let destURL = uniqueDestination(
                            in: directory,
                            named: url.lastPathComponent
                        )
                        try FileManager.default.copyItem(at: url, to: destURL)
                        continuation.resume(returning: destURL)
                    } catch {
                        continuation.resume(throwing: FileProviderError.loadFailed(error.localizedDescription))
                    }
                } else if let error = error {
                    continuation.resume(throwing: FileProviderError.loadFailed(error.localizedDescription))
                } else {
                    // Pas de représentation fichier : repli sur les data.
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Charge un item comme data et l'enregistre dans le conteneur App Group.
    private static func loadAsData(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directory: URL
    ) async throws -> URL? {
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error = error {
                    continuation.resume(throwing: FileProviderError.loadFailed(error.localizedDescription))
                    return
                }

                guard let data = data else {
                    continuation.resume(returning: nil)
                    return
                }

                // Vérifier la taille
                let size = Int64(data.count)
                guard size <= maxFileSize else {
                    continuation.resume(throwing: FileProviderError.fileTooLarge(size))
                    return
                }

                // Déterminer l'extension
                let ext = Self.extensionForType(typeIdentifier)

                do {
                    let filename = "\(UUID().uuidString).\(ext)"
                    let destURL = directory.appendingPathComponent(filename)

                    try data.write(to: destURL)

                    continuation.resume(returning: destURL)
                } catch {
                    continuation.resume(throwing: FileProviderError.loadFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Génère une URL de destination unique pour un fichier, en
    /// préfixant le nom par un UUID court si nécessaire pour éviter
    /// les collisions entre deux lots contenant le même nom.
    private static func uniqueDestination(
        in directory: URL,
        named name: String
    ) -> URL {
        let fileManager = FileManager.default
        let base = name.isEmpty ? "fichier" : name
        var candidate = directory.appendingPathComponent(base)

        // Si le nom est libre, on le garde tel quel (le plus lisible).
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        // Sinon on préfixe par un UUID court.
        let uuid = UUID().uuidString.prefix(8)
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        let newName = ext.isEmpty
            ? "\(uuid)-\(stem)"
            : "\(uuid)-\(stem).\(ext)"
        candidate = directory.appendingPathComponent(newName)
        return candidate
    }

    /// Retourne l'extension de fichier pour un type UTType.
    private static func extensionForType(_ typeIdentifier: String) -> String {
        switch typeIdentifier {
        case UTType.image.identifier:
            return "jpg"
        case UTType.movie.identifier:
            return "mov"
        case UTType.pdf.identifier:
            return "pdf"
        default:
            return "dat"
        }
    }
    #endif

    #if os(macOS)
    /// Charge les fichiers depuis un NSPasteboard (macOS).
    /// - Parameter pasteboard: Le pasteboard contenant les fichiers.
    /// - Returns: URLs des fichiers.
    public static func loadFiles(from pasteboard: NSPasteboard) throws -> [URL] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            throw FileProviderError.noItemsFound
        }

        let fileURLs = urls.filter { $0.isFileURL }

        guard !fileURLs.isEmpty else {
            throw FileProviderError.noItemsFound
        }

        return fileURLs
    }
    #endif
}

// MARK: - App Launcher

/// Mécanisme pour lancer l'application principale et lui transmettre des fichiers.
public final class AirBridgeAppLauncher {

    #if os(iOS)
    /// Ouvre l'application principale avec les fichiers à partager.
    /// - Parameter urls: URLs des fichiers.
    /// - Parameter extensionContext: Le contexte d'extension pour ouvrir l'URL.
    /// - Returns: true si l'ouverture a réussi.
    @discardableResult
    public static func openMainApp(with urls: [URL], extensionContext: NSExtensionContext) -> Bool {
        guard let appURL = AirBridgeURLScheme.makeReceiveURL(urls: urls) else {
            return false
        }

        // Dans une app extension, on utilise le extensionContext pour ouvrir l'URL
        extensionContext.open(appURL, completionHandler: nil)
        return true
    }
    #endif

    #if os(macOS)
    /// Ouvre l'application principale avec les fichiers à partager.
    /// - Parameter urls: URLs des fichiers.
    public static func openMainApp(with urls: [URL]) {
        guard let appURL = AirBridgeURLScheme.makeReceiveURL(urls: urls) else {
            return
        }

        NSWorkspace.shared.open(appURL)
    }
    #endif
}

// MARK: - Notification Names

#if canImport(Foundation)
extension Notification.Name {
    /// Notification envoyée quand des fichiers sont reçus depuis
    /// une extension ou un service externe.
    public static let airbridgeFilesReceived = Notification.Name("com.airbridge.filesReceived")

    /// Notification envoyée quand l'état de connexion change.
    public static let airbridgeConnectionStateChanged = Notification.Name("com.airbridge.connectionStateChanged")
}
#endif