//
//  AirBridgeApp.swift
//  AirBridge
//
//  Created by massi9106 on 16/07/2026.
//

import SwiftUI
import UserNotifications

/// Notification name for files received via URL scheme or Finder Service.
extension Notification.Name {
    static let airbridgeFilesReceived = Notification.Name("airbridgeFilesReceived")
}

#if os(macOS)
import AppKit

/// AppDelegate for handling macOS-specific functionality like URL schemes.
/// Le partage depuis le Finder passe désormais par l'extension
/// FinderService (com.apple.share-services) : l'ancien canal Services
/// (NSServices legacy + `servicesProvider`) a été retiré.
class MainAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle URLs when the app is launched via URL scheme
        for url in urls {
            NotificationCenter.default.post(
                name: .airbridgeFilesReceived,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }
}
#endif

#if os(iOS)
import Foundation

/// Observateur cross-process de la notification Darwin postée par le
/// Share Extension (`com.airbridge.share.pending`) après la copie d'un
/// lot dans l'App Group. La remise de l'URL scheme
/// (`airbridge://receive?batch=`) reste le chemin principal ; cet
/// observateur est le filet de sécurité qui importe le lot même si
/// cette remise est manquée — notamment en **warm launch**, où l'app
/// déjà au premier plan reçoit cette notification alors qu'`onOpenURL`
/// peut ne pas se déclencher.
///
/// Un seul callback existe par cycle de vie d'app ; il est acheminé sur
/// le main pour que le Core ne soit jamais touché depuis un thread de
/// rappel. Aucune déduction n'est faite ici : la résolution du lot et
/// la déduplication par signature restent dans `AirBridgeApp`.
final class PendingShareObserver: NSObject {
    private let callback: @MainActor () -> Void

    init(_ callback: @escaping @MainActor () -> Void) {
        self.callback = callback
        super.init()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let this = Unmanaged<PendingShareObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                Task { @MainActor in
                    this.callback()
                }
            },
            "com.airbridge.share.pending" as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName("com.airbridge.share.pending" as CFString),
            nil
        )
    }
}
#endif

@main
struct AirBridgeApp: App {

    @State private var notificationManager = NotificationManager()

    /// Phase de scène de l'app. Permet de survoler `PendingShares/` à
    /// chaque retour au premier plan : le Share Extension iOS / Finder
    /// Service macOS copie le lot puis ouvre l'app, qui peut déjà être
    /// active (pas d'`onOpenURL` garanti en warm launch).
    @Environment(\.scenePhase) private var scenePhase

#if os(macOS)
    @NSApplicationDelegateAdaptor(MainAppDelegate.self) private var appDelegate
#endif

    // Use a wrapper class to allow lazy initialization
    private final class CoreHolder {
        let core: AirBridgeCore

        init(notificationManager: NotificationManager) {
            let localDevice = LocalDeviceFactory.make()

            print("🏠 Appareil local de cette application :")
            print("Nom : \(localDevice.name)")
            print("Modèle : \(localDevice.model)")
            print("ID : \(localDevice.id)")

            let bonjourService = BonjourService(
                localDevice: localDevice
            )

            let messageRouter = MessageRouter()

            // ✅ Instance PARTAGÉE de PairingStore pour toute la session
            let pairingStore = PairingStore()
            print("🔐 PairingStore créé : \(ObjectIdentifier(pairingStore))")

            let connectionManager = ConnectionManager(
                localDevice: localDevice,
                messageRouter: messageRouter,
                pairingStore: pairingStore
            )

            let receivedFolderStore = ReceivedFolderStore()
            let transferHistoryStore = TransferHistoryStore()

            let transferManager = TransferManager(
                receivedFolderStore: receivedFolderStore,
                localDevice: localDevice,
                historyStore: transferHistoryStore
            )

            self.core = AirBridgeCore(
                bonjourService: bonjourService,
                connectionManager: connectionManager,
                messageRouter: messageRouter,
                transferManager: transferManager,
                receivedFolderStore: receivedFolderStore,
                transferHistoryStore: transferHistoryStore,
                pairingStore: pairingStore
            )

            // ✅ DEBUG: Log de l'instance utilisée par AirBridgeCore
            print("🔐 AirBridgeCore.pairingStore : \(ObjectIdentifier(self.core.pairingStore))")

            // Connecter les callbacks de notification au Core
            notificationManager.onAcceptTransfer = { [weak self] in
                self?.core.acceptPendingTransfer()
            }
            notificationManager.onRejectTransfer = { [weak self] in
                self?.core.rejectPendingTransfer()
            }

            self.core.start()
        }
    }

