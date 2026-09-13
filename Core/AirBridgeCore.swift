//
//  AirBridgeCore.swift
//  AirBridge
//
//  Created by massi9106 on 16/07/2026.
//

import Observation
import Network
import UserNotifications
import CryptoKit
import OSLog
internal import UniformTypeIdentifiers

@MainActor
@Observable
final class AirBridgeCore {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "core"
    )

    let bonjourService: BonjourService
    let connectionManager: ConnectionManager
    let messageRouter: MessageRouter
    let transferManager: TransferManager
    let receivedFolderStore: ReceivedFolderStore
    let transferHistoryStore: TransferHistoryStore
    let notificationManager = NotificationManager()

    private let messageCodec = MessageCodec()

    
    
    /// Lot d'autorisation prêt à être présenté à l'utilisateur.
    /// Reste `nil` pendant la fenêtre de coalescence pour qu'une
    /// sélection multiple ne produise qu'une seule demande.
    private(set) var pendingTransferBatch: PendingTransferBatch?

    private let pendingApprovalCoordinator =
        PendingApprovalCoordinator()

    private let outgoingTransferQueue =
        OutgoingTransferQueue()

    private let transferTimeoutManager =
        TransferTimeoutManager()

    let pairingStore: PairingStore
    private var pairingHandshake: PairingHandshake

    /// Challenge en attente pour le handshake de pairage (initiateur).
    /// Clé = peerID, Valeur = challenge envoyé.
    private var pendingPairingChallenges: [UUID: Data] = [:]

    private var outgoingFileHandles: [UUID: FileHandle] = [:]
    private var startedOutgoingTransfers: Set<UUID> = []
    private var approvalRequestsSent: Set<UUID> = []
    private var approvedOutgoingTransfers: Set<UUID> = []
    private var isCleaningUpSession = false

    /// Dernier pair connu, mémorisé pour rattacher les transferts à un
    /// peer même après que la session a été fermée (le `connectedDevice`
    /// vaut alors déjà `nil`).
    private var lastKnownPeerID: UUID?

    /// Reprises automatiques en cours : une seule tâche par transfert,
    /// jamais deux reprises simultanées du même identifiant.
    private var resumeTasks: [UUID: Task<Void, Never>] = [:]

    /// Vrai quand une campagne de reprise est déjà ouverte (des tâches de
    /// backoff tournent). Une seule campagne à la fois : sans ce verrou,
    /// chaque événement de session relancerait un cycle complet — d'où des
    /// `resumeRequest` répétés observés sur le terrain. Le verrou tombe aux
    /// sorties terminales (`endResumeCampaign`) pour qu'une prochaine
    /// session puisse en rouvrir une.
    private var isResumeCampaignActive = false


    init(
        bonjourService: BonjourService,
        connectionManager: ConnectionManager,
        messageRouter: MessageRouter,
        transferManager: TransferManager,
        receivedFolderStore: ReceivedFolderStore,
        transferHistoryStore: TransferHistoryStore,
        pairingStore: PairingStore
    ) {
        self.bonjourService = bonjourService
        self.connectionManager = connectionManager
        self.messageRouter = messageRouter
        self.transferManager = transferManager
        self.receivedFolderStore = receivedFolderStore
        self.transferHistoryStore = transferHistoryStore
        self.pairingStore = pairingStore
        self.pairingHandshake = PairingHandshake(pairingStore: pairingStore)

        configureBindings()
    }
    
    
    private func activateOutgoingTransfer(
        _ entry: OutgoingTransferQueue.Entry
    ) {
        guard outgoingTransferQueue.isActive(entry.id) else {
            return
        }

        sendApprovalRequestIfNeeded(for: entry)

        guard approvedOutgoingTransfers.contains(entry.id) else {
            return
        }

        beginOutgoingTransfer(entry)
    }

    private func sendApprovalRequestIfNeeded(
        for entry: OutgoingTransferQueue.Entry
    ) {
        guard !approvalRequestsSent.contains(entry.id) else {
            return
        }

        transferManager.markWaitingForApproval(
            transferID: entry.id
        )

        guard let transferID = connectionManager.sendTransferRequest(
            transferID: entry.id,
            fileName: entry.fileName,
            fileSize: entry.fileSize,
            contentType: entry.contentType,
            batchID: entry.batchID,
            batchFolderName: entry.batchFolderName,
            relativePath: entry.relativePath
        ), transferID == entry.id else {
            failOutgoingTransfer(
                transferID: entry.id,
                reason: "Impossible d’envoyer la demande de transfert",
                notifyPeer: false
            )
            return
        }

        approvalRequestsSent.insert(entry.id)
        transferTimeoutManager.start(
            transferID: entry.id,
            kind: .approval,
            duration: .seconds(300)
        ) { [weak self] in
            guard let self else {
                return
            }

            logger.warning(
                "Délai d’acceptation dépassé : \(entry.id, privacy: .public)"
            )

            self.failOutgoingTransfer(
                transferID: entry.id,
                reason: "Délai d’acceptation dépassé",
                notifyPeer: true
            )
        }
    }

    private func beginOutgoingTransfer(
        _ entry: OutgoingTransferQueue.Entry
    ) {
        guard outgoingTransferQueue.isActive(entry.id),
              approvedOutgoingTransfers.contains(entry.id),
              startedOutgoingTransfers.insert(entry.id).inserted else {
            return
        }

        do {
            let fileURL = try transferManager.outgoingFileURL(
                transferID: entry.id
            )

            transferTimeoutManager.cancel(
                transferID: entry.id
            )
            transferManager.markAccepted(
                transferID: entry.id
            )
            restartTransferActivityTimeout(
                transferID: entry.id
            )
            sendFileChunks(
                transferID: entry.id,
                fileURL: fileURL
            )
        } catch {
            startedOutgoingTransfers.remove(entry.id)
            transferManager.markFailed(
                transferID: entry.id,
                reason: "Source du transfert introuvable"
            )
            finishOutgoingTransfer(
                transferID: entry.id
            )
        }
    }

    private func failOutgoingTransfer(
        transferID: UUID,
        reason: String,
        notifyPeer: Bool
    ) {
        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        if notifyPeer {
            connectionManager.sendTransferCancelled(
                transferID: transferID,
                reason: reason
            )
        }

        transferManager.markFailed(
            transferID: transferID
        )

        finishOutgoingTransfer(
            transferID: transferID
        )
    }

    private func restartTransferActivityTimeout(
        transferID: UUID
    ) {
        transferTimeoutManager.start(
            transferID: transferID,
            kind: .transferActivity,
            duration: .seconds(30)
        ) { [weak self] in
            guard let self else {
                return
            }

            logger.warning(
                "Délai d’activité dépassé : \(transferID, privacy: .public)"
            )

            // Décision métier : un timeout d'activité signale une liaison
            // silencieuse, pas un refus du pair. Si la session est encore
            // vivante, le transfert passe à `.interrupted` (récupérable par
            // reprise) au lieu de `.failed` (terminal). Hors session, le
            // handler de déconnexion a déjà interrompu le transfert : on ne
            // fait qu'un nettoyage terminal classique, sans notifier un pair
            // qui n'est plus joignable.
            guard self.connectionManager.session != nil else {
                // Liaison déjà perdue mais session pas encore fermée :
                // même politique que la coupure réseau, jamais `.failed`.
                logger.info("Timeout d'activité hors session : interruption récupérable")
                self.interruptOutgoingTransfer(transferID: transferID)
                return
            }

            self.interruptOutgoingTransfer(transferID: transferID)
        }
    }

    /// Fait passer un envoi actif à `.interrupted` : progression conservée,
    /// handle fermé, entrée retirée de la file FIFO pour libérer le suivant,
    /// mais source sortante préservée — c'est elle qui porte l'offset déjà
    /// envoyé et servira de point de départ à la reprise.
    private func interruptOutgoingTransfer(transferID: UUID) {
        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        transferTimeoutManager.cancel(transferID: transferID)

        if let fileHandle = outgoingFileHandles.removeValue(
            forKey: transferID
        ) {
            try? fileHandle.close()
        }

        let transferredBytes = transferManager.transfers
            .first { $0.id == transferID }?
            .transferredBytes ?? 0

        transferManager.markInterrupted(
            transferID: transferID,
            transferredBytes: transferredBytes,
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        // Retire l'entrée de la file (et active la suivante) sans toucher
        // à la source : `cleanupOutgoingTransfer` la supprimerait.
        _ = outgoingTransferQueue.cancel(transferID: transferID)

        startedOutgoingTransfers.remove(transferID)
    }

    @discardableResult
    private func finishOutgoingTransfer(
        transferID: UUID
    ) -> Bool {
        guard let entry = outgoingTransferQueue.allEntries.first(where: {
            $0.id == transferID
        }) else {
            startedOutgoingTransfers.remove(transferID)
            approvalRequestsSent.remove(transferID)
            approvedOutgoingTransfers.remove(transferID)
            return false
        }

        transferTimeoutManager.cancel(
            transferID: transferID
        )

        if let fileHandle = outgoingFileHandles.removeValue(
            forKey: transferID
        ) {
            try? fileHandle.close()
        }

        transferManager.cleanupOutgoingTransfer(
            transferID: transferID
        )

        guard outgoingTransferQueue.finish(transferID: transferID) else {
            return false
        }

        startedOutgoingTransfers.remove(transferID)
        approvalRequestsSent.remove(transferID)
        approvedOutgoingTransfers.remove(transferID)

        if entry.sourceFileURL != entry.fileURL {
            logger.info(
                "Fichier original conservé : \(entry.sourceFileURL.lastPathComponent, privacy: .public)"
            )
        }

        return true
    }

    func requestTransfer(
        fileURL: URL,
        sourceFileURL: URL,
        isTemporarySource: Bool = false
    ) {
        guard let peer = connectionManager.connectedDevice else {
            logger.error("Aucun appareil connecté")
            return
        }

        do {
            let resourceValues = try fileURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .contentTypeKey
                ]
            )

            guard let fileSize = resourceValues.fileSize else {
                logger.error("Impossible de lire la taille du fichier")
                return
            }

            let entry = OutgoingTransferQueue.Entry(
                peer: peer,
                fileName: fileURL.lastPathComponent,
                fileSize: Int64(fileSize),
                contentType: resourceValues.contentType?.preferredMIMEType,
                fileURL: fileURL,
                sourceFileURL: sourceFileURL
            )

            transferManager.createOutgoingTransfer(
                id: entry.id,
                peer: entry.peer,
                fileName: entry.fileName,
                fileSize: entry.fileSize,
                state: .requesting
            )

            transferManager.setSourceFileURL(
                transferID: entry.id,
                url: entry.sourceFileURL
            )

            transferManager.registerOutgoingSource(
                transferID: entry.id,
                fileURL: entry.fileURL,
                originalFileURL: sourceFileURL,
                isTemporary: isTemporarySource
            )

            if isCleaningUpSession,
               outgoingTransferQueue.allEntries.isEmpty {
                isCleaningUpSession = false
                startedOutgoingTransfers.removeAll()
            }

            outgoingTransferQueue.enqueue(entry)

            logger.info(
                "Transfert ajouté à la file : \(entry.fileName, privacy: .public)"
            )

        } catch {
            logger.error(
                "Impossible de préparer le fichier : \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func requestTransferEntries(
        _ entries: [OutgoingTransferQueue.Entry],
        batchID: UUID
    ) {
        for entry in entries {
            transferManager.createOutgoingTransfer(
                id: entry.id,
                peer: entry.peer,
                fileName: entry.fileName,
                fileSize: entry.fileSize,
                state: .requesting
            )
            // Tous les fichiers d'une même sélection partagent le lot :
            // l'aperçu des transferts terminés peut alors les présenter
            // comme un seul dossier.
            transferManager.setBatchID(
                transferID: entry.id,
                batchID: batchID
            )
            transferManager.setSourceFileURL(
                transferID: entry.id,
                url: entry.sourceFileURL
            )
            transferManager.registerOutgoingSource(
                transferID: entry.id,
                fileURL: entry.fileURL,
                originalFileURL: entry.sourceFileURL,
                isTemporary: true
            )
        }

        if isCleaningUpSession,
           outgoingTransferQueue.allEntries.isEmpty {
            isCleaningUpSession = false
            startedOutgoingTransfers.removeAll()
        }

        entries.forEach(outgoingTransferQueue.enqueue)
    }

    /// Envoie une sélection de l'utilisateur : des fichiers, des dossiers,
    /// ou les deux mélangés.
    ///
    /// Point d'entrée unique des sélecteurs et du dépôt. La sélection est
    /// répartie en lots — les fichiers isolés ensemble, chaque dossier à
    /// part — et chaque lot part avec son propre identifiant, donc son
    /// propre sous-dossier à l'arrivée.
    /// - Returns: `true` si au moins une entrée a été créée et mise en
    ///   file (les fichiers ont été copiés dans le temporaire du Core et
    ///   la sélection est donc consommée) ; `false` si rien n'a été
    ///   importé — aucun appareil connecté, sélection vide, ou échec de
    ///   copie. Le retour permet à l'appelant de savoir s'il peut
    ///   nettoyer une source temporaire (batch App Group du share
    ///   extension) sans perdre une sélection non consommée.
    @discardableResult
    func importAndRequestItems(
        urls: [URL]
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        guard connectionManager.connectedDevice != nil else {
            logger.error("Aucun appareil connecté")
            return false
        }

        let plans = OutgoingSelectionPlanner.plans(for: urls)

        guard !plans.isEmpty else {
            logger.info("Sélection sans fichier à envoyer")
            return false
        }

        var importedAny = false
        for plan in plans {
            importedAny = requestTransfers(for: plan) || importedAny
        }
        return importedAny
    }

    /// Prépare les fichiers d'un lot puis les met en file.
    ///
    /// L'accès au dossier choisi est tenu pendant toute la préparation :
    /// le système l'accorde au dossier et non à ses fichiers, donc le
    /// relâcher entre deux copies rendrait les suivantes illisibles.
    /// - Returns: `true` si au moins une entrée a été préparée (copie
    ///   réussie vers le temporaire du Core) et mise en file.
    @discardableResult
    private func requestTransfers(
        for plan: OutgoingSelectionPlan
    ) -> Bool {
        let folderAccess =
            plan.folderURL?.startAccessingSecurityScopedResource()
                ?? false

        defer {
            if folderAccess, let folderURL = plan.folderURL {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        var entries = plan.files.compactMap {
            makeEntry(for: $0, in: plan)
        }

        guard !entries.isEmpty else {
            logger.error("Aucun fichier exploitable dans la sélection")
            return false
        }

        let batchID = UUID()

        // Le lot n'est annoncé au récepteur que s'il en est vraiment un :
        // un dossier toujours, une sélection de fichiers à partir de deux.
        // Un fichier isolé reste ainsi à plat dans le dossier de réception,
        // et le récepteur n'a rien à compter pour le savoir.
        if plan.announcesBatch {

            for index in entries.indices {
                entries[index].batchID = batchID
            }
        }

        requestTransferEntries(entries, batchID: batchID)
        sendApprovalRequests(for: entries)
        return true
    }

    /// Copie un fichier vers le conteneur de l'app et décrit l'envoi.
    ///
    /// La copie protège l'original : le transfert lit ensuite sa propre
    /// copie, donc l'utilisateur peut déplacer ou modifier son fichier sans
    /// casser l'envoi en cours.
    private func makeEntry(
        for file: OutgoingSelectionPlan.File,
        in plan: OutgoingSelectionPlan
    ) -> OutgoingTransferQueue.Entry? {

        let fileURL = file.url
        let fileManager = FileManager.default

        // Utile pour un fichier isolé, à qui l'accès est accordé
        // directement. Sans effet pour l'enfant d'un dossier, dont l'accès
        // est déjà tenu par l'appelant.
        let hasAccess =
            fileURL.startAccessingSecurityScopedResource()

        defer {
            if hasAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let localURL = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "\(UUID().uuidString)-\(fileURL.lastPathComponent)"
                )

            try fileManager.copyItem(at: fileURL, to: localURL)

            let values = try localURL.resourceValues(
                forKeys: [.fileSizeKey, .contentTypeKey]
            )

            guard let fileSize = values.fileSize else {
                throw CocoaError(.fileReadUnknown)
            }

            guard let peer = connectionManager.connectedDevice else {
                return nil
            }

            return OutgoingTransferQueue.Entry(
                peer: peer,
                fileName: fileURL.lastPathComponent,
                fileSize: Int64(fileSize),
                contentType: values.contentType?.preferredMIMEType,
                fileURL: localURL,
                sourceFileURL: fileURL,
                batchFolderName: plan.folderName,
                relativePath: file.relativePath
            )

        } catch {
            logger.error(
                "Impossible d’importer \(fileURL.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func importAndRequestTransfers(
        fileURLs: [URL]
    ) {
        importAndRequestItems(urls: fileURLs)
    }

    func importAndRequestTransfer(
        fileURL: URL
    ) {
        importAndRequestItems(urls: [fileURL])
    }

    private func sendApprovalRequests(
        for entries: [OutgoingTransferQueue.Entry]
    ) {
        for entry in entries {
            sendApprovalRequestIfNeeded(for: entry)
        }
    }

    /// `chunkSize` est décidé une fois pour tout le transfert, puis passé de
    /// morceau en morceau : le découpage doit rester régulier même si le
    /// fichier change de taille sous nos pieds.
    ///
    /// Durée de la dernière lecture disque, consommée par l'instrumentation
    /// de performance (`TransferPerformanceLog`) via le chemin d'envoi.
    private var lastReadDuration: Double = 0

    private func sendNextChunk(
        transferID: UUID,
        fileHandle: FileHandle,
        fileSHA256: String,
        offset: Int64,
        chunkSize: Int,
        performanceMode: String? = nil,
        expectedTotalSize: Int64? = nil
    ) {
        // Wrapper de compatibilité : délègue au pipeline async.
        // Conserve la signature d'origine pour les appels existants
        // (reprise, tests) tout en bénéficiant des performances du
        // nouveau chemin (lecture disque + chiffrement off main thread,
        // envois concurrents).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runChunkPipeline(
                    transferID: transferID,
                    fileHandle: fileHandle,
                    fileSHA256: fileSHA256,
                    offset: offset,
                    chunkSize: chunkSize,
                    performanceMode: performanceMode,
                    expectedTotalSize: expectedTotalSize
                )
            } catch {
                // `runChunkPipeline` a déjà fait le ménage (fermeture du
                // handle, marquage échec/interruption). En cas d'erreur
                // non gérée, on s'assure au minimum que la queue est
                // nettoyée.
                self.outgoingFileHandles.removeValue(forKey: transferID)
                try? fileHandle.close()
                logger.error("Pipeline d'envoi : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pipeline d'envoi async.
    ///
    /// Remplace la récursion par complétion synchrone de
    /// `sendNextChunk`. Les bénéfices principaux :
    /// 1. **Lecture disque off main thread** : `FileHandle.read` est
    ///    appelé depuis une `Task.detached`, ce qui libère le `@MainActor`
    ///    pour le décodage entrant.
    /// 2. **Pas de saut `@MainActor` par chunk** : l'envoi passe par
    ///    `OutgoingTransferManager.sendChunkAsync`, qui utilise un
    ///    `CheckedContinuation` et reste hors MainActor entre chaque
    ///    chunk.
    /// 3. **Fenêtre en vol bornée** : jusqu'à `pipelineDepth = 4`
    ///    chunks peuvent être en transit simultanément. Le décodage
    ///    du chunk N+1 commence pendant que N est encore en transit,
    ///    masquant la latence du disque et du réseau.
    /// 4. **Ordre strict préservé** : bien que plusieurs chunks
    ///    puissent être en vol, l'incrément de `totalBytesSentCount`
    ///    et la mise à jour de `lastOffsetConsumed` sont sérialisés
    ///    par un `OrderedAckPump` qui ne libère les compteurs que
    ///    dans l'ordre d'émission (offset croissant). Le récepteur
    ///    peut donc traiter les chunks dans l'ordre d'arrivée sans
    ///    risque de réordonnancement côté émetteur.
    private func runChunkPipeline(
        transferID: UUID,
        fileHandle: FileHandle,
        fileSHA256: String,
        offset: Int64,
        chunkSize: Int,
        performanceMode: String?,
        expectedTotalSize: Int64? = nil
    ) async throws {

        if let performanceMode {
            TransferPerformanceLog.begin(
                transferID: transferID,
                mode: performanceMode,
                chunkSize: chunkSize
            )
        }

        let currentOffset = offset

        // Fenêtre en vol bornée à `pipelineDepth = 4` chunks. Le
        // compromis mémoire/débit :
        // - À 1 chunk en vol (l'ancien comportement séquentiel), le
        //   débit plafonne autour de 7 Mo/s : chaque chunk attend
        //   son acquittement avant que le suivant ne soit émis, ce
        //   qui sous-utilise la fenêtre TCP sur réseau local.
        // - À 4 chunks en vol, on masque la latence d'un aller-retour
        //   (~1 ms sur réseau local) tout en restant sous le seuil
        //   d'accumulation mémoire côté récepteur (4 × 2 Mio = 8 Mio
        //   en vol maximum, ce qui tient dans le buffer NWConnection).
        // - Au-delà de 4, les benchmarks sur réseau local Gigabit
        //   ne montrent pas de gain de débit mesurable mais
        //   continuent à accroître la mémoire réceptrice et la
        //   pression sur le réordonnancement.
        //
        // L'ordre reste strict grâce à `OrderedAckPump` (défini plus
        // bas) : le chunk N+1 peut être *en vol* en même temps que N,
        // mais son compteur d'octets ne s'incrémente qu'après
        // l'acquittement de N, et donc toujours dans l'ordre
        // d'émission. La back-pressure est effective via le sémaphore
        // `PipelineWindow` : le producteur attend qu'un slot se
        // libère avant d'émettre le chunk suivant.
        let pipelineDepth = 4

        // Batching des updates UI de progression. Avant le refactor,
        // chaque chunk acquitté franchissait `MainActor.run` pour
        // pousser `updateProgress` + `restartTransferActivityTimeout`,
        // ce qui sérialisait le pipeline sur le main thread (~1 ms
        // par chunk → ~4 chunks/s → ~8 Mo/s sur chunks de 2 Mio).
        //
        // À `uiBatchStride = 8`, on ne traverse le MainActor qu'une
        // fois tous les 8 chunks (16 Mio) — soit ~30 updates/s sur un
        // transfert à 100 Mo/s, imperceptible pour l'œil humain.
        // La progression n'est jamais en retard de plus de 16 Mio.
        // Le dernier chunk force toujours la mise à jour pour garantir
        // `progress == 100%` au moment de la finalisation.
        let uiBatchStride = 8

        // Channel producteur/consommateur entre la lecture disque
        // (détachée) et la boucle d'envoi. Politique de buffering
        // par défaut (`.unbounded`) : la back-pressure est désormais
        // imposée par le sémaphore `PipelineWindow` (le producteur
        // attend un slot libre avant de yield), donc un buffer borné
        // serait à la fois inutile et dangereux.
        //
        // Bug historique : la politique `.bufferingNewest(pipelineDepth)`
        // utilisée ici écrasait silencieusement les chunks les plus
        // récents quand le buffer interne de l'`AsyncStream` était
        // plein, ce qui faisait perdre la majorité d'un fichier dès
        // que le nombre de chunks dépassait `pipelineDepth`. Sur un
        // fichier de 736 Mo / 2 Mio par chunk = 369 chunks avec
        // `pipelineDepth = 4`, le récepteur ne recevait que quelques
        // chunks épars (les derniers ajoutés avant que le producteur
        // ne soit drainé).
        let (readStream, readContinuation) = AsyncStream<
            PipelineChunk
        >.makeStream()

        // 1. Producteur de chunks : lit le fichier off main thread.
        let readerTask = Task.detached(
            priority: .userInitiated
        ) { [chunkSize, transferID] in
            var fileOffset = currentOffset
            do {
                while true {
                    if Task.isCancelled { break }
                    let readStart = Date()
                    let data = try fileHandle.read(
                        upToCount: chunkSize
                    ) ?? Data()
                    let readDuration = Date().timeIntervalSince(readStart)
                    if data.isEmpty { break }
                    let nextOffset = fileOffset + Int64(data.count)
                    let isLast = data.count < chunkSize
                    let chunk = PipelineChunk(
                        transferID: transferID,
                        offset: fileOffset,
                        data: data,
                        isLastChunk: isLast,
                        readDuration: readDuration
                    )
                    fileOffset = nextOffset
                    readContinuation.yield(chunk)
                }
            } catch {
                // Erreur disque : on propage via le canal d'erreur.
                readContinuation.yield(
                    PipelineChunk(
                        transferID: transferID,
                        offset: -1,
                        data: Data(),
                        isLastChunk: true,
                        readDuration: 0,
                        readError: error
                    )
                )
            }
            readContinuation.finish()
        }

        // 2. Consommateur : fenêtre en vol bornée + acquittements
        //    ordonnés. Chaque chunk tiré du flux est envoyé dans une
        //    tâche enfant ; jusqu'à `pipelineDepth` envois peuvent
        //    être en transit simultanément. Les acquittements sont
        //    appliqués dans l'ordre strict d'émission grâce à
        //    `OrderedAckPump`, ce qui préserve l'invariant
        //    `totalBytesSentCount == expectedTotalSize` utilisé par
        //    le garde-fou d'intégrité.
        let window = PipelineWindow(limit: pipelineDepth)
        let pump = OrderedAckPump(startOffset: currentOffset)
        let errorSlot = PipelineErrorSlot()

        // Capture faible de self pour les callbacks MainActor
        // (mise à jour de la progression, redémarrage du timeout
        // d'activité). Le `withTaskGroup` attendra la fin de toutes
        // les tâches enfant avant de retourner, donc ces callbacks
        // s'exécutent nécessairement avant la sortie de la fonction.
        let transferMgr = transferManager
        let outgoingMgr = transferMgr.outgoingManager
        let transferIDForTasks = transferID
        let chunkSizeForTasks = chunkSize

        // Snapshot immuable de l'état d'envoi capturé une fois pour
        // toutes sous `@MainActor` (avant d'entrer dans le
        // `withTaskGroup`). Les tâches enfant (non isolées)
        // utiliseront ce snapshot pour appeler directement
        // `sendChunkOverConnection` sans jamais repasser par
        // `@MainActor` pour relire les `var` du manager.
        // C'est l'optimisation qui débloque le débit : avant le
        // refactor, chaque chunk payait un saut MainActor (~1 ms),
        // ce qui bridait le pipeline à ~4 chunks/s (~8 Mo/s sur
        // chunks de 2 Mio).
        let sendSnapshot = outgoingMgr.snapshotForSending()
        guard let snapshotConnection = sendSnapshot.connection else {
            // Pas de connexion : échec immédiat.
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            logger.error("Aucune connexion active pour le pipeline")
            return
        }
        let frameCodec = FrameCodec()
        let snapshotForTasks = sendSnapshot
        let connectionForTasks = snapshotConnection

        var lastError: Error?
        var lastReadDuration: Double = 0
        // Snapshot final lu depuis le pump une fois le groupe drainé :
        // l'ack pump a appliqué tous les submits dans l'ordre, donc
        // ses totaux sont la source de vérité.
        var lastOffsetConsumed = currentOffset
        var chunksSentCount: Int = 0
        var totalBytesSentCount: Int64 = 0
        var sentAnyChunk = false

        await withTaskGroup(of: Void.self) { group in
            for await chunk in readStream {
                // Vérifie d'abord si une tâche enfant a enregistré
                // une erreur : on ne continue pas à spawn si le
                // transfert est déjà condamné.
                if let err = errorSlot.consume() {
                    lastError = err
                    readerTask.cancel()
                    break
                }

                // Vérifie l'état d'activation avant chaque envoi :
                // si la queue a été annulée ou fermée, on arrête
                // immédiatement et on draine les envois en vol.
                guard outgoingTransferQueue.isActive(transferID) else {
                    readerTask.cancel()
                    break
                }

                if chunk.offset < 0 {
                    // Sentinelle d'erreur lecture.
                    lastError = chunk.readError
                    continue
                }

                // Attend un slot libre dans la fenêtre en vol. La
                // suspension permet aux tâches déjà en vol de
                // progresser (et de libérer leur slot à leur tour).
                await window.acquire()

                let capturedTransferID = chunk.transferID
                let capturedOffset = chunk.offset
                let capturedData = chunk.data
                let capturedIsLast = chunk.isLastChunk
                let capturedReadDuration = chunk.readDuration

                group.addTask { [weak self] in
                    do {
                        // Appel direct à la variante statique
                        // `nonisolated` du manager, avec le snapshot
                        // pré-capturé. Aucun saut MainActor par
                        // chunk : c'est la clé du gain de débit.
                        try await OutgoingTransferManager
                            .sendChunkOverConnectionStatic(
                                transferID: capturedTransferID,
                                offset: capturedOffset,
                                data: capturedData,
                                isLastChunk: capturedIsLast,
                                chunkSize: chunkSizeForTasks,
                                snapshot: snapshotForTasks,
                                frameCodec: frameCodec,
                                connection: connectionForTasks
                            )
                        // L'acquittement est appliqué en ordre strict
                        // par le pump : si le chunk N+1 termine avant
                        // N, son compteur attend que N soit passé.
                        await pump.submit(
                            offset: capturedOffset,
                            bytes: Int64(capturedData.count),
                            readDuration: capturedReadDuration
                        )
                        // Incrément atomique pour le batching UI :
                        // on ne traverse le MainActor qu'une fois
                        // tous les `uiBatchStride` chunks, pas à
                        // chaque chunk. Cela évite de saturer le
                        // sérialiseur du main thread (qui bridait
                        // le pipeline à ~4 chunks/s avant le refactor)
                        // tout en gardant la progression visible
                        // (~30 updates/s sur 1 Go / 2 Mio).
                        // Le dernier chunk force TOUJOURS la mise à
                        // jour pour garantir `progress == 100%` à
                        // l'UI.
                        let ackIndex = await pump.ackCount
                        let shouldUpdateUI = capturedIsLast
                            || (ackIndex % uiBatchStride == 0)

                        if shouldUpdateUI {
                            let snap = await pump.snapshot()
                            await MainActor.run {
                                transferMgr.updateProgress(
                                    transferID: transferIDForTasks,
                                    transferredBytes: snap.lastOffsetConsumed
                                )
                                // `restartTransferActivityTimeout` est
                                // une méthode de `self` (MainActor) : on
                                // l'invoque dans le même Run pour éviter
                                // une suspension supplémentaire. `self`
                                // est capturé faiblement par sécurité
                                // (le `withTaskGroup` parent garantit
                                // qu'on est toujours vivant pendant
                                // l'exécution, mais le compilateur
                                // l'ignore).
                                self?.restartTransferActivityTimeout(
                                    transferID: transferIDForTasks
                                )
                            }
                        }
                    } catch {
                        errorSlot.record(error)
                        readerTask.cancel()
                    }
                    // Le slot est toujours libéré, y compris en cas
                    // d'erreur : sans `defer`/`finally` on s'assure
                    // que la fenêtre ne fuit pas.
                    await window.release()
                }
            }

            // Attend la fin de toutes les tâches en vol avant de
            // continuer. Cela garantit que le snapshot du pump est
            // complet (tous les submits ont été appliqués ou ont
            // errored).
            await group.waitForAll()
        }

        // Snapshot final du pump (toutes les tâches ont été drainées).
        let finalSnapshot = await pump.snapshot()
        lastOffsetConsumed = finalSnapshot.lastOffsetConsumed
        chunksSentCount = finalSnapshot.chunkCount
        totalBytesSentCount = finalSnapshot.totalBytes
        lastReadDuration = finalSnapshot.lastReadDuration
        sentAnyChunk = chunksSentCount > 0

        // 3. Nettoyage systématique.
        outgoingFileHandles.removeValue(forKey: transferID)
        try? fileHandle.close()
        TransferPerformanceLog.finish(transferID: transferID)

        if let error = lastError {
            // Lecture ou envoi échoué.
            guard outgoingTransferQueue.isActive(transferID) else {
                return
            }
            if NetworkErrorClassifier.isRecoverableNetworkInterruption(error) {
                logger.info("Interruption réseau pendant l'envoi : \(error.localizedDescription, privacy: .public)")
                interruptOutgoingTransfer(transferID: transferID)
                return
            }
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            logger.error("Échec d'envoi : \(error.localizedDescription, privacy: .public)")
            return
        }

        guard sentAnyChunk else {
            // Fichier vide ou aucune lecture : on ne déclare pas
            // succès, on marque l'échec pour éviter une complétion
            // silencieuse qui ne déclencherait pas de `transferCompleted`.
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            logger.error("Aucun morceau envoyé pour \(transferID, privacy: .public)")
            return
        }

        // 4. Garde-fou d'intégrité : on vérifie que la somme des chunks
        //    envoyés correspond bien à la taille de fichier annoncée.
        //    Si ce n'est pas le cas, c'est qu'un chunk a été perdu en
        //    route (buffer borné, écrasement, etc.) et on lève une
        //    erreur AVANT d'envoyer un `transferCompleted` mensonger.
        if let expectedSize = expectedTotalSize,
           totalBytesSentCount != expectedSize {
            logger.error("Intégrité pipeline : \(totalBytesSentCount) octets envoyés pour \(expectedSize) attendus (\(chunksSentCount) chunks)")
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            throw PipelineIntegrityError(
                expected: expectedSize,
                sent: totalBytesSentCount,
                chunks: chunksSentCount
            )
        }

        // 5. Envoi du `transferCompleted` et armement du timeout de
        //    confirmation finale. Identique à l'ancien chemin.
        connectionManager.sendTransferCompleted(
            transferID: transferID,
            totalBytes: lastOffsetConsumed,
            sha256: fileSHA256
        )
        transferTimeoutManager.cancel(transferID: transferID)
        transferTimeoutManager.start(
            transferID: transferID,
            kind: .completionConfirmation,
            duration: .seconds(30)
        ) { [weak self] in
            guard let self else { return }
            logger.warning("Confirmation finale non reçue : \(transferID, privacy: .public)")
            self.transferManager.markFailed(transferID: transferID)
            self.finishOutgoingTransfer(transferID: transferID)
        }
        logger.info("Tous les morceaux ont été envoyés : \(lastOffsetConsumed) octets (\(chunksSentCount) chunks)")
    }

    /// Structure interne au pipeline d'envoi async : un chunk lu depuis
    /// le fichier, prêt à être chiffré puis envoyé. `offset == -1`
    /// signale une erreur de lecture (champ `readError`).
    private struct PipelineChunk: Sendable {
        let transferID: UUID
        let offset: Int64
        let data: Data
        let isLastChunk: Bool
        let readDuration: Double
        var readError: Error? = nil
    }

    /// Sémaphore compteur bornant la fenêtre en vol de chunks dans
    /// `runChunkPipeline`. Jusqu'à `limit` chunks peuvent être en
    /// transit simultanément ; les autres attendent passivement
    /// qu'un slot se libère via une `CheckedContinuation`.
    ///
    /// Le pattern `waiters.first`-prioritaire transfère le slot
    /// d'une libération à l'acquéreur en attente sans repasser
    /// par la valeur 0 : cela évite une fenêtre de course où deux
    /// acquéreurs pourraient croire disposer du slot.
    ///
    /// Exposé en `internal` (et non `private`) pour que les tests
    /// de régression puissent l'instancier directement et exercer
    /// le type de production, pas un doublon. Le code de production
    /// reste dans ce fichier, donc le type n'est pas exposé hors
    /// du module.
    actor PipelineWindow {
        private var inFlight = 0
        private let limit: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// Pic d'occupation de la fenêtre observé en interne. Mis à
        /// jour à chaque `acquire()` (chemin rapide) et à chaque
        /// `release()` (transfert de slot). Utile pour l'instrumentation
        /// et les tests de non-régression sur la back-pressure.
        private(set) var maxObservedInFlight: Int = 0

        init(limit: Int) {
            self.limit = limit
        }

        func acquire() async {
            if inFlight < limit {
                inFlight += 1
                maxObservedInFlight = max(maxObservedInFlight, inFlight)
                return
            }
            // Anti-fuite de continuation : si la `Task` appelante est
            // annulée pendant l'attente, la continuation abandonnée
            // doit être retirée de la queue sans être resumée. Sinon,
            // elle s'accumule comme une entrée morte et consomme un
            // slot à perpétuité.
            //
            // Le handler `onCancel` tourne HORS de l'actor : on ré-entre
            // par `Task { await ... }` pour respecter l'isolation
            // d'acteur. Si la continuation a déjà été reprise par
            // `release()` (transfert au prochain acquéreur) entre
            // l'`onCancel` et l'exécution de la `Task`, le retrait
            // échoue silencieusement (`firstIndex` ne trouve rien),
            // ce qui est correct.
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    waiters.append(continuation)
                }
            } onCancel: { [weak self] in
                // La `Task` interne ne capture que `self` faiblement
                // pour ne pas maintenir une référence sur l'actor si
                // l'instance a été détruite avant que le cancel ne
                // soit délivré.
                Task { [weak self] in
                    await self?.removeFirstWaiter()
                }
            }
            // Slot acquis (soit par le chemin rapide, soit après
            // reprise via `release()`) : on met à jour le pic.
            maxObservedInFlight = max(maxObservedInFlight, inFlight)
        }

        func release() {
            if let next = waiters.first {
                // Transfère directement le slot au prochain
                // acquéreur : `inFlight` reste constant.
                waiters.removeFirst()
                next.resume()
                return
            }
            inFlight = max(0, inFlight - 1)
        }

        /// Retire la première continuation en attente, sans la
        /// resumer. Utilisé par le handler `onCancel` de `acquire()`
        /// pour ne pas laisser une continuation morte bloquer un
        /// slot à perpétuité après une annulation.
        ///
        /// Retire uniquement la première pour préserver le FIFO :
        /// chaque appelant de `acquire()` annulé supprime *sa*
        /// continuation, qui est forcément en tête de file (les
        /// `release()` ne retirent que `waiters.first`).
        private func removeFirstWaiter() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst()
        }

        /// Utilisé en debug / tests : retourne le nombre d'envois
        /// actuellement en vol. N'est pas appelé dans le chemin
        /// nominal.
        func currentInFlight() -> Int { inFlight }
    }

    /// Sérialise l'application des acquittements de chunks dans
    /// l'ordre strict d'émission (offset croissant). Plusieurs chunks
    /// peuvent être en vol simultanément, mais le compteur global
    /// `totalBytes` et la position du dernier offset acquitté
    /// (`lastOffsetConsumed`) n'avancent que dans l'ordre.
    ///
    /// L'algorithme : une map `pending` indexée par offset conserve
    /// les acquittements qui arrivent avant leur tour (suspendus
    /// via `CheckedContinuation`). Quand un acquittement in-order
    /// est appliqué, on draine `pending` autant que possible
    /// (offsets contigus au nouvel `nextOffset`) en reprenant
    /// chaque continuation.
    ///
    /// Exposé en `internal` (et non `private`) pour que les tests
    /// de régression puissent l'instancier directement et exercer
    /// le type de production, pas un doublon.
    actor OrderedAckPump {
        private var nextOffset: Int64
        private var pending: [Int64: PendingAck] = [:]
        private(set) var totalBytes: Int64 = 0
        private(set) var chunkCount: Int = 0
        private(set) var lastOffsetConsumed: Int64
        private(set) var lastReadDuration: Double = 0
        /// Nombre total d'appels à `submit()` (acks reçus, dans
        /// l'ordre ou hors ordre). Utilisé pour le batching UI : on
        /// ne traverse le MainActor qu'une fois tous les N acks,
        /// pas à chaque ack.
        private(set) var ackCount: Int = 0

        private struct PendingAck {
            let bytes: Int64
            let readDuration: Double
            let cont: CheckedContinuation<Void, Never>
        }

        init(startOffset: Int64) {
            self.nextOffset = startOffset
            self.lastOffsetConsumed = startOffset
        }

        /// Soumet un acquittement de chunk. Suspend jusqu'à ce que
        /// tous les chunks d'offset inférieur aient été acquittés,
        /// puis applique celui-ci et draine les suivants.
        func submit(
            offset: Int64,
            bytes: Int64,
            readDuration: Double
        ) async {
            ackCount += 1
            if offset == nextOffset {
                applyInOrder(
                    offset: offset,
                    bytes: bytes,
                    readDuration: readDuration
                )
                drainPending()
                return
            }
            // Hors ordre : on attend notre tour.
            //
            // Anti-fuite de continuation : si la `Task` appelante est
            // annulée pendant l'attente, la continuation abandonnée
            // doit être retirée du `pending` sans être resumée. Sinon,
            // l'entrée reste en map comme un acquittement mort, et
            // `drainPending` pourrait la reprendre sans contexte valide.
            //
            // Le handler `onCancel` tourne HORS de l'actor : on ré-entre
            // par `Task { await ... }` pour respecter l'isolation
            // d'acteur. Si l'entrée a déjà été reprise par
            // `drainPending` (l'offset est devenu `nextOffset`),
            // `removeValue` renvoie `nil` et l'opération est sans
            // effet — comportement correct.
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    (cont: CheckedContinuation<Void, Never>) in
                    pending[offset] = PendingAck(
                        bytes: bytes,
                        readDuration: readDuration,
                        cont: cont
                    )
                }
            } onCancel: { [weak self] in
                Task { [weak self] in
                    await self?.removePending(offset: offset)
                }
            }
        }

        /// Retire l'entrée `pending` pour l'offset donné, sans
        /// resumer sa continuation. Utilisé par le handler
        /// `onCancel` de `submit()` pour ne pas laisser une
        /// continuation morte bloquer un offset dans la map après
        /// une annulation.
        private func removePending(offset: Int64) {
            pending.removeValue(forKey: offset)
        }

        private func applyInOrder(
            offset: Int64,
            bytes: Int64,
            readDuration: Double
        ) {
            nextOffset += bytes
            lastOffsetConsumed = offset + bytes
            totalBytes += bytes
            chunkCount += 1
            // `lastReadDuration` du pump reflète le dernier ack
            // *appliqué* (donc dans l'ordre), pas le dernier ack
            // *reçu* : c'est le comportement souhaité, aligné sur
            // le code séquentiel d'origine.
            lastReadDuration = readDuration
        }

        private func drainPending() {
            while let head = pending.removeValue(forKey: nextOffset) {
                nextOffset += head.bytes
                lastOffsetConsumed += head.bytes
                totalBytes += head.bytes
                chunkCount += 1
                lastReadDuration = head.readDuration
                head.cont.resume()
            }
        }

        struct Snapshot {
            let totalBytes: Int64
            let chunkCount: Int
            let lastOffsetConsumed: Int64
            let lastReadDuration: Double
        }

        func snapshot() -> Snapshot {
            Snapshot(
                totalBytes: totalBytes,
                chunkCount: chunkCount,
                lastOffsetConsumed: lastOffsetConsumed,
                lastReadDuration: lastReadDuration
            )
        }
    }

    /// Stockage d'erreur partagé entre les tâches enfant du
    /// `withTaskGroup` et la boucle principale. La boucle
    /// principale lit l'erreur via `consume()` au début de chaque
    /// itération pour stopper le producteur et sortir
    /// proprement. Une seule erreur est conservée (la première) :
    /// les suivantes sont ignorées car le transfert est de toute
    /// façon condamné.
    ///
    /// Exposé en `internal` (et non `private`) pour que les tests
    /// de régression puissent l'instancier directement et exercer
    /// le type de production, pas un doublon.
    final class PipelineErrorSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var _error: Error?

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if _error == nil { _error = error }
        }

        /// Lit l'erreur enregistrée puis l'efface, pour qu'une
        /// seconde consultation (par une autre itération) ne la
        /// revoie pas. C'est la sémantique "edge-triggered"
        /// attendue par la boucle principale.
        func consume() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            let value = _error
            _error = nil
            return value
        }
    }



    func dismissPendingTransferRequest() {
        pendingApprovalCoordinator.clear()
    }

    private func appendPendingTransferRequest(
        _ request: PendingTransferRequest
    ) {
        pendingApprovalCoordinator.append(request)
    }

    private func clearPendingTransferBatch(
        transferIDs: Set<UUID>
    ) {
        pendingApprovalCoordinator.remove(
            transferIDs: transferIDs
        )
    }

    private func pendingRequests() -> [PendingTransferRequest] {
        pendingApprovalCoordinator.requests
    }

    private func markOutgoingTransferApproved(_ transferID: UUID) {
        approvedOutgoingTransfers.insert(transferID)
        if let entry = outgoingTransferQueue.allEntries.first(where: { $0.id == transferID }),
           outgoingTransferQueue.isActive(transferID) {
            beginOutgoingTransfer(entry)
        }
    }

    private func sendFileChunks(
        transferID: UUID,
        fileURL: URL
    ) {
        do {
            let sha256 = try FileHasher.sha256(
                of: fileURL
            )

            transferManager.setSHA256(
                transferID: transferID,
                sha256: sha256
            )

            let fileHandle = try FileHandle(
                forReadingFrom: fileURL
            )

            outgoingFileHandles[transferID] = fileHandle

            // La taille lue sur le disque, et non celle du transfert : c'est
            // ce fichier-ci que l'on découpe. Une lecture qui échoue laisse
            // la taille à zéro, donc le découpage d'origine.
            let fileSize = (
                try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey]
                )
                .fileSize
            )
            .map(Int64.init) ?? 0

            let chunkSize = TransferChunkSizing.chunkSize(
                forFileSize: fileSize
            )

            logger.info(
                "Morceaux de \(chunkSize / 1024) Kio pour \(fileSize) octets"
            )

            TransferPerformanceLog.begin(
                transferID: transferID,
                mode: "NORMAL",
                chunkSize: chunkSize
            )

            sendNextChunk(
                transferID: transferID,
                fileHandle: fileHandle,
                fileSHA256: sha256,
                offset: 0,
                chunkSize: chunkSize,
                expectedTotalSize: fileSize
            )

        } catch {
            logger.error(
                "Impossible de préparer le fichier : \(error.localizedDescription, privacy: .public)"
            )

            self.transferTimeoutManager.cancel(
                transferID: transferID
            )
            
            transferManager.markFailed(
                transferID: transferID
            )

            finishOutgoingTransfer(
                transferID: transferID
            )
        }
    }


    private func configureBindings() {
        // Configure notification categories at startup
        notificationManager.configureCategories()

        // Chargement de l'état de reprise au démarrage : scanner le dossier
        // des métadonnées et restaurer les transferts interrompus.
        Task { @MainActor in
            do {
                let dir = ResumePersistence.directory()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let files = try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "json" }

                for file in files {
                    let transferID = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                    guard transferID != nil else { continue }

                    let persistence = ResumePersistence(url: file)
                    guard let info = try await persistence.load() else {
                        // Métadonnée illisible : orpheline, on la retire
                        // plutôt que de la laisser s'accumuler.
                        try? await persistence.clear()
                        continue
                    }

                    guard let reconciledBytes =
                        Self.resolvedRestorationBytes(for: info) else {
                        // Le `.partial` n'existe plus : les octets reçus sont
                        // perdus, la métadonnée ne décrit plus rien de réel.
                        logger.info("Métadonnée orpheline (`.partial` absent) : \(info.transferID, privacy: .public)")
                        try? await persistence.clear()
                        continue
                    }

                    self.transferManager.restoreInterruptedTransfer(
                        info: info,
                        transferredBytes: reconciledBytes
                    )

                    logger.info("Reprise restaurée : \(info.transferID, privacy: .public) — \(reconciledBytes)/\(info.fileSize) octets")
                }
            } catch {
                logger.error("Erreur chargement reprises : \(error.localizedDescription, privacy: .public)")
            }
        }

        pendingApprovalCoordinator.onReadyChanged = { [weak self] in
            guard let self else {
                return
            }

            self.pendingTransferBatch =
                self.pendingApprovalCoordinator.presentableBatch
        }

        outgoingTransferQueue.onActivate = { [weak self] entry in
            self?.activateOutgoingTransfer(entry)
        }

        bonjourService.onIncomingConnection = { [weak connectionManager] connection in
            connectionManager?.accept(connection)
        }

        // Redécouverte Bonjour d'un pair : signal de reprise automatique.
        //
        // Une coupure Wi-Fi invalide l'adresse connue ; seule la
        // redécouverte fournit une endpoint fraîche. Quand des transferts
        // interrompus appartiennent au pair retrouvé, la connexion est
        // relancée ici : sans cet appel, la campagne attendait indéfiniment
        // une session que personne ne déclenchait (reprises « reportées »
        // en boucle observées sur le terrain). La tâche de backoff ne fait
        // qu'attendre la session — jamais une vieille adresse n'est rejetée
        // aveuglément, seule l'endpoint fraîche sert.
        bonjourService.onDeviceDiscovered = { [weak self] discovered in
            guard let self else { return }
            guard self.connectionManager.session == nil else { return }

            let device = discovered.device

            let hasInterruptedForPeer = self.transferManager.transfers.contains {
                $0.state == .interrupted && $0.peer.id == device.id
            }

            guard hasInterruptedForPeer else { return }

            logger.info("Pair redécouvert avec reprises en attente : \(device.name, privacy: .public)")
            self.lastKnownPeerID = device.id
            self.connectionManager.rememberConnectedPeer(device)
            // La redécouverte fournit une endpoint fraîche : c'est la seule
            // porte de sortie après une campagne invalidée par un échec. La
            // campagne elle-même ne s'ouvrira qu'à la confirmation `.ready`
            // (via `onSessionReady`), avec une seule tâche par transfert.
            self.connectionManager.connect(to: discovered)
        }

        connectionManager.onSessionReady = { [weak self] connection in
            guard let self else { return }
            self.transferManager.outgoingManager.setConnection(connection)

            // Déterminer le rôle de ce pair dans le handshake.
            //
            // Sur un réseau local, les deux pairs se découvrent en
            // général mutuellement et **chacun accepte la connexion
            // entrante de l'autre**. Sans cette distinction, les deux
            // pairs lançaient leur propre `keyExchange` en parallèle,
            // chacun avec son propre `sessionId` LOCAL. Résultat : les
            // deux `keyExchange` se croisaient, chaque pair adoptait le
            // `sessionId` de l'autre, puis les `keyExchangeAck`
            // arrivaient avec un `sessionId` qui ne correspondait plus
            // au `activeSessionId` du moment → rejet (« sessionId
            // incohérent »), puis tous les chunks binaires v2 étaient
            // rejetés à la réception.
            //
            // Convention de rôle, calquée sur la direction TCP :
            //  - **Initiateur** : la session a été ouverte par un
            //    `connect()` (`.outgoing`). C'est ce pair qui génère
            //    le `sessionId` partagé et l'envoie dans son
            //    `keyExchange`. L'autre pair l'adopte puis renvoie un
            //    `keyExchangeAck` avec le même `sessionId`.
            //  - **Répondeur** : la session a été acceptée par le
            //    listener (`.incoming`). Ce pair NE doit PAS envoyer
            //    son propre `keyExchange` : il attend celui de
            //    l'initiateur, l'adopte, et répond par un
            //    `keyExchangeAck`.
            //
            // Si les deux pairs se considèrent comme initiateurs
            // (ex. connexions sortantes croisées), le perdant du
            // `guard session == nil` voit sa connexion annulée et ne
            // passe jamais par `onSessionReady` (cf.
            // `ConnectionManager.connect`).
            let isInitiator = self.connectionManager.session?.direction == .outgoing

            if isInitiator {
                // Générer un identifiant de session unique pour lier
                // les chunks binaires v2 à cette session. C'est cet
                // UUID qui sera partagé avec le pair via le
                // `keyExchange` sortant.
                let newSessionId = UUID()
                self.connectionManager.setActiveSessionId(newSessionId)
                self.transferManager.outgoingManager.setSessionId(newSessionId)

                // Initier le handshake ECDH P-256 : on envoie notre clé
                // publique éphémère et notre `sessionId` partagé via
                // `keyExchange`. Le pair répondra par `keyExchangeAck`
                // et les deux côtés installeront alors la clé
                // symétrique de session.
                self.initiateECDHHandshake()
            } else {
                // Côté répondeur : on NE génère PAS de `sessionId`
                // LOCAL et on N'envoie PAS de `keyExchange`. On attend
                // que l'initiateur nous envoie son `keyExchange` ; on
                // adoptera alors son `sessionId` (cf.
                // `handleKeyExchange`).
                logger.info("Session entrante — j'attends le keyExchange de l'initiateur")
            }

            if let device = self.connectionManager.connectedDevice {
                self.lastKnownPeerID = device.id
                self.connectionManager.rememberConnectedPeer(device)

                // Initier le pairage si le pair n'est pas encore de confiance
                if !self.pairingStore.isTrusted(device.id)
                    && !self.pairingStore.isBlocked(device.id) {
                    self.initiatePairing(with: device, on: connection)
                }
            }
            // Une session vient de s'établir (état `.ready` confirmé) :
            // c'est ici — et seulement ici — qu'une reprise peut partir.
            self.scheduleAutomaticResumeOnReconnect()
        }

        connectionManager.onSessionClosed = { [weak self] lostPeer in
            guard let self else {
                return
            }

            // 1. Identifier le pair associé à la session perdue.
            //
            // Le pair est reçu en paramètre (extrait avant la destruction de
            // la session), avec le dernier pair mémorisé en repli : une
            // session précédemment connectée ne doit jamais produire
            // « Déconnexion sans pair identifié ».
            let identifiedPeer =
                lostPeer ?? self.connectionManager.lastConnectedPeer

            guard !self.isCleaningUpSession else {
                logger.info("Nettoyage de session déjà effectué")
                return
            }

            self.isCleaningUpSession = true

            // La session vient de tomber : la campagne de reprise en cours
            // (s'il y en a une) est invalidée. Elle ne repartira que sur une
            // redécouverte Bonjour fraîche, jamais sur l'ancienne endpoint.
            self.endResumeCampaign()

            // Oublier le sessionId : un nouveau sera généré à la prochaine
            // reconnexion (les chunks de l'ancienne session ne doivent pas
            // pouvoir être acceptés par la suivante).
            self.connectionManager.setActiveSessionId(nil)
            self.transferManager.outgoingManager.setSessionId(nil)
            self.hasAdoptedSessionIdFromKeyExchange = false

            // Oublier aussi la clé de chiffrement : sur reconnexion, un
            // nouveau handshake ECDH générera une nouvelle clé
            // symétrique. Sans ce nettoyage, l'ancien chiffrement resterait
            // actif contre un nouveau `sessionId`, ce qui ferait rejeter
            // les chunks (l'AAD contient le sessionId).
            self.transferManager.outgoingManager.clearSessionKey()
            self.transferManager.incomingManager.clearSessionKey()
            self.pendingECDHHandshake = nil

            if let identifiedPeer {
                self.lastKnownPeerID = identifiedPeer.id
                logger.info("Déconnexion du pair : \(identifiedPeer.name, privacy: .public)")
            } else {
                logger.info("Déconnexion sans pair jamais identifié : rien à interrompre")
            }

            // Oublier les challenges de pairage en attente : un pair
            // déconnecté ne répondra jamais, et garder son challenge
            // en mémoire empêcherait un nouveau handshake propre plus
            // tard (ou accumulerait des entrées fantômes).
            self.pendingPairingChallenges.removeAll()

            // 2/3. Identifier puis interrompre les transferts actifs, avec
            // leur progression conservée et leurs métadonnées persistées.
            let interruptedIDs: [UUID]

            if let identifiedPeer {
                interruptedIDs = self.transferManager.interruptActiveTransfers(
                    peerID: identifiedPeer.id,
                    peerName: identifiedPeer.name,
                    protocolVersion: ProtocolCompatibility.currentVersion
                )
            } else {
                interruptedIDs = []
            }

            // 4. Arrêter proprement le pipeline sortant.
            self.startedOutgoingTransfers.removeAll()
            self.approvalRequestsSent.removeAll()
            self.approvedOutgoingTransfers.removeAll()
            self.transferTimeoutManager.cancelAll()
            self.pendingApprovalCoordinator.clear()

            let fileHandles = Array(
                self.outgoingFileHandles.values
            )
            self.outgoingFileHandles.removeAll()

            for fileHandle in fileHandles {
                try? fileHandle.close()
            }

            // Une déconnexion n'est pas un échec : les transferts actifs de
            // ce pair passent à `.interrupted` (non terminal), restent
            // reprisables, et conservent source et `.partial`.
            let queuedEntries = self.outgoingTransferQueue.cancelAll()

            for entry in queuedEntries {
                if interruptedIDs.contains(entry.id) {
                    // Source conservée pour une reprise ultérieure :
                    // la supprimer détruirait l'offset déjà envoyé.
                    continue
                }

                self.transferManager.cleanupOutgoingTransfer(
                    transferID: entry.id
                )
            }

            // 5. Les métadonnées sont déjà écrites par l'interruption. Côté
            // réception : fermer les writers en préservant les `.partial`.
            for transferID in interruptedIDs {
                if let transfer = self.transferManager.transfers.first(where: {
                    $0.id == transferID
                }), transfer.direction == .incoming {
                    self.transferManager.interruptIncomingTransfer(
                        transferID: transferID
                    )
                }
            }

            // Ce nettoyage préserve sources sortantes et `.partial` des
            // transferts visés.
            self.transferManager.finishSessionCleanup(
                preserving: interruptedIDs
            )

            // 6. Seulement maintenant : oublier le pair, la séquence de
            // déconnexion est terminée.
            self.connectionManager.clearLastConnectedPeer()

            // Le drapeau est baissé ici plutôt qu'à `onSessionReady` :
            // une seconde déconnexion peut survenir avant toute
            // reconnexion (refus du pair, réseau instable), et il faut
            // alors pouvoir nettoyer à nouveau. Toute la séquence
            // ci-dessus est déjà idempotente — elle ne trouve plus rien à
            // interrompre si l'état a déjà été nettoyé.
            self.isCleaningUpSession = false
        }
        
        messageRouter.onEvent = { [weak self] event in
            guard let self else { return }
            
            switch event {
                
            case let .hello(message, connection):
                logger.info("Core : HELLO reçu de \(message.sender.name, privacy: .public), version protocole: \(message.protocolVersion)")

                // L'identification du pair est confirmée ici : mémoriser
                // l'identité dès maintenant, pas seulement à la fermeture,
                // pour qu'une coupure brutale trouve toujours un pair connu.
                if self.connectionManager.connectedDevice?.id == message.sender.id {
                    self.lastKnownPeerID = message.sender.id
                }

                // Négocier la version du protocole
                let negotiatedVersion = min(message.protocolVersion, ProtocolCompatibility.currentVersion)
                if negotiatedVersion >= 2 {
                    self.transferManager.outgoingManager.setProtocolVersion(negotiatedVersion)
                    self.connectionManager.setNegotiatedProtocolVersion(negotiatedVersion)
                    logger.info("Version du protocole négociée : v\(negotiatedVersion)")
                }

                self.connectionManager.sendAcknowledgement(
                    on: connection
                )

            case let .acknowledgement(message, _):
                logger.info("Core : ACK reçu de \(message.sender.name, privacy: .public), version protocole: \(message.protocolVersion)")

                // Pour l'initiateur de la connexion, c'est ici qu'on reçoit la version
                // du pair distant (le récepteur répond avec ack qui contient sa version)
                let negotiatedVersion = min(message.protocolVersion, ProtocolCompatibility.currentVersion)
                if negotiatedVersion >= 2 {
                    self.transferManager.outgoingManager.setProtocolVersion(negotiatedVersion)
                    self.connectionManager.setNegotiatedProtocolVersion(negotiatedVersion)
                    logger.info("Version du protocole négociée (via ACK) : v\(negotiatedVersion)")
                }

            case let .pairingRequest(message, connection):
                logger.info("Core : Demande de pairage reçue de \(message.sender.name, privacy: .public)")
                self.handlePairingRequest(message, connection: connection)

            case let .pairingResponse(message, connection):
                logger.info("Core : Réponse de pairage reçue de \(message.sender.name, privacy: .public)")
                self.handlePairingResponse(message, connection: connection)

            case let .keyExchange(message, connection):
                // Échange de clés ECDH P-256 : le pair nous envoie sa clé
                // publique éphémère. On génère la nôtre, on dérive la clé
                // symétrique de session, et on renvoie un `keyExchangeAck`
                // pour que le pair fasse de même.
                self.handleKeyExchange(message: message, connection: connection)

            case let .keyExchangeAck(message, _):
                // Le pair a reçu notre `keyExchange` et nous renvoie sa clé
                // publique. On dérive la clé symétrique et on l'installe
                // dans les deux gestionnaires de chunks.
                self.handleKeyExchangeAck(message: message)


            case let .unknown(message, _):
                logger.warning("Message non pris en charge : \(message.type.rawValue, privacy: .public)")
                
           
            case let .transferRequest(message, connection):
                // Wrapper async : la création du transfert entrant est
                // `await` (le writer est préparé avant de répondre à
                // l'émetteur, pour respecter le contrat `.accepted` =
                // prêt à écrire). Le reste de la branche reste tel quel.
                Task { @MainActor in
                    self.logger.info(
                        "Core : demande de transfert reçue de \(message.sender.name, privacy: .public)"
                    )

                    guard let payloadData = message.payload else {
                        self.logger.error("La demande de transfert ne contient aucun payload")

                        return
                    }

                    do {
                        let request = try self.messageCodec.decodePayload(
                            TransferRequestPayload.self,
                            from: payloadData
                        )

                        self.logger.info("Fichier : \(request.fileName, privacy: .public)")
                        self.logger.info("Taille : \(request.fileSize) octets")
                        self.logger.info("Type : \(request.contentType ?? "inconnu", privacy: .public)")
                        self.logger.info("Transfert : \(request.transferID, privacy: .public)")

                        // Vérification du pair : les appareils de confiance sont
                        // acceptés automatiquement, les bloqués sont refusés,
                        // les inconnus déclenchent la demande utilisateur.
                        let peerID = message.sender.id
                        if self.pairingStore.isBlocked(peerID) {
                            self.logger.warning("Pair bloqué — transfert refusé : \(message.sender.name, privacy: .public)")
                            self.connectionManager.sendTransferRejected(
                                transferID: request.transferID,
                                reason: "pair bloqué",
                                on: connection
                            )
                            return
                        }

                        let isTrusted = self.pairingStore.isTrusted(peerID)
                        if isTrusted {
                            self.logger.info("Pair de confiance — acceptation automatique : \(message.sender.name, privacy: .public)")
                        }

                        let outcome: IncomingRequestOutcome
                        if isTrusted {
                            outcome = await self.transferManager.createIncomingTransferAutoAccepted(
                                request: request,
                                sender: message.sender
                            )
                            if outcome == .accepted {
                                // Auto-acceptation : on confirme immédiatement
                                // à l'émetteur, sans passer par la feuille.
                                self.connectionManager.sendTransferAccepted(
                                    transferID: request.transferID,
                                    on: connection
                                )
                            }
                        } else {
                            outcome = await self.transferManager.createIncomingTransfer(
                                request: request,
                                sender: message.sender
                            )
                        }

                        switch outcome {
                        case .accepted:
                            // Notifier IMMÉDIATEMENT la demande de transfert entrante (AirDrop style)
                            // Avant la fenêtre de coalescence, pour que l'utilisateur voie la notif
                            // pendant qu'il décide d'accepter/refuser
                            self.notificationManager.notifyIncomingTransferRequest(
                                senderName: message.sender.name,
                                fileCount: 1,
                                fileName: request.fileName
                            )

                        case .rejected:
                            // Refusé avant toute question à l'utilisateur : une
                            // annonce hors plafond n'a pas à occuper l'écran, et
                            // l'émetteur doit l'apprendre tout de suite plutôt
                            // qu'au bout de son délai d'attente.
                            self.connectionManager.sendTransferRejected(
                                transferID: request.transferID,
                                reason: "annonce refusée par le récepteur",
                                on: connection
                            )

                            return

                        case .duplicate:
                            // Aucune réponse : un refus porterait l'identifiant
                            // du transfert déjà en cours, et l'avorterait.
                            return
                        }

                        let pendingRequest = PendingTransferRequest(
                            sender: message.sender,
                            request: request,
                            connection: connection
                        )
                        self.appendPendingTransferRequest(pendingRequest)

                        // Le protocole envoie une demande par fichier : le
                        // récepteur ne voit donc jamais la sélection. En
                        // revanche le coordinateur d'autorisation coalesce
                        // déjà les demandes d'une même rafale, et ce lot
                        // d'autorisation tient lieu de sélection ici.
                        if let batchID = self.pendingApprovalCoordinator.batch?.id {
                            self.transferManager.setBatchID(
                                transferID: request.transferID,
                                batchID: batchID
                            )
                        }


                    } catch {
                        self.logger.error("Payload de transfert invalide : \(error.localizedDescription, privacy: .public)")
                    }
                }
                
           
                
            case let .transferAccepted(message, _):
                
                
                guard let payloadData = message.payload else {
                    logger.error("Acceptation sans payload")
                    return
                }
                
                do {
                    let payload = try messageCodec.decodePayload(
                        TransferAcceptedPayload.self,
                        from: payloadData
                    )

                    guard transferManager.hasTransfer(
                        transferID: payload.transferID
                    ) else {
                        logger.info(
                            "Acceptation ignorée pour un transfert inconnu : \(payload.transferID, privacy: .public)"
                        )
                        return
                    }

                    guard approvedOutgoingTransfers.insert(
                        payload.transferID
                    ).inserted else {
                        logger.info(
                            "Acceptation déjà traitée : \(payload.transferID, privacy: .public)"
                        )
                        return
                    }

                    transferTimeoutManager.cancel(
                        transferID: payload.transferID
                    )

                    guard let entry = outgoingTransferQueue.allEntries.first(where: {
                        $0.id == payload.transferID
                    }) else {
                        return
                    }

                    if outgoingTransferQueue.isActive(payload.transferID) {
                        beginOutgoingTransfer(entry)
                    }

                    logger.info("Transfert accepté : \(payload.transferID, privacy: .public)")

                    
                    
                } catch {
                    logger.error("Acceptation invalide : \(error.localizedDescription, privacy: .public)")
                }
                
                
            case let .transferRejected(message, _):
                guard let payloadData = message.payload else {
                    logger.error("Refus sans payload")
                    return
                }
                
                do {
                    let payload = try messageCodec.decodePayload(
                        TransferRejectedPayload.self,
                        from: payloadData
                    )
                    
                    guard !transferManager.isTerminal(
                        transferID: payload.transferID
                    ) else {
                        logger.info("transferRejected déjà traité : \(payload.transferID, privacy: .public)")
                        return
                    }

                    transferTimeoutManager.cancel(
                        transferID: payload.transferID
                    )

                    transferManager.markRejected(
                        transferID: payload.transferID
                    )

                    finishOutgoingTransfer(
                        transferID: payload.transferID
                    )
                    
                    logger.error("Transfert refusé")
                    logger.info("Transfert : \(payload.transferID, privacy: .public)")
                    logger.info("Motif : \(payload.reason ?? "Aucun", privacy: .public)")

                } catch {
                    logger.error("Refus invalide : \(error.localizedDescription, privacy: .public)")
                }
                
                
            case let .fileChunk(message, _):
                Task {
                    await self.handleFileChunk(message: message)
                }

                
            case let .transferCompleted(message, connection):
                Task { @MainActor in
                    await self.handleTransferCompleted(
                        message: message,
                        connection: connection
                    )
                }

            case let .transferSucceeded(message, _):
                handleTransferSucceeded(message: message)

                
            case let .resumeRequest(message, connection):
                guard let payloadData = message.payload else {
                    logger.error("resumeRequest sans payload")
                    return
                }
                do {
                    let payload = try messageCodec.decodePayload(
                        ResumeRequestPayload.self,
                        from: payloadData
                    )
                    let transferID = payload.transferID
                    guard let transfer = transferManager.transfers.first(where: { $0.id == transferID }) else {
                        return
                    }
                    if transfer.direction == .incoming {
                        let written = transferManager.incomingWriterWrittenBytes(transferID: transferID)
                        connectionManager.sendResumeAccepted(
                            transferID: transferID,
                            offset: written,
                            fileName: transfer.fileName,
                            sha256: "",
                            chunkSize: TransferChunkSizing.chunkSize(forFileSize: transfer.fileSize),
                            fileSize: transfer.fileSize,
                            on: connection
                        )
                    }
                } catch {
                    logger.error("resumeRequest invalide")
                }

            case let .resumeAccepted(message, _):
                // La connexion du message n'est pas utilisée ici : l'envoi
                // repart par le pipeline sortant courant, déjà rattaché à la
                // session active via `onSessionReady`.
                guard let payloadData = message.payload else {
                    logger.error("resumeAccepted sans payload")
                    return
                }
                do {
                    let payload = try messageCodec.decodePayload(
                        ResumeAcceptedPayload.self,
                        from: payloadData
                    )
                    let transferID = payload.transferID
                    guard transferManager.hasTransfer(transferID: transferID) else { return }
                    if let entry = outgoingTransferQueue.allEntries.first(where: { $0.id == transferID }) {
                        // reprendre à l'offset donné
                        // La source temporaire peut avoir disparu (nettoyage,
                        // redémarrage) : dans ce cas la reprise est simplement
                        // abandonnée plutôt que laissée en erreur.
                        guard let fileURL = try? transferManager.outgoingFileURL(
                            transferID: transferID
                        ), let fileHandle = try? FileHandle(
                            forReadingFrom: fileURL
                        ) else {
                            logger.error("Source introuvable pour la reprise : \(transferID, privacy: .public)")
                            return
                        }
                        // Un offset au-delà de la fin de fichier est
                        // impossible ici : il vient du récepteur, qui n'a
                        // accepté que les octets qu'il a réellement écrits.
                        fileHandle.seek(toFileOffset: UInt64(payload.offset))
                        outgoingFileHandles[transferID] = fileHandle

                        // AUCUN hachage ici : recalculer le SHA-256 complet
                        // de la source bloquerait le fil principal pendant
                        // toute une relecture du fichier avant le premier
                        // chunk repris. La empreinte calculée au premier
                        // envoi (`sendFileChunks`) est conservée dans le
                        // transfert ; si elle manque, elle reste vide et
                        // l'intégrité finale repose sur le contrôle du
                        // récepteur — inchangé.
                        let sourceSHA256 =
                            transferManager.transfers.first {
                                $0.id == transferID
                            }?.sha256 ?? ""
                        // La reprise est une continuation : la durée de
                        // transfert affichée repart de maintenant, sinon le
                        // temps d'interruption s'ajoute et écrase le débit
                        // mesuré (`recordHistory` divise par cette durée).
                        transferManager.resetStartedAt(transferID: transferID)
                        transferManager.markAccepted(transferID: transferID)
                        sendNextChunk(
                            transferID: transferID,
                            fileHandle: fileHandle,
                            fileSHA256: sourceSHA256,
                            offset: payload.offset,
                            chunkSize: TransferChunkSizing.chunkSize(forFileSize: entry.fileSize),
                            performanceMode: "RESUME",
                            expectedTotalSize: entry.fileSize
                        )
                    }
                } catch {
                    logger.error("resumeAccepted invalide")
                }

            case let .transferFailed(message, _):
                handleTransferFailed(message: message)
                
            case let .transferCancelled(message, _):
                handleTransferCancelled(
                    message: message
                )

            }
        }
    }

    // MARK: - Pairage

    /// Initie (ou relance) un pairage avec le pair actuellement connecté.
    ///
    /// Variante pratique pour l'UI : on lit la session active et le pair
    /// distant, et on lance le handshake si les conditions sont réunies.
    /// - Returns: `true` si une demande a effectivement été envoyée.
    @discardableResult
    func requestPairingIfNeeded() -> Bool {
        guard let peer = connectionManager.connectedDevice,
              let connection = connectionManager.session?.connection else {
            logger.info("Pas de session active, impossible de pairer")
            return false
        }
        initiatePairing(with: peer, on: connection)
        return true
    }

    /// Initie un pairage avec un pair : envoie une demande contenant
    /// notre clé publique signée avec un challenge.
    func initiatePairing(
        with peer: Device,
        on connection: NWConnection
    ) {
        // Ne pas ré-initier un pairage avec un pair déjà de confiance.
        if pairingStore.isTrusted(peer.id) {
            logger.info("Le pair \(peer.name, privacy: .public) est déjà de confiance, pas de pairage")
            return
        }
        if pairingStore.isBlocked(peer.id) {
            logger.warning("Le pair \(peer.name, privacy: .public) est bloqué, refus de pairage")
            return
        }

        let challenge = PairingHandshake.generateChallenge()
        pendingPairingChallenges[peer.id] = challenge

        connectionManager.sendPairingRequest(
            peerID: localDeviceForPairing().id,
            peerName: localDeviceForPairing().name,
            challenge: challenge,
            on: connection
        ) { [weak self] result in
            switch result {
            case .success:
                self?.logger.info("Demande de pairage envoyée à \(peer.name, privacy: .public)")
            case .failure(let error):
                self?.logger.error("Échec d'envoi de la demande de pairage : \(error.localizedDescription, privacy: .public)")
                self?.pendingPairingChallenges.removeValue(forKey: peer.id)
            }
        }
    }

    /// Traite une demande de pairage reçue : si on est l'initiateur en
    /// attente de la réponse, c'est la réponse qu'on reçoit. Sinon, c'est
    /// le pair qui initie : on lui renvoie un nouveau challenge signé.
    private func handlePairingRequest(
        _ message: AirBridgeMessage,
        connection: NWConnection
    ) {
        guard let payloadData = message.payload else {
            logger.error("Demande de pairage sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                PairingPayload.self,
                from: payloadData
            )

            let peerID = message.sender.id

            // Si on a déjà un challenge en attente pour ce pair, c'est sa
            // réponse à notre demande : on la vérifie avec ce challenge.
            if let ourChallenge = pendingPairingChallenges[peerID] {
                let result = pairingHandshake.verifyPairingPayload(
                    payload,
                    expectedChallenge: ourChallenge
                )
                pendingPairingChallenges.removeValue(forKey: peerID)

                switch result {
                case .success(let info):
                    logger.info("Pairage réussi avec \(info.peerName, privacy: .public)")
                    // Empreinte omise volontairement : matériel cryptographique
                    // sensible, jamais journalisé.
                case .invalidSignature:
                    logger.error("Signature de pairage invalide de \(message.sender.name, privacy: .public)")
                case .challengeMismatch:
                    logger.error("Challenge de pairage incorrect de \(message.sender.name, privacy: .public)")
                case .protocolVersionMismatch:
                    logger.error("Version de protocole incompatible avec \(message.sender.name, privacy: .public)")
                case .selfPairingAttempt:
                    logger.warning("Tentative d'auto-pairage détectée")
                }
                return
            }

            // Sinon, c'est une demande entrante : on signe le challenge
            // reçu et on le renvoie dans notre réponse (le handshake est
            // un challenge-response : l'initiateur envoie un challenge, le
            // répondeur le signe avec sa clé privée et le renvoie tel quel).
            // Si le pair est bloqué, on ne répond pas.
            if pairingStore.isBlocked(peerID) {
                logger.warning("Demande de pairage ignorée d'un pair bloqué : \(message.sender.name, privacy: .public)")
                return
            }

            // On vérifie la signature du PairingPayload reçu AVANT d'y
            // répondre, et on enregistre le pair dans le PairingStore si
            // la vérification réussit. Sans cela, le répondeur reste
            // inconnu pour lui-même : il accepterait bien la réponse
            // (le MAC confirme qu'il a bien signé le challenge) mais
            // rejetterait ensuite tous les messages du pair (transferRequest
            // etc.) parce que ce pair ne serait pas dans son PairingStore.
            let verifyResult = pairingHandshake.verifyIncomingPairingRequest(payload)
            switch verifyResult {
            case .success(let info):
                logger.info("Pair \(info.peerName, privacy: .public) authentifié (signature ECDSA valide)")
            case .invalidSignature:
                logger.error("Signature de pairage invalide de \(message.sender.name, privacy: .public) — réponse non envoyée")
                return
            case .protocolVersionMismatch:
                logger.error("Version de protocole incompatible avec \(message.sender.name, privacy: .public) — réponse non envoyée")
                return
            case .selfPairingAttempt:
                logger.warning("Tentative d'auto-pairage détectée de \(message.sender.name, privacy: .public)")
                return
            case .challengeMismatch:
                // Pas applicable ici (pas de challenge en attente), mais
                // couvert par le compilateur : on ne devrait jamais le
                // voir. Au cas où, on refuse par sécurité.
                logger.error("Réponse de pairage refusée (challenge inattendu)")
                return
            }

            // On garde le même challenge en attente : c'est celui que
            // l'initiateur attend dans sa réponse pour confirmer qu'on a
            // bien signé ce qu'il a envoyé.
            pendingPairingChallenges[peerID] = payload.challenge

            connectionManager.sendPairingResponse(
                peerID: localDeviceForPairing().id,
                peerName: localDeviceForPairing().name,
                challenge: payload.challenge,
                on: connection
            ) { [weak self] result in
                if case .failure(let error) = result {
                    self?.logger.error("Échec d'envoi de la réponse de pairage : \(error.localizedDescription, privacy: .public)")
                    self?.pendingPairingChallenges.removeValue(forKey: peerID)
                }
            }
            logger.info("Réponse de pairage envoyée à \(message.sender.name, privacy: .public)")

        } catch {
            logger.error("Payload de pairage invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Traite une réponse de pairage reçue (notre challenge signé par le pair).
    private func handlePairingResponse(
        _ message: AirBridgeMessage,
        connection: NWConnection
    ) {
        guard let payloadData = message.payload else {
            logger.error("Réponse de pairage sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                PairingPayload.self,
                from: payloadData
            )

            guard let ourChallenge = pendingPairingChallenges[message.sender.id] else {
                logger.warning("Réponse de pairage inattendue de \(message.sender.name, privacy: .public)")
                return
            }

            let result = pairingHandshake.verifyPairingPayload(
                payload,
                expectedChallenge: ourChallenge
            )
            pendingPairingChallenges.removeValue(forKey: message.sender.id)

            switch result {
            case .success(let info):
                logger.info("Pairage confirmé avec \(info.peerName, privacy: .public)")
            case .invalidSignature:
                logger.error("Signature de pairage invalide de \(message.sender.name, privacy: .public)")
            case .challengeMismatch:
                logger.error("Challenge de pairage incorrect de \(message.sender.name, privacy: .public)")
            case .protocolVersionMismatch:
                logger.error("Version de protocole incompatible avec \(message.sender.name, privacy: .public)")
            case .selfPairingAttempt:
                logger.warning("Tentative d'auto-pairage détectée")
            }
        } catch {
            logger.error("Payload de réponse de pairage invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Renvoie l'identité de l'appareil local (utilisée pour les payloads
    /// de pairage). On évite `connectionManager.connectedDevice` qui peut
    /// être nil selon le moment du cycle de connexion.
    private func localDeviceForPairing() -> Device {
        bonjourService.localDevice
    }

    // MARK: - Handshake ECDH P-256 (chiffrement de session)

    /// Clé éphémère générée à l'initiation du handshake ECDH.
    /// Conservée jusqu'à la réception du `keyExchangeAck` du pair, qui
    /// permet de dériver la clé symétrique de session.
    private var pendingECDHHandshake: SecureHandshake?

    /// Indique si le `sessionId` a déjà été adopté depuis un
    /// `keyExchange` reçu. Permet de distinguer le premier
    /// `keyExchange` (qui doit écraser l'UUID LOCAL généré à
    /// `onSessionReady`) des `keyExchange` ultérieurs (qui doivent
    /// être ignorés si leur `sessionId` diffère — replay ou injection).
    private var hasAdoptedSessionIdFromKeyExchange = false

    /// Reçoit un `keyExchange` du pair : on génère notre propre clé
    /// éphémère, on dérive la clé symétrique de session, et on renvoie
    /// notre clé publique via un `keyExchangeAck`.
    ///
    /// Correction architecturale : le `sessionId` partagé EST celui
    /// annoncé par l'initiator dans `payload.sessionId`. Auparavant,
    /// on lisait `connectionManager.getActiveSessionId()` (un UUID
    /// LOCAL généré à `onSessionReady` de chaque pair), ce qui
    /// produisait deux `sessionId` distincts sur les deux pairs →
    /// clés symétriques dérivées différentes, et tous les chunks
    /// rejetés à la réception ("FileChunk avec sessionId incorrect").
    ///
    /// La signature long-terme du `keyExchange` couvre le payload
    /// entier incluant `sessionId` (vérifié par
    /// `runSecureReceptionPipeline` en amont), donc
    /// `payload.sessionId` est authentifié.
    private func handleKeyExchange(
        message: AirBridgeMessage,
        connection: NWConnection
    ) {
        guard let payloadData = message.payload else {
            logger.error("keyExchange sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                KeyExchangePayload.self,
                from: payloadData
            )

            // Anti-remplacement : si un `sessionId` a déjà été ADOPTÉ
            // depuis un précédent `keyExchange` (et non pas généré
            // localement à `onSessionReady`) et qu'il diffère de celui
            // annoncé, on ignore. C'est soit un replay, soit un second
            // `keyExchange` croisé. Un `sessionId` adopté ne se
            // remplace pas pour la durée de la connexion. Un rejeu du
            // même `keyExchange` (même `sessionId`) est déjà bloqué
            // par le `ReplayProtectionStore` (vérification antireplay
            // dans `runSecureReceptionPipeline`).
            //
            // Note : le premier `keyExchange` doit TOUJOURS adopter,
            // même si un UUID LOCAL a été généré à `onSessionReady`
            // (c'est précisément le bug architectural que ce correctif
            // résout : l'UUID LOCAL du responder est écrasé par le
            // `sessionId` de l'initiator).
            if hasAdoptedSessionIdFromKeyExchange,
               let existing = connectionManager.getActiveSessionId(),
               existing != payload.sessionId {
                logger.warning("keyExchange avec sessionId divergent — ignoré (replay ou injection)")
                return
            }

            // Adoption du sessionId partagé (celui de l'initiator).
            let sharedSessionId = payload.sessionId
            connectionManager.setActiveSessionId(sharedSessionId)
            transferManager.outgoingManager.setSessionId(sharedSessionId)
            hasAdoptedSessionIdFromKeyExchange = true

            // 1. Génération de notre clé éphémère et dérivation de la clé
            //    symétrique de session, en utilisant le sessionId partagé.
            let handshake = SecureHandshake()
            let sessionKey = try handshake.deriveSessionKey(
                from: payload.publicKeyData,
                sessionId: sharedSessionId
            )

            // 2. Installation immédiate de la clé (on est celui qui a
            //    reçu le `keyExchange` en premier : on peut déjà
            //    chiffrer les chunks sortants et déchiffrer les
            //    entrants).
            installSessionKey(sessionKey)

            // 3. Envoi de notre `keyExchangeAck` avec notre clé
            //    publique et le sessionId partagé : le pair pourra
            //    alors dériver la même clé symétrique et l'installer
            //    de son côté.
            connectionManager.sendKeyExchangeAck(
                publicKey: handshake.publicKey,
                sessionId: sharedSessionId,
                on: connection
            )

            logger.info("Handshake ECDH terminé (côté réception, sessionId=\(sharedSessionId, privacy: .public))")

        } catch {
            logger.error("keyExchange invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reçoit un `keyExchangeAck` du pair : on dérive la clé symétrique
    /// à partir de notre `SecureHandshake` en attente et de la clé
    /// publique du pair, puis on l'installe.
    private func handleKeyExchangeAck(message: AirBridgeMessage) {
        guard let payloadData = message.payload else {
            logger.error("keyExchangeAck sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                KeyExchangePayload.self,
                from: payloadData
            )
            guard let activeSession = connectionManager.getActiveSessionId() else {
                logger.error("keyExchangeAck sans session active")
                return
            }
            // Cohérence défensive : le responder doit renvoyer dans son
            // ack le MÊME `sessionId` que celui qu'il a adopté depuis
            // notre `keyExchange` (cf. `handleKeyExchange`). Si le
            // responder a adopté un autre `sessionId` (ou si on a
            // plusieurs sessions en parallèle), on le détecte ici et
            // on ignore l'ack plutôt que de dériver une clé
            // incompatible.
            if payload.sessionId != activeSession {
                logger.error("keyExchangeAck avec sessionId incohérent : \(payload.sessionId, privacy: .public) vs \(activeSession, privacy: .public) — ignoré")
                return
            }
            guard let handshake = pendingECDHHandshake else {
                // On a déjà installé la clé (côté réception), ou on n'a
                // jamais initié le handshake. Ignorer sans erreur.
                return
            }

            let sessionKey = try handshake.deriveSessionKey(
                from: payload.publicKeyData,
                sessionId: activeSession
            )
            installSessionKey(sessionKey)
            pendingECDHHandshake = nil
            logger.info("Handshake ECDH terminé (côté initiation)")

        } catch {
            logger.error("keyExchangeAck invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Initie un handshake ECDH P-256 : on génère une clé éphémère, on
    /// l'envoie via `keyExchange`, et on attend le `keyExchangeAck` du
    /// pair qui permettra la dérivation finale.
    func initiateECDHHandshake() {
        guard connectionManager.session != nil,
              let activeSession = connectionManager.getActiveSessionId(),
              let connection = connectionManager.session?.connection else {
            logger.info("Pas de session active pour le handshake ECDH")
            return
        }
        // Ne pas relancer un handshake si une clé est déjà installée.
        if transferManager.outgoingManager is OutgoingTransferManager,
           pendingECDHHandshake != nil {
            return
        }

        let handshake = SecureHandshake()
        pendingECDHHandshake = handshake

        do {
            let payload = KeyExchangePayload(
                publicKey: handshake.publicKey,
                sessionId: activeSession
            )
            let payloadData = try messageCodec.encodePayload(payload)
            let message = AirBridgeMessage(
                type: .keyExchange,
                sender: bonjourService.localDevice,
                payload: payloadData
            )
            connectionManager.send(
                message,
                on: connection
            )
            logger.info("Handshake ECDH initié")
        } catch {
            logger.error("Impossible d'initier le handshake ECDH : \(error.localizedDescription, privacy: .public)")
            pendingECDHHandshake = nil
        }
    }

    /// Installe la clé symétrique de session dans les deux gestionnaires
    /// de chunks. Centralise l'appel pour que les deux côtés (initiation
    /// et réception) partagent la même logique.
    private func installSessionKey(_ key: SymmetricKey) {
        transferManager.outgoingManager.installSessionKey(key)
        transferManager.incomingManager.installSessionKey(key)
    }

    private func handleTransferCancelled(
        message: AirBridgeMessage
    ) {
        guard let payloadData = message.payload else {
            logger.error("transferCancelled sans payload")
            return
        }

        
        do {
            
            
            let payload = try messageCodec.decodePayload(
                TransferCancelledPayload.self,
                from: payloadData
            )

            guard !transferManager.isTerminal(
                transferID: payload.transferID
            ) else {
                logger.info("transferCancelled déjà traité : \(payload.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: payload.transferID
            )

            transferManager.markCancelled(
                transferID: payload.transferID
            )

            transferManager.cancelIncomingTransfer(
                transferID: payload.transferID
            )

            finishOutgoingTransfer(
                transferID: payload.transferID
            )

            let cancelledIDs = Set([payload.transferID])
            clearPendingTransferBatch(transferIDs: cancelledIDs)

            logger.warning(
                "Transfert annulé par l’appareil distant"
            )

            if let reason = payload.reason {
                logger.info("Motif : \(reason, privacy: .public)")
            }

        } catch {
            logger.error(
                "transferCancelled invalide : \(error.localizedDescription, privacy: .public)"
            )
        }

        // Notification: transfert annulé (par appareil distant)
        do {
            let payload = try messageCodec.decodePayload(
                TransferCancelledPayload.self,
                from: message.payload ?? Data()
            )
            if notificationManager.checkNotNotified(payload.transferID) {
                if let transfer = transferManager.transfers.first(where: { $0.id == payload.transferID }) {
                    notificationManager.notifyTransferCancelled(
                        fileName: transfer.fileName,
                        deviceName: message.sender.name,
                        cancelledBy: .remoteDevice
                    )
                }
            }
        } catch {
            logger.error("Impossible de décoder payload pour notification : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Traite un chunk binaire reçu : décode, vérifie le sessionId, puis
    /// délègue le travail lourd (déchiffrement + écriture disque) à
    /// `transferManager.appendReceivedChunk` qui s'exécute hors MainActor
    /// depuis la phase 2-bis. Méthode `async` car l'API publique du
    /// TransferManager est devenue asynchrone ; le call site du
    /// `MessageRouter` l'enveloppe dans une Task dédiée.
    private func handleFileChunk(
        message: AirBridgeMessage
    ) async {
        guard let payloadData = message.payload else {
            logger.error("FileChunk sans payload")
            return
        }

        do {
            // On évite le double décodage : si le `ConnectionManager`
            // a déjà décodé le chunk binaire v2 (cas de la réception
            // directe), on l'utilise tel quel. Sinon (chemin v1, ou
            // chemin non décodé en amont), on décode maintenant.
            let binaryChunk: BinaryFileChunkPayload?
            if let pre = message.decodedBinaryChunk {
                binaryChunk = pre
            } else if message.protocolVersion >= 2 {
                binaryChunk = try messageCodec.decodePayload(
                    BinaryFileChunkPayload.self,
                    from: payloadData,
                    protocolVersion: message.protocolVersion,
                    messageType: .fileChunk
                )
            } else {
                binaryChunk = nil
            }

            // Extraire les champs communs
            let transferID: UUID
            let offset: Int64
            let data: Data
            if let binaryChunk = binaryChunk {
                // Vérification du sessionId : un chunk binaire v2
                // DOIT appartenir à la session active. Un chunk d'une
                // autre session (ou d'un attaquant) est silencieusement
                // ignoré.
                if let activeId = self.connectionManager.getActiveSessionId(),
                   binaryChunk.sessionId != activeId {
                    logger.error("FileChunk avec sessionId incorrect : \(binaryChunk.sessionId, privacy: .public) vs \(activeId, privacy: .public)")
                    return
                }
                transferID = binaryChunk.transferID
                offset = binaryChunk.offset
                data = binaryChunk.data
            } else {
                let v1Chunk = try messageCodec.decodePayload(
                    FileChunkPayload.self,
                    from: payloadData
                )
                transferID = v1Chunk.transferID
                offset = v1Chunk.offset
                data = v1Chunk.data
            }

            // Le sessionId est désormais obligatoire (MAJEUR-3) :
            // l'appelant de appendReceivedChunk doit le fournir
            // explicitement. Pour les chunks v1, qui ne transportent pas
            // de sessionId, on exige que la session active soit déjà
            // établie — sinon on rejette le chunk.
            guard let activeSessionId = connectionManager.getActiveSessionId() else {
                logger.error("FileChunk reçu sans session active établie — chunk ignoré")
                return
            }

            let wasWritten = await transferManager.appendReceivedChunk(
                transferID: transferID,
                offset: offset,
                data: data,
                sessionId: activeSessionId
            )

            if wasWritten {
                restartTransferActivityTimeout(
                    transferID: transferID
                )
            }
        } catch {
            logger.error("FileChunk invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTransferCompleted(
        message: AirBridgeMessage,
        connection: NWConnection
    ) async {
        guard let payloadData = message.payload else {
            logger.error("transferCompleted sans payload")
            return
        }

        do {
            let completed = try messageCodec.decodePayload(
                TransferCompletedPayload.self,
                from: payloadData
            )
            
            guard !transferManager.isTerminal(
                transferID: completed.transferID
            ) else {
                logger.info("transferCompleted déjà traité : \(completed.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: completed.transferID
            )

            let isValid = await transferManager.finalizeReceivedTransfer(
                transferID: completed.transferID,
                announcedTotalBytes: completed.totalBytes
            )

            guard isValid else {
                transferManager.markFailed(
                    transferID: completed.transferID
                )

                transferManager.cancelIncomingTransfer(
                    transferID: completed.transferID
                )

                connectionManager.sendTransferFailed(
                    transferID: completed.transferID,
                    reason: "Taille du fichier reçue invalide",
                    on: connection
                )

                return
            }

            do {
                let temporaryURL =
                    try transferManager.receivedTemporaryFileURL(
                        transferID: completed.transferID
                    )

                let receivedSHA256 = try FileHasher.sha256(
                    of: temporaryURL
                )

                guard receivedSHA256 == completed.sha256 else {
                    transferManager.markFailed(
                        transferID: completed.transferID
                    )

                    transferManager.cancelIncomingTransfer(
                        transferID: completed.transferID
                    )

                    connectionManager.sendTransferFailed(
                        transferID: completed.transferID,
                        reason: "L’intégrité du fichier est invalide",
                        on: connection
                    )

                    logger.error("Empreinte SHA-256 différente")
                    return
                }

                transferManager.setSHA256(
                    transferID: completed.transferID,
                    sha256: receivedSHA256
                )


                let savedURL = try transferManager.saveReceivedFile(
                    transferID: completed.transferID
                )

                transferManager.setLocalFileURL(
                    transferID: completed.transferID,
                    url: savedURL
                )

                transferManager.markCompleted(
                    transferID: completed.transferID,
                    transferredBytes: completed.totalBytes
                )

                // Notification: transfert reçu terminé avec succès
                if notificationManager.checkNotNotified(completed.transferID) {
                    notificationManager.notifyTransferCompleted(
                        direction: .received,
                        fileCount: 1,
                        deviceName: message.sender.name
                    )
                }


                connectionManager.sendTransferSucceeded(
                    transferID: completed.transferID,
                    receivedBytes: completed.totalBytes,
                    on: connection
                )

                logger.info("Transfert terminé")
                logger.info("Fichier disponible : \(savedURL.path, privacy: .public)")

            } catch {
                transferManager.markFailed(
                    transferID: completed.transferID
                )

                
                transferManager.cancelIncomingTransfer(
                    transferID: completed.transferID
                )
                
                connectionManager.sendTransferFailed(
                    transferID: completed.transferID,
                    reason: "Impossible d’enregistrer le fichier",
                    on: connection
                )

                logger.error(
                    "Impossible d’enregistrer le fichier : \(error.localizedDescription, privacy: .public)"
                )
            }

        } catch {
            logger.error(
                "transferCompleted invalide : \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    
    
    private func handleTransferSucceeded(
        message: AirBridgeMessage
    ) {
        guard let payloadData = message.payload else {
            logger.error("transferSucceeded sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                TransferSucceededPayload.self,
                from: payloadData
            )

            guard !transferManager.isTerminal(
                transferID: payload.transferID
            ) else {
                logger.info("transferSucceeded déjà traité : \(payload.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: payload.transferID
            )

            transferManager.markCompleted(
                transferID: payload.transferID,
                transferredBytes: payload.receivedBytes
            )

            // Notification: transfert envoyé terminé avec succès
            if notificationManager.checkNotNotified(payload.transferID) {
                notificationManager.notifyTransferCompleted(
                    direction: .sent,
                    fileCount: 1,
                    deviceName: message.sender.name
                )
            }

            finishOutgoingTransfer(
                transferID: payload.transferID
            )


            logger.info("Fichier reçu et enregistré par le destinataire")
            logger.info("Transfert : \(payload.transferID, privacy: .public)")

        } catch {
            logger.error(
                "transferSucceeded invalide : \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    

    
    
    private func handleTransferFailed(
        message: AirBridgeMessage
    ) {
        guard let payloadData = message.payload else {
            logger.error("transferFailed sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                TransferFailedPayload.self,
                from: payloadData
            )

            guard !transferManager.isTerminal(
                transferID: payload.transferID
            ) else {
                logger.info("transferFailed déjà traité : \(payload.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: payload.transferID
            )
            transferManager.markFailed(
                transferID: payload.transferID
            )

            finishOutgoingTransfer(
                transferID: payload.transferID
            )

            logger.error("Le destinataire n’a pas pu finaliser le transfert")
            logger.info("Motif : \(payload.reason, privacy: .public)")

        } catch {
            logger.error(
                "transferFailed invalide : \(error.localizedDescription, privacy: .public)"
            )
        }

        // Notification: transfert échoué
        do {
            let payload = try messageCodec.decodePayload(
                TransferFailedPayload.self,
                from: payloadData
            )
            if notificationManager.checkNotNotified(payload.transferID) {
                if let transfer = transferManager.transfers.first(where: { $0.id == payload.transferID }) {
                    notificationManager.notifyTransferFailed(
                        fileName: transfer.fileName,
                        deviceName: message.sender.name,
                        reason: payload.reason
                    )
                }
            }
        } catch {
            logger.error("Impossible de décoder payload pour notification : \(error.localizedDescription, privacy: .public)")
        }
    }





    func acceptPendingTransfer() {
        let requests = pendingRequests()
        guard let connection = requests.first?.connection else {
            logger.info("Aucune demande de transfert à accepter")
            return
        }

        for request in requests {
            let transferID = request.request.transferID
            transferManager.markAccepted(
                transferID: transferID
            )
            connectionManager.sendTransferAccepted(
                transferID: transferID,
                on: connection
            )
            logger.info("Demande acceptée : \(request.request.fileName, privacy: .public)")
        }

        logger.info(
            "Autorisation groupée : \(requests.count) fichier(s) accepté(s)"
        )

        pendingApprovalCoordinator.clear()
    }

    func rejectPendingTransfer(
        reason: String? = nil
    ) {
        let requests = pendingRequests()
        guard let connection = requests.first?.connection else {
            logger.info("Aucune demande de transfert à refuser")
            return
        }

        for request in requests {
            let transferID = request.request.transferID
            transferManager.markRejected(
                transferID: transferID,
                reason: reason
            )
            transferManager.cancelIncomingTransfer(
                transferID: transferID
            )
            connectionManager.sendTransferRejected(
                transferID: transferID,
                reason: reason,
                on: connection
            )
            logger.error("Demande refusée : \(request.request.fileName, privacy: .public)")
        }

        logger.error(
            "Autorisation groupée : \(requests.count) fichier(s) refusé(s)"
        )

        pendingApprovalCoordinator.clear()
    }
    
    
    func start() {
        bonjourService.startAdvertising()
        bonjourService.startDiscovery()
    }
    
    func stop() {
        connectionManager.disconnect()
        bonjourService.stopDiscovery()
        bonjourService.stopAdvertising()
    }
    
    
    func cancelTransfer(
        transferID: UUID
    ) {
        // Une reprise automatique en cours ne doit pas survivre à une
        // annulation explicite de l'utilisateur.
        cancelAutomaticResumeTask(for: transferID)

        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        let wasActive = outgoingTransferQueue.isActive(transferID)

        // Récupérer le nom du fichier avant le nettoyage pour la notification
        let transfer = transferManager.transfers.first(where: { $0.id == transferID })

        if !wasActive {
            _ = outgoingTransferQueue.cancel(transferID: transferID)
            transferManager.markCancelled(
                transferID: transferID
            )
            transferManager.cleanupOutgoingTransfer(
                transferID: transferID
            )

            // Notification: transfert en attente annulé par l'utilisateur local
            if let transfer,
               notificationManager.checkNotNotified(transferID) {
                notificationManager.notifyTransferCancelled(
                    fileName: transfer.fileName,
                    deviceName: transfer.peer.name,
                    cancelledBy: .localUser
                )
            }
            return
        }

        transferTimeoutManager.cancel(
            transferID: transferID
        )

        connectionManager.sendTransferCancelled(
            transferID: transferID,
            reason: "Annulé par l’utilisateur"
        )

        transferManager.markCancelled(
            transferID: transferID
        )

        finishOutgoingTransfer(
            transferID: transferID
        )

        // Notification: transfert actif annulé par l'utilisateur local
        if let transfer,
           notificationManager.checkNotNotified(transferID) {
            notificationManager.notifyTransferCancelled(
                fileName: transfer.fileName,
                deviceName: transfer.peer.name,
                cancelledBy: .localUser
            )
        }
    }

    /// Annule un transfert interrompu : terminal, nettoyage complet des
    /// ressources de reprise (source sortante, `.partial`, métadonnées).
    func cancelInterruptedTransfer(transferID: UUID) {
        cancelAutomaticResumeTask(for: transferID)

        guard let transfer = transferManager.transfers.first(where: {
            $0.id == transferID
        }), transfer.state == .interrupted else {
            return
        }

        transferManager.markCancelled(
            transferID: transferID
        )
        transferManager.cleanupTransfer(transferID: transferID)

        _ = outgoingTransferQueue.cancel(transferID: transferID)
        startedOutgoingTransfers.remove(transferID)

        if notificationManager.checkNotNotified(transferID) {
            notificationManager.notifyTransferCancelled(
                fileName: transfer.fileName,
                deviceName: transfer.peer.name,
                cancelledBy: .localUser
            )
        }
    }

    /// Tente de reprendre un transfert interrompu, dans le sens qui convient.
    ///
    /// Réception : rouvre le `.partial` à l'offset disque et demande au pair
    /// de repartir de là. Envoi : annonce au pair l'offset déjà reçu pour que
    /// la source locale reprenne son envoi. Sans session active avec le peer,
    /// l'appel est sans effet : le transfert reste `.interrupted` et pourra
    /// être repris plus tard (manuellement ou à la reconnexion).
    func resumeTransfer(_ id: UUID) {
        guard let transfer = transferManager.transfers.first(where: {
            $0.id == id
        }), transfer.state == .interrupted else {
            logger.info("Reprise demandée sur un transfert non interrompu : \(id, privacy: .public)")
            return
        }

        // Garde anti-double-reprise : jamais deux tentatives simultanées
        // pour un même transfert.
        guard resumeTasks[id] == nil else {
            logger.info("Une reprise est déjà en cours : \(id, privacy: .public)")
            return
        }

        switch transfer.direction {
        case .incoming:
            startIncomingResume(transferID: id)

        case .outgoing:
            startOutgoingResume(transferID: id)
        }
    }

    private func startIncomingResume(transferID: UUID) {
        // Rouvrir le writer entrant à la taille réelle du `.partial` avant
        // d'annoncer l'offset au pair : les chunks repris s'écriront dedans.
        let offset = transferManager.incomingPartialFileBytes(
            transferID: transferID
        )

        guard offset > 0 else {
            logger.error("Reprise impossible : aucun octet déjà reçu (\(transferID, privacy: .public))")
            return
        }

        guard transferManager.reopenIncomingWriter(
            transferID: transferID,
            atOffset: offset
        ) else {
            logger.error("Reprise impossible : fichier partiel inaccessible")
            return
        }

        guard transferManager.resumeIncomingTransfer(
            transferID: transferID,
            connectionManager: connectionManager
        ) else {
            return
        }

        logger.info("Reprise entrante demandée : \(transferID, privacy: .public) à \(offset)")
    }

    private func startOutgoingResume(transferID: UUID) {
        // Garde stricte : la session doit être confirmée `.ready`. Une
        // session en préparation existe déjà mais ne peut rien transporter ;
        // le resumeRequest partirait dans la file d'une connexion qui
        // expirera peut-être sans jamais l'émettre.
        guard connectionManager.isSessionReady,
              connectionManager.connectedDevice?.id == transferManager.transfers
                  .first(where: { $0.id == transferID })?.peer.id else {
            logger.info("Pair non connecté : reprise reportée (\(transferID, privacy: .public))")
            return
        }

        let resumedTransfer = transferManager.transfers.first {
            $0.id == transferID
        }

        let transferredBytes = resumedTransfer?
            .transferredBytes ?? 0

        guard transferredBytes > 0 else {
            logger.info("Rien n'a encore été envoyé : relance classique plutôt que reprise")
            return
        }

        // Le SHA-256 de la source, s'il a été calculé au premier envoi,
        // accompagne la demande ; sinon il reste vide et le récepteur
        // ignore ce champ (l'intégrité finale repose sur le SHA-256
        // complet du transfert terminé).
        connectionManager.sendResumeRequest(
            transferID: transferID,
            receivedBytes: transferredBytes,
            fileSize: resumedTransfer?.fileSize ?? 0,
            fileName: resumedTransfer?.fileName ?? "",
            chunkSize: TransferChunkSizing.chunkSize(
                forFileSize: resumedTransfer?.fileSize ?? 0
            ),
            sha256: resumedTransfer?.sha256 ?? ""
        )

        logger.info("Reprise sortante demandée : \(transferID, privacy: .public) à \(transferredBytes)")
    }

    // MARK: - Reprise automatique après reconnexion

    /// Au rétablissement de la session avec un pair : tente une reprise
    /// automatique des transferts interrompus de ce pair.
    ///
    /// Bornée : une seule campagne à la fois, au plus quatre tentatives par
    /// transfert selon le backoff `automaticResumeBackoffs` (2 s / 5 s /
    /// 10 s / 20 s), tâches annulables (annulation utilisateur ou reprise
    /// effective). Après épuisement le transfert reste `.interrupted`, la
    /// reprise manuelle reste possible.
    private func scheduleAutomaticResumeOnReconnect() {
        // Unicité de campagne : si une campagne tourne déjà, ne rien
        // rouvrir. Les tâches existantes sont les seules à décider.
        guard !isResumeCampaignActive else { return }
        isResumeCampaignActive = true

        // La session fraîchement établie identifie le pair fiable : c'est
        // lui qui décide des transferts à relancer, pas un souvenir obsolète.
        guard let peerID = connectionManager.connectedDevice?.id
                ?? lastKnownPeerID else {
            isResumeCampaignActive = false
            return
        }

        let interrupted = transferManager.transfers.filter {
            $0.state == .interrupted && $0.peer.id == peerID
        }

        guard !interrupted.isEmpty else {
            isResumeCampaignActive = false
            return
        }

        logger.info("Reprise automatique candidate pour \(interrupted.count) transfert(s)")

        for transfer in interrupted {
            startAutomaticResumeTask(for: transfer.id)
        }
    }

    /// Reprise déclenchée depuis la tâche automatique : la garde
    /// anti-double-reprise est déjà tenue par `resumeTasks` (une seule
    /// tâche par identifiant), on court-circuite donc la vérification de
    /// `resumeTransfer` qui sinon verrait sa propre tâche.
    private func attemptResumeIgnoringRunningTask(_ id: UUID) {
        guard let transfer = transferManager.transfers.first(where: {
            $0.id == id
        }), transfer.state == .interrupted else {
            return
        }

        switch transfer.direction {
        case .incoming:
            startIncomingResume(transferID: id)
        case .outgoing:
            startOutgoingResume(transferID: id)
        }
    }

    /// Backoff de la reprise automatique : croissance douce pour laisser le
    /// réseau se reformer, plafonnée à vingt secondes.
    private static let automaticResumeBackoffs: [UInt64] = [2, 5, 10, 20]

    private func startAutomaticResumeTask(for transferID: UUID) {
        guard resumeTasks[transferID] == nil else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            for seconds in Self.automaticResumeBackoffs {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)

                if Task.isCancelled {
                    // La campagne peut avoir été invalidée (échec de
                    // connexion) : ne rien relancer, attendre une
                    // redécouverte fraîche.
                    return
                }

                guard let transfer = self.transferManager.transfers.first(
                    where: { $0.id == transferID }
                ), transfer.state == .interrupted else {
                    // Repris ou annulé entre-temps : cette tâche s'achève,
                    // les autres continuent leur propre campagne.
                    self.finishResumeTask(for: transferID)
                    return
                }

                // Garde stricte : seule une session confirmée `.ready` et
                // visant le pair du transfert autorise une tentative. Une
                // session en préparation ou en attente ne consomme pas de
                // créneau — on patiente jusqu'au prochain délai.
                guard self.connectionManager.isSessionReady,
                      self.connectionManager.connectedDevice?.id == transfer.peer.id else {
                    continue
                }

                self.attemptResumeIgnoringRunningTask(transferID)

                // Si la reprise a pris (état quitté `.interrupted`),
                // cette tâche s'achève ; sinon retenter au prochain délai.
                if self.transferManager.transfers.first(where: {
                    $0.id == transferID
                })?.state != .interrupted {
                    self.finishResumeTask(for: transferID)
                    return
                }
            }

            // Tentatives épuisées : reste `.interrupted`.
            self.finishResumeTask(for: transferID)
            logger.info("Reprise automatique abandonnée : \(transferID, privacy: .public)")
        }

        resumeTasks[transferID] = task
    }

    /// Achève la tâche de reprise d'un transfert. Quand la dernière tâche
    /// d'une campagne se termine, la campagne entière est close : le verrou
    /// est levé pour qu'une prochaine session puisse en rouvrir une.
    private func finishResumeTask(for transferID: UUID) {
        resumeTasks[transferID] = nil

        guard resumeTasks.isEmpty else { return }

        isResumeCampaignActive = false
    }

    /// Invalide toute la campagne : la session est tombée, l'endpoint sur
    /// laquelle elle s'appuyait n'a plus de sens. Les tâches sont annulées
    /// et seule une redécouverte fraîche pourra rouvrir une campagne.
    private func endResumeCampaign() {
        isResumeCampaignActive = false

        for (id, task) in resumeTasks {
            task.cancel()
            resumeTasks[id] = nil
        }
    }

    /// Annulation utilisateur (du transfert ou de sa reprise) : la tâche
    /// est annulée puis retirée comme toute fin de tâche. Passer par
    /// `finishResumeTask` évite de laisser le verrou de campagne levé quand
    /// le dernier transfert interrompu disparaît — sans quoi plus aucune
    /// campagne automatique ne pourrait s'ouvrir pour ce pair.
    ///
    /// `Task.cancel` est idempotent : l'appel redondant avec celui du bloc
    /// de la tâche (qui passe aussi par `finishResumeTask`) est sans effet.
    private func cancelAutomaticResumeTask(for transferID: UUID) {
        resumeTasks[transferID]?.cancel()
        finishResumeTask(for: transferID)
    }

    /// Taille réelle d'un fichier sur disque, `0` si illisible.
    private static func onDiskBytes(of url: URL) -> Int64 {
        guard let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return 0
        }
        return Int64(size)
    }

    /// Décision de restauration pour une métadonnée de reprise : renvoie
    /// les octets réconciliés à restaurer, ou `nil` si la métadonnée est
    /// orpheline (le `.partial` n'existe plus, rien à reprendre).
    ///
    /// Côté réception, le fichier local est le `.partial`. Côté émission,
    /// c'est la copie de travail — et si elle a disparu (purge du dossier
    /// temporaire au redémarrage), l'original référencé par
    /// `sourceFileURL` suffit : un envoi repart de zéro plutôt que d'être
    /// purgé comme orphelin.
    ///
    /// Extraite de la boucle de démarrage pour rester testable isolément.
    static func resolvedRestorationBytes(
        for info: ResumeTransferInfo
    ) -> Int64? {
        let localDataURL = info.partialFileURL

        let onDisk = FileManager.default.fileExists(atPath: localDataURL.path)
            ? onDiskBytes(of: localDataURL)
            : 0

        if onDisk > 0 {
            // La taille réelle sur disque fait foi : un `.partial`
            // tronqué est repris à sa taille, jamais au-delà des
            // métadonnées.
            return ResumeTransferInfo.reconciledTransferredBytes(
                metadataBytes: info.transferredBytes,
                onDiskBytes: onDisk
            )
        }

        // Pas de fichier local exploitable : seul un envoi dont la source
        // originale existe encore reste restaurable (reprise à zéro).
        let isOutgoing = info.direction == "outgoing"
        let hasLivingSource = info.sourceFileURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false

        guard isOutgoing, hasLivingSource else {
            return nil
        }

        return 0
    }
}

/// Erreur levée par le pipeline d'envoi (`runChunkPipeline`) quand la
/// somme des octets effectivement envoyés ne correspond pas à la taille
/// de fichier annoncée. Indique une perte de chunks dans le pipeline
/// (historiquement causée par une politique de buffering qui écrasait
/// les chunks les plus récents) et provoque l'échec du transfert
/// plutôt qu'un `transferCompleted` mensonger.
struct PipelineIntegrityError: Error, CustomStringConvertible {
    let expected: Int64
    let sent: Int64
    let chunks: Int

    var description: String {
        "PipelineIntegrityError: attendu \(expected) octets, envoyé \(sent) (\(chunks) chunks)"
    }
}

