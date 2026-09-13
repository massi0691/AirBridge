//
//  ShareDropHandler.swift
//  AirBridge
//
//  Helper pur pour la conversion de `[NSItemProvider]` (payload d'un
//  `.onDrop` SwiftUI) en `[URL]` exploitables par le Core.
//
//  Pourquoi ce fichier existe :
//  ----------------------
//  Avant la Phase 5, la conversion vivait directement dans le
//  `handleDrop(providers:viewModel:)` de `ShareView.swift` (iOS
//  uniquement). Avec l'arrivée du drag-and-drop global macOS
//  (Phase 5 — déposé n'importe où sur la fenêtre racine), la même
//  logique doit tourner sur l'écran `MainView` sans dupliquer le
//  parcours de `NSItemProvider`.
//
//  On extrait donc la partie pure (asynchrone, sans SwiftUI) dans
//  une fonction isolée, facile à tester en XCTest (les providers
//  peuvent être stubés) et réutilisable depuis n'importe quel
//  point d'entrée drop. Le partage de la logique garantit un
//  comportement strictement identique entre les deux surfaces
//  (iOS, macOS) : un fichier déposé sur l'écran Partage et un
//  fichier déposé sur la fenêtre racine passent exactement par
//  le même filtre.
//

import Foundation
internal import UniformTypeIdentifiers

/// Helpers drop-and-drop partagés entre les écrans iOS et macOS.
enum ShareDropHandler {

    /// Convertit une liste de `NSItemProvider` (typiquement reçue
    /// d'un `.onDrop(of: [.fileURL], …)`) en `[URL]` de fichiers
    /// locaux exploitables par `AirBridgeCore.importAndRequestItems`.
    ///
    /// Comportement :
    ///   - Conserve uniquement les providers conformes à
    ///     `UTType.fileURL` (les promesses non-fichier — texte,
    ///     images — sont ignorées).
    ///   - Pour chaque provider retenu, charge l'item via
    ///     `loadItem(forTypeIdentifier:)` (l'API historique qui
    ///     fonctionne sur iOS et macOS) puis reconstruit l'URL via
    ///     `URL(dataRepresentation:relativeTo:)` (le provider
    ///     livre une `Data` qui est la représentation binaire
    ///     d'une `URL.fileURL`).
    ///   - Filtre enfin sur `isFileURL` pour rejeter les éventuels
    ///     payloads non-fichier.
    ///   - L'ordre des providers est préservé (c'est l'ordre dans
    ///     lequel l'utilisateur a glissé les fichiers).
    ///
    /// La fonction est purement asynchrone : elle ne touche aucun
    /// état SwiftUI, aucun `MainActor`, aucune instance du Core.
    /// Elle est volontairement testable en isolation (les providers
    /// peuvent être construits à la main dans un XCTest).
    ///
    /// - Parameter providers: les `NSItemProvider` livrés par
    ///   SwiftUI lors d'un drop.
    /// - Returns: la liste des `URL` fichier extraites, dédupliquées
    ///   implicitement par le mécanisme de chargement asynchrone.
    static func loadFileURLs(
        from providers: [NSItemProvider]
    ) async -> [URL] {

        // On isole les providers conformes à `fileURL` en amont :
        // les autres (texte, images…) sont rejetés avant tout
        // appel asynchrone, ce qui évite de payer un `loadItem`
        // inutile et de bruiter les logs de diagnostic.
        let fileProviders = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(
                UTType.fileURL.identifier
            )
        }

        // Fan-out vers `withTaskGroup` : un sous-task par provider,
        // ce qui parallélise le chargement et reste strictement
        // ordonné à l'arrivée (on recolle l'index d'origine pour
        // préserver l'ordre d'arrivée des fichiers déposés).
        let collected = await withTaskGroup(
            of: (Int, [URL]).self,
            returning: [URL].self
        ) { group in

            for (index, provider) in fileProviders.enumerated() {
                group.addTask {
                    let urls = await Self.loadSingleFileURL(
                        from: provider
                    )
                    return (index, urls)
                }
            }

            // On accumule dans un dictionnaire indexé pour
            // préserver l'ordre sans dépendre de l'ordre de
            // complétion des tasks asynchrones.
            var indexed: [Int: [URL]] = [:]
            for await (index, urls) in group {
                indexed[index, default: []].append(contentsOf: urls)
            }

            // Recollement dans l'ordre d'origine, en aplatissant.
            return indexed
                .sorted { $0.key < $1.key }
                .flatMap { $0.value }
        }

        // Filtre de sécurité : `URL(dataRepresentation:)` peut en
        // théorie reconstruire une `URL` non-fichier si le payload
        // a été malformé. On re-valide pour rester cohérent avec
        // le contrat du Core (`importAndRequestItems` n'accepte
        // que des fichiers locaux).
        return collected.filter(\.isFileURL)
    }

    /// Charge un `NSItemProvider` unique et reconstruit l'`URL` qui
    /// s'y cache. La fonction est privée et `async` : elle est
    /// isolable par un `Task` depuis le `withTaskGroup` parent.
    ///
    /// - Parameter provider: un provider conforme à
    ///   `UTType.fileURL`.
    /// - Returns: 0 ou 1 `URL` (le provider peut livrer zéro item
    ///   si le chargement échoue silencieusement).
    private static func loadSingleFileURL(
        from provider: NSItemProvider
    ) async -> [URL] {

        await withCheckedContinuation { continuation in

            // L'API historique `loadItem(forTypeIdentifier:options:
            // completionHandler:)` est la seule garantie commune
            // iOS + macOS. Les variantes async/await
            // (`loadObject`) ne sont pas disponibles uniformément
            // sur les deux plateformes.
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in

                guard let data = item as? Data,
                      let url = URL(
                        dataRepresentation: data,
                        relativeTo: nil
                      ) else {

                    continuation.resume(returning: [])
                    return
                }

                continuation.resume(returning: [url])
            }
        }
    }
}