    // State object to hold the core - initialized lazily
    @State private var coreHolder: CoreHolder?

    /// Contrôleur du lot stationné par une extension de partage dans
    /// l'App Group. Il existe dès l'init de l'app (aucune dépendance au
    /// Core) : une présentation peut donc survenir en cold launch, avant
    /// même le premier rendu. La déduplication par signature, la
    /// présentation unique et la purge des fichiers livrés sont ici —
    /// plus jamais dans l'envoi automatique.
    @State private var pendingShareController = PendingShareController()

#if os(iOS)
    /// Observateur Darwin des lots Share Extension (warm launch). Détenu
    /// par la durée de vie de l'app ; créé une seule fois au démarrage.
    @State private var pendingShareObserver: PendingShareObserver?
#endif

    init() {
        notificationManager.configureCategories()

        // Use UserDefaults directly since @AppStorage doesn't work in App init()
        // Default to true if key doesn't exist (consistent with @AppStorage default)
        let defaults = UserDefaults.standard
        let notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true

        if notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if granted {
                    print("✅ Permission notifications accordée")
                } else {
                    print("❌ Permission notifications refusée : \(error?.localizedDescription ?? "inconnu")")
                }
            }
        }
    }

    var body: some Scene {
        workspaceScene
    }

#if os(macOS)
    /// Fenêtre macOS : taille initiale 1280 × 820, librement
    /// redimensionnable ensuite.
    private var workspaceScene: some Scene {
        WindowGroup {
            rootContent
        }
        .defaultSize(width: 1280, height: 820)
    }
#else
    private var workspaceScene: some Scene {
        WindowGroup {
            rootContent
        }
    }
