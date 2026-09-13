import UIKit
import UniformTypeIdentifiers

/// Share Extension controller for iOS.
/// Receives files from the system share sheet, copies them into the
/// shared App Group container and forwards them to the main AirBridge app.
///
/// Handoff (option A retenue — ouverture MANUELLE de l'app) :
///   1. Les fichiers reçus sont **copiés** dans
///      `group.com.airbridge.shared/PendingShares/<batchID>/` (et non
///      dans le temp privé de l'extension : l'app, processus séparé, ne
///      pourrait pas les lire).
///   2. Un manifeste JSON est écrit à côté (noms + URLs), de façon
///      ATOMIQUE : `manifest.json.tmp` écrit puis `moveItem`, et
///      uniquement une fois la copie complète. L'app ne consomme jamais
///      un lot sans manifeste — la présence du manifeste = copie finie.
///   3. La notification Darwin `com.airbridge.share.pending` est postée
///      (filet de sécurité : le sweep de l'app détectera le lot même si
///      l'utilisateur n'ouvre pas l'app immédiatement).
///   4. « Fichiers prêts. Ouvrez AirBridge pour choisir un appareil et
///      envoyer. » — aucune API publique ne permet à une Share Extension
///      d'ouvrir son app hôte, donc PAS d'ouverture automatique : le bouton
///      « Terminer » complète l'extension, le lot reste dans l'App Group
///      jusqu'à ce que l'app soit ouverte manuellement et le présente.
///
/// L'extension ne complète JAMAIS tant que les fichiers ne sont pas
/// stationnés : « Terminer » / « Fermer » (état prêt) n'existe
/// qu'après la publication complète du lot. En cas d'échec ou
/// d'annulation pendant la préparation, un état d'erreur visible est
/// affiché — jamais une complétion « succès » sur un lot partiel.
@objc(ShareViewController)
class ShareViewController: UIViewController {

    // MARK: - UI Components

