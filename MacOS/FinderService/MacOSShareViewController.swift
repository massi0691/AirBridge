//
//  MacOSShareViewController.swift
//  AirBridge
//
//  Fenêtre de partage macOS (menu Partager du Finder, com.apple.share-services).
//

#if os(macOS)

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Point d'entrée de l'extension de partage macOS.
///
/// Le Finder instancie cette classe via `NSExtensionPrincipalClass` et
/// appelle `beginRequest(with:)` quand l'utilisateur choisit AirBridge
/// dans le menu Partager. Le handoff est identique au Share Extension iOS :
///   1. Les fichiers reçus sont **copiés** dans
///      `group.com.airbridge.shared/PendingShares/<batchID>/` (l'app,
///      processus séparé, ne peut pas lire le temp privé de l'extension).
///   2. Un manifeste JSON est écrit à côté (noms + URLs), de façon
///      ATOMIQUE : `manifest.json.tmp` écrit puis `moveItem`, et
///      uniquement une fois la copie complète. L'app ne consomme jamais
///      un lot sans manifeste — la présence du manifeste = copie finie.
///   3. La notification Darwin `com.airbridge.share.pending` est postée.
///   4. L'app est ouverte avec `airbridge://receive?batch=<batchID>` ;
///      elle résout le répertoire dans son propre conteneur.
///
/// L'extension ne complète JAMAIS tant que les fichiers ne sont pas
/// stationnés : le bouton « Terminer » (et la fermeture d'état prêt)
/// n'apparaît qu'après la publication complète du lot. En cas d'échec
/// ou d'annulation, un état d'erreur visible est affiché — jamais une
/// complétion « succès » sur un lot partiel.
@objc(MacOSShareViewController)
final class MacOSShareViewController: NSViewController {

    /// Conteneur App Group partagé avec l'application principale.
    private let appGroupIdentifier = "group.com.airbridge.shared"

    /// Verrou : `beginRequest(with:)` peut être rappelé par le système sur
    /// un même cycle de vie ; on ne traite qu'une seule demande.
    private var hasHandledRequest = false

    /// Contexte de l'extension, mémorisé pour la complétion différée
    /// (sur « Terminer », et non immédiatement après la copie). Nommé
    /// `shareExtensionContext` pour ne pas entrer en collision avec un
    /// éventuel `extensionContext` exposé par la vue hôte.
    private var shareExtensionContext: NSExtensionContext?

    /// Tâche de handoff, tenue pour l'annulation.
    private var handoffTask: Task<Void, Never>?

    /// Répertoire du lot en cours, pour le nettoyage sur annulation.
    private var currentBatchDirectory: URL?

    /// Vrai une fois le lot publié (copie + manifeste) : « Fermer »/
    /// « Terminer » = complétion de succès, pas d'annulation.
    private var isReady = false

    // MARK: - UI (AppKit pur)

    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField()
    private let doneButton = NSButton()
    private let cancelButton = NSButton()