#endif

    @ViewBuilder
    private var rootContent: some View {
        Group {
            if let coreHolder {
                rootView(for: coreHolder)
                    .environment(notificationManager)
            } else {
                Color.clear
                    .onAppear {
                        coreHolder = CoreHolder(
                            notificationManager: notificationManager
                        )

                        // L'extension de partage (Share Extension iOS,
                        // Finder Service macOS) a pu copier un lot avant
                        // notre démarrage (notification Darwin reçue avant
                        // l'init du Core, ou feuille fermée par le
                        // système) : purge des fichiers livrés puis
                        // présentation du lot le plus récent. Aucun envoi
                        // automatique ici.
                        sweepPendingShares()

#if os(iOS)
                        startPendingShareObserver()
#endif
                    }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Retour au premier plan : le partage a pu être initié
            // pendant que l'app était inactive (pas d'`onOpenURL`
            // garanti) ; on survole les lots App Group à chaque
            // activation.
            if newPhase == .active { sweepPendingShares() }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .airbridgeFilesReceived
            )
        ) { notification in
            receiveSharedFiles(notification)
        }
    }

    /// Vue racine par plateforme : espace de travail dédié macOS
    /// (`MacTransferWorkspaceView` : sidebar + zone de dépôt + tableau
    /// des transferts), interface existante (`MainView`) sur iOS.
    @ViewBuilder
    private func rootView(
        for holder: CoreHolder
    ) -> some View {
#if os(macOS)
        MacTransferWorkspaceView(
            core: holder.core,
            pendingShareController: pendingShareController
        )
#else
        MainView(
            core: holder.core,
            pendingShareController: pendingShareController
        )
#endif
    }

    /// Handles incoming URLs from Finder Service, Drop Zone, the
    /// iOS Share Extension, or a document opened from Files
    /// (CFBundleDocumentTypes, `file://`).
    /// - Parameter url: The URL to process.
    private func handleIncomingURL(_ url: URL) {
        // Ouverture directe d'un document (Fichiers → « Ouvrir avec
        // AirBridge » via CFBundleDocumentTypes, ou double-clic Finder
        // macOS) : même chemin que le Finder Service — présentation
        // dans la feuille d'envoi SANS envoi automatique. La
        // déduplication par signature du `PendingShareController`
        // absorbe une double remise (AppDelegate macOS + onOpenURL).
        if url.isFileURL {
            importSharedURLs([url])
            return
        }

        guard url.scheme == "airbridge" else { return }

        guard url.host == "receive",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }

        // Nouveau chemin (Share Extension iOS) : un lot a été copié dans
        // le conteneur App Group (`PendingShares/<batchID>/`). On ne
        // transmet que l'identifiant ; on résout ici les fichiers réels.
        if let batchID = components.queryItems?.first(where: { $0.name == "batch" })?.value {
            let urls = pendingBatchURLs(batchID: batchID)
            guard !urls.isEmpty else {
                print("🚫 Lot App Group introuvable : \(batchID)")
                return
            }

            NotificationCenter.default.post(
                name: .airbridgeFilesReceived,
                object: nil,
                userInfo: ["urls": urls]
            )
            print("📩 Fichiers reçus via lot App Group : \(urls.map { $0.lastPathComponent })")
            return
        }

        // Ancien chemin (compat) : URLs de fichiers encodées dans
        // la query (`airbridge://receive?files=...` — FinderService
        // macOS). Le Share Extension iOS utilise désormais le lot.
        guard let filesParam = components.queryItems?
                .first(where: { $0.name == "files" })?.value,
              let decoded = filesParam.removingPercentEncoding else {
            return
        }

        let urlStrings = decoded.split(separator: "|").map(String.init)
        let urls = urlStrings.compactMap { URL(string: $0) }

        // Post notification for the main app to handle
        // In practice, the app must be running and connected for this to work.
        // Otherwise, store the URLs and process them once connected.
        NotificationCenter.default.post(
            name: .airbridgeFilesReceived,
            object: nil,
            userInfo: ["urls": urls]
        )

        print("📩 Fichiers reçus via URL scheme : \(urls.map { $0.lastPathComponent })")
    }

    /// Résout un lot écrit par le Share Extension iOS dans le conteneur
    /// App Group (`PendingShares/<batchID>/`) en liste d'URLs lisibles
    /// par l'app. Le manifeste JSON du lot est exclu.
    private func pendingBatchURLs(batchID: String) -> [URL] {
        // Le batchID provient de l'URL scheme ; on n'accepte que les
        // lots que notre extension a réellement créés (UUID). Refuser
        // tout autre identifiant élimine le path traversal via
        // `appendingPathComponent`.
        guard batchID.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil else { return [] }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.airbridge.shared"
        ) else { return [] }

        let dir = containerURL
            .appendingPathComponent("PendingShares", isDirectory: true)
            .appendingPathComponent(batchID, isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        // Le manifeste est écrit en dernier par les extensions : sa présence
        // garantit une copie complète du lot (sinon il pourrait s'agir d'un
        // lot interrompu — extension tuée en cours de copie).
        guard files.contains(where: { $0.lastPathComponent == "manifest.json" }) else { return [] }

        return files
            .filter { $0.lastPathComponent != "manifest.json" }
            .filter { $0.isFileURL }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Route vers le pipeline existant la sélection arrivée par la
    /// notification `.airbridgeFilesReceived`.
    ///
    /// Deux formes de payload existent et sont toutes deux gérées :
    /// - `"urls"` : tableau `[URL]`, posté par `handleIncomingURL` (iOS) ;
    /// - `"url"` : URL unique, postée par `MainAppDelegate` (macOS).
    ///
    /// La redondance d'un même lot (double remise d'un même lancement)
    /// est filtrée par signature pour ne jamais déclencher un second
    /// `importAndRequestItems` sur les mêmes URLs.
    private func receiveSharedFiles(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]

        if let urls = userInfo["urls"] as? [URL] {
            importSharedURLs(urls)
        } else if let url = userInfo["url"] as? URL {
            importSharedURLs([url])
        }
    }

    /// Reçoit une sélection arrivée par notification et la présente dans
    /// l'interface d'envoi — SANS envoi automatique.
    ///
    /// Le Core n'est pas sollicité ici : le lot devient seulement
    /// *candidat* ; il ne sera transmis au moteur (`importAndRequestItems`)
    /// que si l'utilisateur choisit un destinataire dans la feuille.
    /// Aucune suppression n'a lieu non plus : la purge des fichiers livrés
    /// appartient à `sweepPendingShares`, seule consommatrice de
    /// `pruneDeliveredBatches`.
    private func importSharedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingShareController.present(urls: urls)
    }

