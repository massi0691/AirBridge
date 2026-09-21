import Foundation
import Observation
import os.lock
import OSLog

// Assumes TransferHistory.swift and TransferHistoryStore.swift are in the same module

enum TransferManagerError: Error {
    case outgoingSourceNotFound
    case transferNotFound
    case receivedDirectoryNotSelected
    case receivedDirectoryAccessDenied
    case receivedDirectoryNotFound
    case receivedTemporaryFileNotFound
}

@MainActor
@Observable
final class TransferManager {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "transfer.manager"
    )

    private let store: TransferStore
    let incomingManager: IncomingTransferManager
    let outgoingManager: OutgoingTransferManager
    private let storage: TransferStorage
    private let historyStore: TransferHistoryStore

    var transfers: [Transfer] {
        store.transfers
    }

    // Lock to protect concurrent access to pipeline tracking dictionaries
    // from nested @MainActor Task closures
    // OSAllocatedUnfairLock is async-safe via performWhileLocked
    private let pipelineLock = OSAllocatedUnfairLock()

    init(
        receivedFolderStore: ReceivedFolderStore,
        localDevice: Device,
        historyStore: TransferHistoryStore
    ) {
        let store = TransferStore()

        self.store = store
        self.incomingManager = IncomingTransferManager(
            store: store
        )
        self.outgoingManager = OutgoingTransferManager(
            store: store,
            localDevice: localDevice
        )
        self.storage = TransferStorage(
            receivedFolderStore: receivedFolderStore
        )
        self.historyStore = historyStore
    }

    // MARK: - Transferts sortants

    // MAP: Gestion du pipeline avec plusieurs chunks en vol simultanément

    func sendChunk(
        transferID: UUID,
        chunkOffset: Int64,
        chunkData: Data,
        isLastChunk: Bool = false,
        chunkSize: Int = 0,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Pipeline configuration: 5 chunks in flight (was 2)
        // Increased to better utilize bandwidth on high-latency local networks
        let maxPipelineDepth = 5

        // Check current in-flight chunks for this transfer
        let currentChunks: Int = pipelineLock.withLock {
            ft_chunksInFlight[transferID] ?? 0
        }

        // If we've reached max depth, queue the chunk
        if currentChunks >= maxPipelineDepth {
            pipelineLock.withLock {
                pendingChunks[transferID, default: []].append((offset: chunkOffset, data: chunkData, isLastChunk: isLastChunk))
            }
            completion(.success(()))
            return
        }

        // Update tracking immediately to reserve slot
        pipelineLock.withLock {
            ft_chunksInFlight[transferID] = currentChunks + 1
        }

        // Get transfer for validation
        guard store.transfer(withID: transferID) != nil else {
            pipelineLock.withLock {
                let currentCount = ft_chunksInFlight[transferID] ?? 1
                ft_chunksInFlight[transferID] = max(0, currentCount - 1)
            }
            completion(.failure(TransferManagerError.transferNotFound))
            return
        }

        let effectiveChunkSize = chunkSize > 0
            ? chunkSize
            : TransferChunkSizing.chunkSize(
                forFileSize: store.transfer(withID: transferID)?.fileSize ?? 0
            )

        // Send chunk immediately via outgoingManager
        outgoingManager.sendChunk(
            transferID: transferID,
            offset: chunkOffset,
            data: chunkData,
            isLastChunk: isLastChunk,
            chunkSize: effectiveChunkSize
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.processSentChunk(for: transferID, completion: completion)
                case .failure(let error):
                    logger.error("Échec d'envoi du chunk : \(error.localizedDescription, privacy: .public)")
                    self.pipelineLock.withLock {
                        let currentCount = self.ft_chunksInFlight[transferID] ?? 1
                        self.ft_chunksInFlight[transferID] = max(0, currentCount - 1)
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    private func processSentChunk(for transferID: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        // Decrement in-flight count and get next pending chunk under lock
        let nextChunk: (offset: Int64, data: Data, isLastChunk: Bool)? = pipelineLock.withLock {
            let currentCount = ft_chunksInFlight[transferID] ?? 0
            ft_chunksInFlight[transferID] = max(0, currentCount - 1)

            if var chunks = pendingChunks[transferID], !chunks.isEmpty {
                let next = chunks.removeFirst()
                pendingChunks[transferID] = chunks
                return next
            }
            return nil
        }

        // Call the original completion
        completion(.success(()))

        // Send next chunk outside the lock to avoid deadlock
        if let nextChunk = nextChunk {
            sendChunk(
                transferID: transferID,
                chunkOffset: nextChunk.offset,
                chunkData: nextChunk.data,
                isLastChunk: nextChunk.isLastChunk,
                completion: { _ in }
            )
        }
    }

    // Dictionary to track in-flight chunks per transfer
    // nonisolated: these are protected by pipelineLock, not actor isolation
    // @ObservationIgnored prevents Observation from generating getters/setters
    @ObservationIgnored
    nonisolated(unsafe) private var ft_chunksInFlight: [UUID: Int] = [:]

    // Dictionary to track pending chunks per transfer
    @ObservationIgnored
    nonisolated(unsafe) private var pendingChunks: [UUID: [(offset: Int64, data: Data, isLastChunk: Bool)]] = [:]

    // MARK: - Private Methods

    func hasTransfer(transferID: UUID) -> Bool {
        store.hasTransfer(transferID)
    }

    func isTerminal(transferID: UUID) -> Bool {
        store.isTerminal(transferID: transferID)
    }

    func outgoingFileURL(
        transferID: UUID
    ) throws -> URL {
        try outgoingManager.fileURL(
            for: transferID
        )
    }

    func createOutgoingTransfer(
        id: UUID,
        peer: Device,
        fileName: String,
        fileSize: Int64,
        state: Transfer.State = .waitingForApproval
    ) {
        let transfer = Transfer(
            id: id,
            peer: peer,
            fileName: fileName,
            fileSize: fileSize,
            direction: .outgoing,
            state: state,
            transferredBytes: 0
        )
        store.append(transfer)
    }

    func registerOutgoingSource(
        transferID: UUID,
        fileURL: URL,
        originalFileURL: URL? = nil,
        isTemporary: Bool = false
    ) {
        outgoingManager.registerSource(
            transferID: transferID,
            fileURL: fileURL,
            originalFileURL: originalFileURL,
            isTemporary: isTemporary
        )
    }

    func cancelOutgoingTransfer(
        transferID: UUID
    ) {
        outgoingManager.removeSource(
            transferID: transferID,
            deleteFile: true
        )
    }

    func cleanupOutgoingTransfer(
        transferID: UUID
    ) {
        outgoingManager.removeSource(
            transferID: transferID,
            deleteFile: true
        )
    }

    // MARK: - Transferts entrants

    func setSourceFileURL(
        transferID: UUID,
        url: URL
    ) {
        store.setSourceFileURL(
            transferID: transferID,
            url: url
        )
    }

    /// Rattache un transfert à la sélection dont il provient.
    ///
    /// Le lot ne sert qu'à l'affichage : il n'intervient ni dans la file
    /// d'envoi ni dans le protocole.
    func setBatchID(
        transferID: UUID,
        batchID: UUID
    ) {
        store.setBatchID(
            transferID: transferID,
            batchID: batchID
        )
    }

    func setLocalFileURL(
        transferID: UUID,
        url: URL
    ) {
        store.setLocalFileURL(
            transferID: transferID,
            url: url
        )
    }

    func receivedTemporaryFileURL(
        transferID: UUID
    ) throws -> URL {
        try incomingManager.temporaryFileURL(
            for: transferID
        )
    }

    /// Voir `IncomingRequestOutcome` : l'appelant doit prévenir l'émetteur
    /// d'un refus, et rester muet sur un doublon.
    @discardableResult
    func createIncomingTransfer(
        request: TransferRequestPayload,
        sender: Device
    ) async -> IncomingRequestOutcome {
        await incomingManager.createTransfer(
            request: request,
            sender: sender
        )
    }

    /// Variante pour les pairs de confiance : crée le transfert avec
    /// l'état `.accepted` directement, sans passer par la feuille
    /// d'approbation utilisateur.
    @discardableResult
    func createIncomingTransferAutoAccepted(
        request: TransferRequestPayload,
        sender: Device
    ) async -> IncomingRequestOutcome {
        await incomingManager.createTransfer(
            request: request,
            sender: sender,
            initialState: .accepted
        )
    }

    @discardableResult
    func appendReceivedChunk(
        transferID: UUID,
        offset: Int64,
        data: Data,
        sessionId: UUID
    ) async -> Bool {
        await incomingManager.appendChunk(
            transferID: transferID,
            offset: offset,
            data: data,
            sessionId: sessionId
        )
    }

    @discardableResult
    func finalizeReceivedTransfer(
        transferID: UUID,
        announcedTotalBytes: Int64
    ) async -> Bool {
        await incomingManager.finalize(
            transferID: transferID,
            announcedTotalBytes: announcedTotalBytes
        )
    }

    func saveReceivedFile(
        transferID: UUID
    ) throws -> URL {
        guard let transfer =
            store.transfer(withID: transferID) else {
            throw TransferManagerError.transferNotFound
        }

        let temporaryFileURL =
            try incomingManager.temporaryFileURL(
                for: transferID
        )

        // Le lot annoncé par l'émetteur décide du rangement : plusieurs
        // fichiers d'une même sélection rejoignent un sous-dossier unique,
        // un fichier isolé reste à plat.
        let savedURL = try storage.save(
            temporaryFileURL: temporaryFileURL,
            fileName: transfer.fileName,
            batch: incomingManager.batchContext(
                for: transferID
            )
        )

        incomingManager.removeWriter(
            transferID: transferID
        )

        return savedURL
    }

    func cancelIncomingTransfer(
        transferID: UUID
    ) {
        incomingManager.cancelTransfer(
            transferID: transferID
        )
    }

    /// Interruption d'une réception : le writer est fermé, le `.partial`
    /// conservé. Contrairement à l'annulation, rien n'est supprimé : les
    /// octets reçus sont le point de départ de la reprise.
    func interruptIncomingTransfer(
        transferID: UUID
    ) {
        incomingManager.interruptTransfer(transferID: transferID)
    }

    // MARK: - Reprise des transferts

    /// Tente de reprendre un transfert interrompu côté réception.
    ///
    /// - Parameter transferID: Identifiant du transfert à reprendre
    /// - Parameter connectionManager: Gestionnaire de connexion pour envoyer la demande
    /// - Returns: Bool indiquant si la reprise a été initiée avec succès
    func resumeIncoming(
        transferID: UUID,
        connectionManager: ConnectionManager
    ) -> Bool {
        guard connectionManager.isSessionReady,
              connectionManager.isSecureSessionReady,
              store.isResumable(transferID: transferID),
              let transfer = store.transfer(withID: transferID),
              transfer.direction == .incoming,
              transfer.peer.id == connectionManager.connectedDevice?.id else {
            logger.error("Impossible de reprendre : transfert non interrompu ou pas entrant")
            return false
        }

        // Taille réelle sur disque (fait foi pour la reprise)
        let receivedBytes = incomingManager.partialFileBytes(transferID: transferID)

        guard receivedBytes > 0, receivedBytes < transfer.fileSize else {
            logger.error("Impossible de reprendre : progression invalide (\(receivedBytes)/\(transfer.fileSize))")
            return false
        }

        // Envoyer la demande de reprise au pair. Le sha256 de la source est
        // inconnu du récepteur (il appartient à l'émetteur) : il reste vide,
        // l'intégrité finale étant assurée par le SHA-256 complet du
        // transfert terminé.
        guard connectionManager.sendResumeRequest(
            transferID: transferID,
            receivedBytes: receivedBytes,
            fileSize: transfer.fileSize,
            fileName: transfer.fileName,
            chunkSize: TransferChunkSizing.chunkSize(
                forFileSize: transfer.fileSize
            )
        ) else {
            logger.error("Impossible d'envoyer la demande de reprise")
            return false
        }

        // Passer à l'état accepté pour que les chunks puissent être écrits
        store.markAccepted(transferID: transferID)

        return true
    }

    /// Gère l'acceptation de reprise reçue du pair (côté émetteur).
    ///
    /// - Parameter transferID: Identifiant du transfert
    /// - Parameter offset: Offset accepté par le récepteur (premier octet à renvoyer)
    /// - Returns: Bool indiquant si la reprise a été acceptée et l'envoi démarré
    func handleResumeAccepted(
        transferID: UUID,
        offset: Int64
    ) -> Bool {
        guard let transfer = store.transfer(withID: transferID),
              transfer.state == .interrupted,
              transfer.direction == .outgoing else {
            logger.error("Aucun transfert sortant interrompu trouvé pour \(transferID, privacy: .public)")
            return false
        }

        // Borner l'offset à la progression connue
        let resumeOffset = max(offset, 0)

        // Mettre à jour l'état
        store.markAccepted(transferID: transferID)

        // Réinitialiser la file de chunks en attente
        pipelineLock.withLock {
            pendingChunks[transferID] = []
        }

        // Vérifier seulement l'accessibilité du fichier source : c'est
        // `AirBridgeCore` (dans son handler `resumeAccepted`) qui ouvre LE
        // handle utilisé par `sendNextChunk`.
        // Utiliser FileManager pour éviter une fuite de FileHandle.
        do {
            let fileURL = try outgoingManager.fileURL(for: transferID)
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                logger.error("Fichier source illisible pour la reprise : \(fileURL.path, privacy: .public)")
                return false
            }

            // L'envoi réel démarre via AirBridgeCore.sendNextChunk
            // qui sera appelé après la mise à jour de l'état

            return true
        } catch {
            logger.error("Impossible d'accéder au fichier source pour la reprise à l'offset \(resumeOffset) : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func updateProgress(
        transferID: UUID,
        transferredBytes: Int64
    ) {
        store.updateProgress(
            transferID: transferID,
            transferredBytes: transferredBytes
        )
    }

    func markWaitingForApproval(transferID: UUID) {
        store.markWaitingForApproval(
            transferID: transferID
        )
    }

    func markAccepted(transferID: UUID) {
        store.markAccepted(
            transferID: transferID
        )
    }

    /// Repart l'horloge de durée du transfert : utilisé à la reprise, pour
    /// que le temps d'interruption ne soit pas compté dans le débit affiché
    /// (`recordHistory` divise la taille par cette durée).
    func resetStartedAt(transferID: UUID) {
        store.resetStartedAt(transferID: transferID)
    }

    func markRejected(transferID: UUID, reason: String? = nil) {
        store.markRejected(
            transferID: transferID,
            reason: reason
        )
    }

    func markFailed(transferID: UUID, reason: String? = nil) {
        store.markFailed(
            transferID: transferID,
            reason: reason
        )
        recordHistory(transferID: transferID, status: .failed)

        // Un transfert terminal n'est plus reprisable : sa métadonnée de
        // reprise ne doit pas survivre au démarrage suivant, sinon elle
        // serait purgée comme orpheline (ou pire, restaurée à tort).
        clearResumeInfo(for: transferID)
    }

    func markCompleted(
        transferID: UUID,
        transferredBytes: Int64
    ) {
        store.markCompleted(
            transferID: transferID,
            transferredBytes: transferredBytes
        )
        recordHistory(transferID: transferID, status: .completed)

        // Même politique que l'échec : terminé = plus rien à reprendre.
        clearResumeInfo(for: transferID)
    }

    func setSHA256(
        transferID: UUID,
        sha256: String
    ) {
        store.setSHA256(
            transferID: transferID,
            sha256: sha256
        )
    }

    func markCancelled(
        transferID: UUID,
        reason: String? = nil
    ) {
        store.markCancelled(
            transferID: transferID,
            reason: reason
        )
        recordHistory(transferID: transferID, status: .cancelled)

        // Annulation volontaire : terminal, la métadonnée de reprise est
        // obsolète (le nettoyage des fichiers, lui, reste à la charge des
        // chemins d'annulation existants).
        clearResumeInfo(for: transferID)
    }

    /// Interruption unitaire (timeout d'activité, erreur réseau isolée) :
    /// même politique que la déconnexion, persistance immédiate comprise.
    func markInterrupted(
        transferID: UUID,
        transferredBytes: Int64,
        protocolVersion: Int? = nil
    ) {
        store.markInterrupted(
            transferID: transferID,
            transferredBytes: transferredBytes
        )

        guard let transfer = store.transfer(withID: transferID) else { return }

        persistResumeInfo(
            transferID: transferID,
            peerID: transfer.peer.id,
            peerName: transfer.peer.name,
            protocolVersion: protocolVersion
        )
    }

    /// Interruption en masse des transferts actifs d'un pair, sur
    /// déconnexion de sa session. Renvoie les identifiants réellement
    /// interrompus.
    ///
    /// Chaque interruption est persistée immédiatement : la métadonnée de
    /// reprise doit survivre même si le processus est tué juste après la
    /// coupure réseau. Attendre une demande de reprise explicite laisserait
    /// une fenêtre où un crash perdrait tout l'état.
    @discardableResult
    func interruptActiveTransfers(
        peerID: UUID,
        peerName: String?,
        protocolVersion: Int?
    ) -> [UUID] {
        let interruptedIDs = store.interruptActiveTransfers(peerID: peerID)

        for transferID in interruptedIDs {
            persistResumeInfo(
                transferID: transferID,
                peerID: peerID,
                peerName: peerName,
                protocolVersion: protocolVersion
            )
        }

        return interruptedIDs
    }

    /// Construit et écrit la métadonnée de reprise d'un transfert qui vient
    /// de passer à `.interrupted`.
    ///
    /// L'offset fait foi : côté réception c'est la taille réelle du
    /// `.partial` sur disque, côté envoi la progression annoncée par le
    /// pipeline. La sauvegarde est silencieuse en cas d'échec disque : une
    /// métadonnée manquante dégrade la reprise automatique, elle ne doit
    /// pas faire échouer l'interruption elle-même.
    private func persistResumeInfo(
        transferID: UUID,
        peerID: UUID,
        peerName: String?,
        protocolVersion: Int?
    ) {
        guard let transfer = store.transfer(withID: transferID) else { return }

        let isOutgoing = transfer.direction == .outgoing

        // Côté réception, la taille du `.partial` peut être supérieure à la
        // progression affichée (chunks écrits mais non confirmés) : c'est
        // bien le disque que la reprise doit retrouver.
        let transferredBytes = isOutgoing
            ? transfer.transferredBytes
            : incomingManager.partialFileBytes(transferID: transferID)

        // `partialFileURL` désigne le fichier local portant les octets déjà
        // transférés : le `.partial` côté réception, la copie de travail
        // côté émission. Y écrire l'URL entrante pour un envoi pointerait
        // vers un fichier qui n'existe jamais chez l'émetteur, et la
        // métadonnée serait purgée comme orpheline au démarrage suivant.
        let localDataURL: URL

        if isOutgoing {
            localDataURL = (try? outgoingManager.fileURL(for: transferID))
                ?? transfer.sourceFileURL
                ?? IncomingFileWriter.temporaryURL(for: transferID)
        } else {
            localDataURL = IncomingFileWriter.temporaryURL(for: transferID)
        }

        let info = ResumeTransferInfo(
            transferID: transferID,
            fileSize: transfer.fileSize,
            transferredBytes: transferredBytes,
            fileName: transfer.fileName,
            direction: isOutgoing ? "outgoing" : "incoming",
            peerID: peerID,
            timestamp: Date(),
            partialFileURL: localDataURL,
            peerName: peerName ?? transfer.peer.name,
            sourceFileURL: transfer.sourceFileURL,
            sha256: transfer.sha256,
            protocolVersion: protocolVersion
        )

        saveResumeInfo(info)
    }

    /// Écrit une métadonnée de reprise hors du fil principal.
    private func saveResumeInfo(_ info: ResumeTransferInfo) {
        let persistence = ResumePersistence.makePersistence(
            transferID: info.transferID
        )

        Task {
            do {
                try await persistence.save(info)
            } catch {
                logger.error("Impossible de sauvegarder les infos de reprise : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Supprime la métadonnée de reprise d'un transfert passé à un état
    /// terminal (completed, cancelled, failed) : elle ne doit jamais
    /// resurgir comme restaurable au démarrage suivant.
    private func clearResumeInfo(for transferID: UUID) {
        let persistence = ResumePersistence.makePersistence(
            transferID: transferID
        )

        Task {
            do {
                try await persistence.clear()
            } catch {
                logger.warning("Impossible de nettoyer les infos de reprise : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func recordHistory(transferID: UUID, status: TransferStatus) {
        guard let transfer = store.transfer(withID: transferID) else { return }
        let endDate = Date()
        let duration = transfer.startedAt.map { endDate.timeIntervalSince($0) } ?? 0
        let speed = duration > 0 ? Double(transfer.fileSize) / 1_048_576.0 / duration : 0
        let fileType = transfer.sourceFileURL?.pathExtension.lowercased() ?? ""
        let direction: TransferDirection = transfer.direction == .outgoing ? .sent : .received

        let entry = TransferHistoryEntry(
            id: transfer.id,
            fileName: transfer.fileName,
            fileSize: transfer.fileSize,
            direction: direction,
            startDate: transfer.startedAt ?? transfer.createdAt,
            endDate: endDate,
            status: status,
            remoteDeviceName: transfer.peer.name,
            remoteDeviceType: transfer.peer.model,
            fileType: fileType.isEmpty ? "unknown" : fileType,
            fileCount: 1,
            transferSpeed: speed,
            sha256: transfer.sha256
        )
        historyStore.addEntry(entry)
    }

    // MARK: - Nettoyage

    func removeTransfer(
        transferID: UUID
    ) {
        store.removeTransfer(
            transferID: transferID
        )
    }

    func incomingWriterWrittenBytes(transferID: UUID) -> Int64 {
        return incomingManager.getWrittenBytes(transferID: transferID)
    }

    func incomingPartialFileBytes(transferID: UUID) -> Int64 {
        return incomingManager.partialFileBytes(transferID: transferID)
    }

    func reopenIncomingWriter(transferID: UUID, atOffset offset: Int64) -> Bool {
        return incomingManager.reopenWriterForResume(transferID: transferID, atOffset: offset)
    }

    func reopenIncomingWriterAndWait(
        transferID: UUID,
        atOffset offset: Int64
    ) async -> Bool {
        await incomingManager.reopenWriterForResumeAndWait(
            transferID: transferID,
            atOffset: offset
        )
    }

    func resumeIncomingTransfer(
        transferID: UUID,
        connectionManager: ConnectionManager
    ) -> Bool {
        return resumeIncoming(transferID: transferID, connectionManager: connectionManager)
    }

    func cleanupTransfer(
        transferID: UUID
    ) {
        incomingManager.cancelTransfer(
            transferID: transferID
        )

        outgoingManager.removeSource(
            transferID: transferID,
            deleteFile: true
        )

        // Nettoyer les métadonnées de reprise si elles existent
        let persistence = ResumePersistence.makePersistence(transferID: transferID)
        Task {
            do {
                try await persistence.clear()
            } catch {
                logger.warning("Impossible de nettoyer les infos de reprise : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cleanupAllTransfers() {
        store.cancelActiveTransfers()
        incomingManager.cleanupAll()
        outgoingManager.cleanupAll()
        storage.forgetBatchFolders()
    }

    /// Reconstruit, au démarrage de l'app, un transfert interrompu à partir
    /// de ses métadonnées de reprise persistées.
    ///
    /// Le transfert reparaît dans la liste en état `.interrupted`, avec la
    /// progression réconciliée sur la taille réelle du `.partial`. Sans
    /// auto-reprise ici : l'utilisateur relance, ou la reconnexion du pair
    /// déclenchera la campagne automatique.
    ///
    /// Un transfert déjà connu (double démarrage, restauration rejouée)
    /// n'est pas dupliqué.
    func restoreInterruptedTransfer(
        info: ResumeTransferInfo,
        transferredBytes: Int64
    ) {
        guard !store.hasTransfer(info.transferID) else {
            logger.info("Transfert déjà restauré : \(info.transferID, privacy: .public)")
            return
        }

        let direction: Transfer.Direction = info.direction == "outgoing"
            ? .outgoing
            : .incoming

        // Le nom du pair est connu quand la métadonnée a été écrite par
        // cette session ; les métadonnées antérieures (ou restaurées d'un
        // ancien format) retombent sur le libellé générique.
        let peer = Device(
            id: info.peerID,
            name: info.peerName ?? "Appareil inconnu",
            model: "Appareil inconnu",
            systemVersion: "Inconnue"
        )

        let transfer = Transfer(
            id: info.transferID,
            peer: peer,
            fileName: info.fileName,
            fileSize: info.fileSize,
            direction: direction,
            state: .interrupted,
            transferredBytes: transferredBytes,
            // Côté émission, la copie temporaire locale est la source de la
            // reprise ; l'original est référencé séparément pour l'affichage.
            sourceFileURL: direction == .outgoing
                ? (info.sourceFileURL ?? info.partialFileURL)
                : nil,
            localFileURL: direction == .incoming ? info.partialFileURL : nil,
            // L'empreinte calculée au premier envoi est restaurée avec le
            // transfert : sans elle, une reprise devrait soit recalculer un
            // SHA-256 complet au mauvais moment (dans le chemin critique),
            // soit partir sans empreinte.
            sha256: info.sha256
        )

        if direction == .outgoing,
           let sourceURL = info.sourceFileURL,
           FileManager.default.fileExists(atPath: sourceURL.path) {
            if FileManager.default.fileExists(atPath: info.partialFileURL.path) {
                // La copie temporaire a survécu au redémarrage : réenregistrer
                // les deux URLs pour qu'une reprise reparte de la copie.
                store.setSourceFileURL(transferID: transfer.id, url: sourceURL)
                registerOutgoingSource(
                    transferID: transfer.id,
                    fileURL: info.partialFileURL,
                    originalFileURL: sourceURL,
                    isTemporary: true
                )
            } else {
                // La copie temporaire a disparu (purge du dossier temporaire)
                // mais l'original existe : l'envoi reste restaurable et
                // reprendra à zéro depuis l'original.
                store.setSourceFileURL(transferID: transfer.id, url: sourceURL)
                registerOutgoingSource(
                    transferID: transfer.id,
                    fileURL: sourceURL,
                    isTemporary: false
                )
            }
        }

        store.append(transfer)
    }

    /// Nettoyage de fin de session, en préservant ce dont une reprise
    /// ultérieure a besoin.
    ///
    /// - Les réceptions actives : le writer est fermé sans supprimer le
    ///   `.partial`, qui porte les octets déjà reçus.
    /// - Les envois interrompus : la source sortante est conservée, l'envoi
    ///   reprendra à partir d'elle. Les envois non reprisables (annulés,
    ///   échoués) sont nettoyés comme avant.
    func finishSessionCleanup(preserving resumableIDs: [UUID]) {
        incomingManager.closeWritersWithoutDeletingPartials(
            for: resumableIDs
        )

        outgoingManager.cleanupAllExcept(transferIDs: resumableIDs)
        storage.forgetBatchFolders()
    }
}