    private lazy var iconImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.image = UIImage(systemName: "airplane.circle.fill")
        imageView.tintColor = .systemBlue
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.text = "AirBridge"
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Préparation..."
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    /// « Terminer » — visible UNIQUEMENT après publication complète du
    /// lot (copie + manifeste atomique). Complète l'extension en succès ;
    /// le lot reste stationné dans l'App Group pour l'app.
    private lazy var doneButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Terminer", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(doneAction), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    private lazy var cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Annuler", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancelAction), for: .touchUpInside)
        return button
    }()

    // MARK: - Properties

    private let appGroupIdentifier = "group.com.airbridge.shared"
    private var currentBatchID: String?

    /// Répertoire App Group du lot en cours, pour le nettoyage sur
    /// annulation / échec.
    private var currentBatchDirectory: URL?

    /// Tâche de copie, tenue pour l'annulation.
    private var handoffTask: Task<Void, Never>?

    /// Vrai une fois le lot publié (copie + manifeste atomique) :
    /// « Terminer » / « Fermer » = complétion de succès, pas d'annulation
    /// ni de suppression.
    private var isReady = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Taille du popover iPad ; sur iPhone la feuille système occupe
        // tout l'écran disponible.
        preferredContentSize = CGSize(width: 540, height: 380)
        setupUI()
        extractSharedItems()
    }

    // MARK: - UI Setup

    /// Layout plein écran : le fond clair et la présentation en feuille
    /// sont déjà fournis par le système. On n'ajoute PAS de voile sombre
    /// ni de carte centrée (c'est ce qui causait l'affichage "60 % au
    /// centre").
    private func setupUI() {
        view.backgroundColor = .systemBackground

        view.addSubview(iconImageView)
        view.addSubview(titleLabel)
        view.addSubview(activityIndicator)
        view.addSubview(statusLabel)
        view.addSubview(doneButton)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            // En-tête (haut de l'écran, safe area).
            iconImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            iconImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 64),
            iconImageView.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Zone centrale (statut).
            activityIndicator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Actions (bas de l'écran, safe area).
            doneButton.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: 240),
            doneButton.heightAnchor.constraint(equalToConstant: 50),

            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        activityIndicator.startAnimating()
    }

    // MARK: - Item Extraction

    private func extractSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("Aucun élément à partager")
            return
        }

        // Les fichiers sont copiés dans le conteneur App Group pour que
        // l'application principale (processus séparé) puisse les lire.
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            showError("Conteneur partagé indisponible")
            return
        }

        // Progression visible : l'indicateur tourne pendant toute la
        // préparation, avec le nombre attendu de fichiers.
        let expectedCount = extensionItems.reduce(into: 0) { count, item in
            count += item.attachments?.count ?? 0
        }
        if expectedCount == 1 {
            updateStatus("Préparation de 1 fichier…")
        } else {
            updateStatus("Préparation de \(expectedCount) fichiers…")
        }

        let batchID = UUID().uuidString
        currentBatchID = batchID
        let batchDirectory = containerURL
            .appendingPathComponent("PendingShares", isDirectory: true)
            .appendingPathComponent(batchID, isDirectory: true)
        currentBatchDirectory = batchDirectory

        handoffTask = Task {
            do {
                let urls = try await AirBridgeFileProvider.loadFiles(
                    from: extensionItems,
                    destinationDirectory: batchDirectory
                )
                // Annulation pendant la copie : le lot est partiel (pas de
                // manifeste) → on le retire, on ne publie rien. Le retry
                // a déjà nettoyé, `removeItem` est idempotent.
                guard !Task.isCancelled else {
                    cleanupCurrentBatch()
                    return
                }
                await MainActor.run {
                    handleSharedURLs(urls, batchID: batchID, batchDirectory: batchDirectory)
                }
            } catch {
                await MainActor.run {
                    // Copie interrompue : lot partiel sans manifeste → on
                    // le retire avant d'afficher l'erreur (jamais un lot
                    // orphelin dans l'App Group).
                    cleanupCurrentBatch()
                    showError(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Batch Publication

    /// Publie le lot : manifeste ATOMIQUE (copie requise terminée), puis
    /// notification Darwin. N'affiche l'état « prêt » que si la
    /// publication est COMPLÈTE.
    private func handleSharedURLs(_ urls: [URL], batchID: String, batchDirectory: URL) {
        guard !urls.isEmpty else {
            cleanupCurrentBatch()
            showError("Aucun fichier valide à partager")
            return
        }

        // Manifeste ATOMIQUE — nb : moveItem sur un manifeste existant
        // échouerait, donc suppression best-effort d'un éventuel reliquat.
        guard publishBatchManifest(batchID: batchID, urls: urls, in: batchDirectory) else {
            cleanupCurrentBatch()
            showError("Échec de la préparation des fichiers")
            return
        }
        print("✅ Manifeste écrit : \(batchID) — \(urls.count) fichier(s)")

        // Filet de sécurité (warm launch) : le sweep de l'app détectera
        // le lot même si l'utilisateur n'ouvre pas l'app tout de suite.
        postPendingNotification()

        // Ouverture MANUELLE de l'app : aucune API publique d'une Share
        // Extension ne permet d'ouvrir son app hôte, on ne tente rien.
        isReady = true
        activityIndicator.stopAnimating()
        statusLabel.textColor = .secondaryLabel
        updateStatus("Fichiers prêts. Ouvrez AirBridge pour choisir un appareil et envoyer.")
        cancelButton.setTitle("Fermer", for: .normal)
        doneButton.isHidden = false
    }

    /// Écrit le manifeste du lot (noms + URLs réelles) de façon ATOMIQUE
    /// (`manifest.json.tmp` puis `moveItem`), à côté des fichiers déjà
    /// copiés. La présence du manifeste est le marqueur de complétude
    /// consommé par `pendingBatchURLs` : jamais de lot incomplet lisible.
    /// - Returns: `true` si le manifeste a été publié.
    private func publishBatchManifest(batchID: String, urls: [URL], in batchDirectory: URL) -> Bool {
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

        do {
            let data = try JSONSerialization.data(withJSONObject: manifest)
            let tmpURL = batchDirectory.appendingPathComponent("manifest.json.tmp")
            let manifestURL = batchDirectory.appendingPathComponent("manifest.json")
            try data.write(to: tmpURL, options: .atomic)
            // Reliquat éventuel (re-publication) : suppression best-effort.
            try? FileManager.default.removeItem(at: manifestURL)
            try FileManager.default.moveItem(at: tmpURL, to: manifestURL)
            return true
        } catch {
            print("⚠️ Écriture du manifeste impossible : \(error.localizedDescription)")
            return false
        }
    }

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

    // MARK: - Status Updates

    private func updateStatus(_ message: String) {
        statusLabel.text = message
    }

    private func showError(_ message: String) {
        isReady = false
        activityIndicator.stopAnimating()
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        doneButton.isHidden = true
        cancelButton.setTitle("Fermer", for: .normal)
    }

    // MARK: - Actions

    /// « Terminer » / « Fermer » (état prêt) : le lot est stationné, on
    /// complète en succès — les fichiers restent dans l'App Group pour
    /// l'app. Jamais de suppression ici.
    @objc private func doneAction() {
        completeWithSuccess()
    }

    /// « Annuler » (préparation en cours) : arrêt de la copie + retrait du
    /// lot partiel (aucun manifeste publié) + `cancelRequest`. « Fermer »
    /// (état prêt ou erreur) : en prêt, le lot est publié → complétion de
    /// succès ; en erreur, rien n'a été publié → `cancelRequest`.
    @objc private func cancelAction() {
        if isReady {
            completeWithSuccess()
            return
        }
        handoffTask?.cancel()
        cleanupCurrentBatch()
        completeWithCancel()
    }

    // MARK: - Cleanup

    /// Retire le lot en cours de l'App Group (fichiers + manifeste).
    /// Utilisé UNIQUEMENT pour un lot absent (annulation ou échec de
    /// préparation) : rien n'a été publié, il n'est jamais consommable
    /// par l'app. Les fichiers d'origine du share sheet restent intacts.
    private func cleanupCurrentBatch() {
        guard let batchID = currentBatchID,
              let batchDirectory = currentBatchDirectory else {
            return
        }
        do {
            try FileManager.default.removeItem(at: batchDirectory)
            print("🗑 Lot non publié retiré : \(batchID)")
        } catch {
            print("⚠️ Nettoyage du lot impossible : \(error.localizedDescription)")
        }
        currentBatchDirectory = nil
    }

    private func completeWithSuccess() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func completeWithCancel() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "ShareExtension",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "User cancelled"]
        ))
    }
}