#if os(iOS)
    /// Démarre (une seule fois) l'observateur Darwin des lots partagés.
    /// Idempotent : une app peut passer plusieurs fois par le rendu
    /// initial sans créer de doublon.
    private func startPendingShareObserver() {
        guard pendingShareObserver == nil else { return }
        pendingShareObserver = PendingShareObserver { [self] in
            self.sweepPendingShares()
        }
    }
#endif

    /// Balayage de `PendingShares/` dans l'App Group — chemin commun du
    /// warm launch (observateur Darwin iOS, retour au premier plan via
    /// `scenePhase`) et du cold launch (premier rendu).
    ///
    /// Deux responsabilités, sans jamais déclencher d'envoi :
    ///   1. purge des fichiers de lot livrés — chaque fichier n'est
    ///      retiré que si un transfert sortant `completed` l'a livré
    ///      (`PendingShareController.pruneDeliveredBatches`, UNIQUE point
    ///      de suppression des lots) ;
    ///   2. présentation du lot le plus récent non encore présenté.
    @MainActor
    private func sweepPendingShares() {
        // Fichiers livrés = `sourceFileURL` des transferts sortants
        // terminés. Lecture seule de l'état déjà exposé par le Core —
        // le moteur de transfert n'est pas modifié.
        let delivered = Set(
            (coreHolder?.core.transferManager.transfers ?? [])
                .filter { $0.direction == .outgoing && $0.state == .completed }
                .compactMap(\.sourceFileURL)
        )

        let result = pendingShareController.pruneDeliveredBatches(
            deliveredSourceURLs: delivered
        )
        for error in result.errors {
            print("⚠️ Prune des lots : \(error.localizedDescription)")
        }

        presentNewestUnpresentedBatch()
    }

    /// Présente le lot le plus récent qui contient encore des fichiers et
    /// n'a pas déjà été présenté dans cette session. Ne déclenche JAMAIS
    /// d'envoi : l'utilisateur choisit le destinataire puis envoie.
    @MainActor
    private func presentNewestUnpresentedBatch() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.airbridge.shared"
        ) else { return }

        let pendingRoot = PendingShareController.pendingSharesRoot(
            in: containerURL
        )
        guard let batchDirectories = try? FileManager.default.contentsOfDirectory(
            at: pendingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        // Lot le plus récent, en ignorant le reste (stores, caches…).
        var newestBatch: URL?
        var newestDate = Date.distantPast
        for candidate in batchDirectories {
            guard PendingShareController.isUUID(candidate.lastPathComponent) else {
                continue
            }
            guard (try? candidate.resourceValues(
                forKeys: [.isDirectoryKey]
            ))?.isDirectory == true else { continue }
            let date = (try? candidate.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            if date > newestDate {
                newestDate = date
                newestBatch = candidate
            }
        }
        guard let newestBatch else { return }

        // `pendingBatchURLs` valide l'UUID et écarte le manifeste.
        let urls = pendingBatchURLs(batchID: newestBatch.lastPathComponent)
        guard !urls.isEmpty else { return }
        pendingShareController.present(urls: urls)
    }
}