    override func loadView() {
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 240)
        )

        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.alignment = .center
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.drawsBackground = false
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = .labelColor

        doneButton.title = "Terminer"
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.isHidden = true
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "Annuler"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, statusLabel, doneButton, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(
                greaterThanOrEqualTo: container.topAnchor,
                constant: 20
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor,
                constant: -20
            ),
            statusLabel.leadingAnchor.constraint(
                equalTo: stack.leadingAnchor
            ),
            statusLabel.trailingAnchor.constraint(
                equalTo: stack.trailingAnchor
            ),
        ])

        view = container
    }

    /// Point d'entrée appelé par le système. On démarre le handoff (copie →
    /// manifeste atomique → Darwin → ouverture de l'app) sur le MainActor ;
    /// la complétion est différée sur « Terminer » / « Fermer ».
    override func beginRequest(with context: NSExtensionContext) {
        guard !hasHandledRequest else { return }
        hasHandledRequest = true
        shareExtensionContext = context

        statusLabel.stringValue = "Préparation…"
        statusLabel.textColor = .labelColor
        // Première apparition : le bouton peut être flottant entre deux
        // partages du même cycle de vie — on réinitialise l'état.
        doneButton.isHidden = true
        cancelButton.title = "Annuler"
        spinner.startAnimation(nil)

        handoffTask = Task { @MainActor in
            await performHandoff(context: context)
        }
    }

    // MARK: - Handoff

    /// Copie les fichiers reçus dans l'App Group, écrit le manifeste de
    /// façon atomique, poste la notification Darwin puis ouvre l'app.
    /// Ne complète JAMAIS ici : seul `doneTapped` / la fermeture d'état
    /// prêt terminent l'extension, une fois le lot stationné.
    @MainActor
    private func performHandoff(context: NSExtensionContext) async {
        let batchID = UUID().uuidString
        print("🔁 Finder Share — début du handoff, lot \(batchID)")

        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            showErrorState("Conteneur partagé indisponible.")
            return
        }

        let batchDirectory = containerURL
            .appendingPathComponent("PendingShares", isDirectory: true)
            .appendingPathComponent(batchID, isDirectory: true)
        currentBatchDirectory = batchDirectory

        do {
            try FileManager.default.createDirectory(
                at: batchDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            showErrorState("Impossible de créer le dossier du lot : \(error.localizedDescription)")
            return
        }

        // 1. Extraction et copie des fichiers sélectionnés dans le Finder.
        var copiedURLs: [URL] = []
        let extensionItems = context.inputItems as? [NSExtensionItem] ?? []

        for item in extensionItems {
            for provider in item.attachments ?? [] {
                guard !Task.isCancelled else {
                    cleanupIncompleteBatch()
                    finishWithCancel(detail: "Partage annulé")
                    return
                }

                // `loadFileURL` peut échouer (throw) si le provider refuse
                // de produire un fichier : un lot partiel est un échec —
                // on le signale, jamais une complétion « succès ». Un
                // provider non conforme (nil) est simplement ignoré.
                let sourceURL: URL?
                do {
                    sourceURL = try await loadFileURL(from: provider)
                } catch {
                    cleanupIncompleteBatch()
                    showErrorState("Impossible de lire le fichier sélectionné.")
                    return
                }
                guard let sourceURL else { continue }

                do {
                    let destURL = try await copyToBatchDirectory(
                        sourceURL,
                        in: batchDirectory
                    )
                    copiedURLs.append(destURL)
                    print("✅ Copié : \(destURL.lastPathComponent)")
                } catch {
                    cleanupIncompleteBatch()
                    showErrorState("Échec de la copie de \(sourceURL.lastPathComponent).")
                    return
                }
            }
        }

        guard !copiedURLs.isEmpty else {
            cleanupIncompleteBatch()
            showErrorState("Aucun fichier à partager.")
            return
        }

        // 2. Manifeste ATOMIQUE — écrit seulement une fois la copie
        //    complète (`manifest.json.tmp` puis `moveItem`).
        do {
            let data = try manifestData(batchID: batchID, urls: copiedURLs)
            let tmpURL = batchDirectory
                .appendingPathComponent("manifest.json.tmp")
            let manifestURL = batchDirectory
                .appendingPathComponent("manifest.json")
            try data.write(to: tmpURL, options: .atomic)
            try FileManager.default.removeItem(at: manifestURL)
            try FileManager.default.moveItem(at: tmpURL, to: manifestURL)
        } catch {
            cleanupIncompleteBatch()
            showErrorState("Impossible d'écrire le manifeste du lot.")
            return
        }
        print("✅ Manifeste écrit : \(batchID) — \(copiedURLs.count) fichier(s)")

        // 3. Notification Darwin (filet de sécurité si l'URL scheme échoue).
        postPendingNotification()

        // 4. Ouverture de l'app avec l'identifiant du lot uniquement.
        var opened = false
        if let appURL = AirBridgeURLScheme.makeReceiveURL(batchID: batchID) {
            opened = NSWorkspace.shared.open(appURL)
        }
        print("📲 Ouverture d'AirBridge : \(opened ? "ok" : "refusée")")

        showReadyState(count: copiedURLs.count)
    }

    // MARK: - États de la feuille

    private func showReadyState(count: Int) {
        isReady = true
        spinner.stopAnimation(nil)
        statusLabel.textColor = .labelColor
        statusLabel.stringValue = count == 1
            ? "1 fichier prêt — ouverture d'AirBridge…"
            : "\(count) fichiers prêts — ouverture d'AirBridge…"
        doneButton.isHidden = false
        cancelButton.title = "Fermer"
    }

    private func showErrorState(_ message: String) {
        isReady = false
        spinner.stopAnimation(nil)
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = message
        doneButton.isHidden = true
        cancelButton.title = "Fermer"
    }

    // MARK: - Actions

    /// « Terminer » (état prêt) : le lot est stationné, on termine en
    /// succès.
    @objc private func doneTapped() {
        finishWithSuccess()
    }

    /// « Annuler » (handoff en cours) : arrêt du Task + nettoyage du lot
    /// incomplet + `cancelRequest`. « Fermer » (état prêt ou erreur) :
    /// après publication le lot reste exploitable par l'app — on ferme
    /// sans supprimer ; en erreur, rien n'a été publié.
    @objc private func cancelTapped() {
        if isReady {
            finishWithSuccess()
            return
        }
        handoffTask?.cancel()
        cleanupIncompleteBatch()
        finishWithCancel(detail: "Partage fermé")
    }

    private func finishWithSuccess() {
        spinner.stopAnimation(nil)
        let context = shareExtensionContext
        Task { @MainActor in
            context?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func finishWithCancel(detail: String) {
        spinner.stopAnimation(nil)
        let context = shareExtensionContext
        Task { @MainActor in
            context?.cancelRequest(withError: NSError(
                domain: "MacOSShareViewController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail]
            ))
        }
    }

    /// Retire le lot en cours — utilisé UNIQUEMENT pour un lot incomplet
    /// (annulation ou échec de copie) : rien n'a été publié, il n'est donc
    /// jamais consommable par l'app. Les fichiers d'origine du Finder
    /// restent intacts.
    private func cleanupIncompleteBatch() {
        guard let batchDirectory = currentBatchDirectory else { return }
        do {
            try FileManager.default.removeItem(at: batchDirectory)
            print("🗑 Lot incomplet retiré : \(batchDirectory.lastPathComponent)")
        } catch {
            print("⚠️ Nettoyage du lot incomplet impossible : \(error.localizedDescription)")
        }
        currentBatchDirectory = nil
    }

    // MARK: - Extraction

    /// Demande au provider la représentation fichier (NSURL) de l'élément.
    /// - Returns: URL source, ou nil si le provider ne fournit pas de
    ///   fichier compatible.
    private func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL, url.isFileURL {
                    continuation.resume(returning: url)
                } else {
                    // Certains providers remontent des données brutes au
                    // lieu d'une URL : sans nom de fichier fiable on les
                    // ignore (l'extraction échouera si aucun fichier).
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Copie la ressource security-scoped vers le répertoire du lot, avec
    /// un nom unique en cas de collision.
    private func copyToBatchDirectory(_ source: URL, in directory: URL) async throws -> URL {
        let destURL = uniqueDestination(in: directory, named: source.lastPathComponent)

        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Copie coordonnée : la ressource peut être détenue par une
            // autre app (iCloud, application Documents…). La lecture
            // coordonnée garantit une copie cohérente du fichier.
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            // La continuation ne doit être reprise qu'UNE seule fois : le
            // bloc accesseur et `if let coordinationError` sont deux chemins
            // de reprise possibles — le garde `didResume` en garantit l'unicité.
            var didResume = false

            coordinator.coordinate(
                readingItemAt: source,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.copyItem(at: coordinatedURL, to: destURL)
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: destURL)
                } catch {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }

            if let coordinationError, !didResume {
                didResume = true
                continuation.resume(throwing: coordinationError)
            }
        }
    }

    /// Génère une destination unique : si le nom existe déjà, on préfixe
    /// avec un compteur ("1_toto.txt", "2_toto.txt", …).
    private func uniqueDestination(in directory: URL, named name: String) -> URL {
        let fileManager = FileManager.default
        let base = name.isEmpty ? "fichier" : name
        var candidate = directory.appendingPathComponent(base)

        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var counter = 1
        repeat {
            let newName = ext.isEmpty
                ? "\(counter)_\(stem)"
                : "\(counter)_\(stem).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Contenu du manifeste du lot (noms + URLs réelles), forme identique
    /// au Share Extension iOS.
    private func manifestData(batchID: String, urls: [URL]) throws -> Data {
        let files = urls.map { url -> [String: Any] in
            [
                "name": url.lastPathComponent,
                "url": url.absoluteString
            ]
        }
        let manifest: [String: Any] = [
            "batchID": batchID,
            "files": files,
            "count": urls.count,
            "timestamp": Date().timeIntervalSince1970
        ]
        return try JSONSerialization.data(withJSONObject: manifest)
    }

    /// Poste la notification Darwin consommée par `PendingShareObserver`
    /// dans l'application principale (warm launch iOS / macOS).
    private func postPendingNotification() {
        let notificationName = "com.airbridge.share.pending" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName),
            nil,
            nil,
            true
        )
    }
}

#endif