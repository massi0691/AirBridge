//
//  IncomingTransferManager.swift
//  AirBridge
//

import Foundation
import CryptoKit
import OSLog

/// Sort d'une demande de transfert entrante.
///
/// Un booléen ne suffisait pas : « écartée » et « déjà connue » demandent
/// des réponses opposées à l'émetteur.
enum IncomingRequestOutcome: Sendable {

    /// Réception préparée ; le fichier peut être soumis à l'utilisateur.
    case accepted

    /// Annonce écartée. L'émetteur doit l'apprendre tout de suite.
    case rejected

    /// Demande déjà connue, ignorée en silence.
    ///
    /// Surtout pas refusée : un refus porterait le même identifiant que le
    /// transfert déjà en cours, et l'avorterait.
    case duplicate
}

@MainActor
final class IncomingTransferManager {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "transfer.incoming"
    )

    private let store: TransferStore

    /// Sink actoriel qui sérialise hors MainActor le travail lourd de
    /// la réception (déchiffrement ChaCha20-Poly1305, écriture
    /// disque, drainage du buffer de chunks en désordre, calcul
    /// d'intégrité). C'est l'isolation du `ChunkSink` qui absorbe la
    /// fenêtre d'envoi 4 chunks : la sérialisation naturelle de
    /// l'actor évite qu'une deuxième écriture disque entre en course
    /// avec la première, et le MainActor reste libre pour l'UI et les
    /// autres Tasks (timeouts, store updates, prochaine trame réseau).
    private let sink = ChunkSink()

    /// Transferts dont l'annulation a été demandée. Consulté à
    /// chaque chunk entrant, donc doit rester immédiatement
    /// accessible sur MainActor (la garde anti-écriture après
    /// annulation est un point de non-régression).
    private var cancelledTransfers: Set<UUID> = []

    /// Lot d'origine d'un transfert entrant, tel que l'émetteur l'a
    /// annoncé.
    ///
    /// Conservé ici plutôt que sur `Transfer` : c'est une information de
    /// rangement, utile au seul moment de l'enregistrement, alors que
    /// `Transfer` décrit ce que l'interface affiche.
    private var batchContexts: [UUID: ReceivedBatchContext] = [:]

    /// Ce qu'un lot a déjà annoncé.
    ///
    /// Les plafonds portent sur le lot entier, mais les fichiers arrivent un
    /// par un : sans mémoire du cumul, chaque fichier serait jugé seul et le
    /// plafond du lot ne voudrait rien dire.
    ///
    /// Le décompte survit à la fin d'un fichier — un lot ne se réduit pas
    /// quand un de ses fichiers aboutit — et disparaît avec la session, dans
    /// `cleanupAll()`.
    private var batchTallies: [UUID: BatchTally] = [:]

    /// Décompte courant d'un lot en réception.
    private struct BatchTally {
        var fileCount: Int
        var totalBytes: Int64
    }

    init(store: TransferStore) {
        self.store = store
    }

    // MARK: - Gestion du chiffreur de session

    /// Installe la clé symétrique de session dérivée du handshake ECDH.
    /// À partir de cet appel, les chunks entrants sont déchiffrés par
    /// ChaCha20-Poly1305 via `ChunkStreamCipher` avant écriture.
    func installSessionKey(_ key: SymmetricKey) {
        let cipher = ChunkStreamCipher(key: key)
        Task { await self.sink.setCipher(cipher) }
    }

    /// Variante attendue par le handshake : le retour ne survient qu'après
    /// que l'actor de réception possède effectivement la clé.
    func installSessionKeyAndWait(_ key: SymmetricKey) async {
        await sink.setCipher(ChunkStreamCipher(key: key))
    }

    /// Réinitialise le chiffreur. Le chemin de production attend la fin de
    /// cette opération avant d'autoriser une nouvelle session.
    func clearSessionKey() {
        Task { await self.sink.clearCipher() }
    }

    func clearSessionKeyAndWait() async {
        await sink.clearCipher()
    }

    /// API historique pour les tests et les appels directs.
    func setNegotiatedChunkSize(_ size: Int) {
        Task { await self.sink.setNegotiatedChunkSize(size) }
    }

    /// Configure la taille de chunk et l'obligation de chiffrement pour un
    /// transfert précis, dans le même ordre actoriel que les chunks.
    func setNegotiatedChunkSize(_ size: Int, for transferID: UUID) {
        Task { [sink] in
            await sink.setNegotiatedChunkSize(size, for: transferID)
            await sink.requireEncryption(for: transferID)
        }
    }

    func setNegotiatedChunkSizeAndRequireEncryption(
        _ size: Int,
        for transferID: UUID
    ) async {
        await sink.setNegotiatedChunkSize(size, for: transferID)
        await sink.requireEncryption(for: transferID)
    }

    // MARK: - Cycle de vie d'un transfert

    /// Prépare la réception d'un fichier annoncé par un pair.
    ///
    /// Voir `IncomingRequestOutcome` pour ce que l'appelant doit en faire.
    /// `initialState` permet de pré-marquer le transfert comme accepté
    /// (cas d'un pair de confiance).
    ///
    /// **Async** : la création du writer (sur l'actor `ChunkSink`) est
    /// awaited avant le retour, pour que le contrat « `.accepted` =
    /// writer prêt » soit respecté. Sinon, un `appendReceivedChunk`
    /// synchrone qui suivrait immédiatement trouverait `hasWriter ==
    /// false` et marquerait le transfert comme échoué.
    @discardableResult
    func createTransfer(
        request: TransferRequestPayload,
        sender: Device,
        initialState: Transfer.State = .waitingForApproval
    ) async -> IncomingRequestOutcome {

        // Une même demande rejouée ne doit pas compter deux fois dans le lot :
        // le décompte servirait alors à refuser des fichiers légitimes.
        guard store.transfer(withID: request.transferID) == nil else {
            logger.info("Demande déjà connue, ignorée : \(request.transferID, privacy: .public)")

            return .duplicate
        }

        let tally = request.batchID.flatMap { batchTallies[$0] }
            ?? BatchTally(fileCount: 0, totalBytes: 0)

        guard ReceivedBatchLimits.canAccept(
            fileSize: request.fileSize,
            inBatchOf: tally.fileCount,
            totalBytes: tally.totalBytes
        ) else {

            logger.error("Annonce refusée, \(ReceivedBatchLimits.rejectionReason(fileSize: request.fileSize, inBatchOf: tally.fileCount, totalBytes: tally.totalBytes), privacy: .public)")

            return .rejected
        }

        if let batchID = request.batchID {
            batchTallies[batchID] = BatchTally(
                fileCount: tally.fileCount + 1,
                totalBytes: tally.totalBytes + request.fileSize
            )
        }

        cancelledTransfers.remove(
            request.transferID
        )

        let transfer = Transfer(
            id: request.transferID,
            peer: sender,
            fileName: request.fileName,
            fileSize: request.fileSize,
            direction: .incoming,
            state: initialState,
            transferredBytes: 0,
            batchID: request.batchID
        )

        store.append(transfer)

        // L'émetteur ne renseigne le lot que pour une sélection multiple :
        // sa présence suffit donc à décider du sous-dossier, sans compter
        // les fichiers reçus.
        if let batchID = request.batchID {

            batchContexts[request.transferID] =
                ReceivedBatchContext(
                    batchID: batchID,
                    folderName: request.batchFolderName,
                    relativePath: request.relativePath
                )
        }

        // Création du writer côté actor (I/O disque hors MainActor),
        // awaited avant le retour : le contrat `.accepted` signifie
        // « writer prêt, on peut écrire ». Si la création échoue
        // (disque saturé, dossier inaccessible), on signale l'échec
        // et l'annonce est refusée : l'émetteur l'apprend tout de
        // suite, et l'utilisateur ne voit pas un transfert condamné
        // d'avance.
        let transferID = request.transferID
        do {
            try await sink.prepareWriter(for: transferID)
        } catch {
            // Le tally et les métadonnées temporaires doivent être annulés
            // si le disque ne permet pas de créer le writer. Sinon une
            // annonce invalide consommerait définitivement le quota du lot.
            rollbackAnnouncement(request)
            logger.error("Impossible de préparer le fichier temporaire : \(error.localizedDescription, privacy: .public)")
            return .rejected
        }

        // Le `chunkIndex` qui entre dans l'AAD du `ChunkStreamCipher` est
        // calculé côté récepteur comme `offset / chunkSize`. Si l'on ne
        // renseigne pas `negotiatedChunkSize` ici, le `ChunkSink` retombe
        // sur la dérivation `offset >> 32`, qui vaut 0 pour tout fichier
        // de moins de 4 Gio (772 Mio tombe dans ce cas) : tous les chunks
        // reçus voient alors un `chunkIndex = 0` alors que l'émetteur
        // émet 0, 1, 2, ... Le premier chunk passe par coïncidence, tous
        // les suivants sont rejetés par l'auth ChaCha20-Poly1305.
        //
        // `TransferChunkSizing` est une fonction pure, partagée avec
        // l'émetteur : appliquée au même `fileSize` des deux côtés, elle
        // produit la même taille. Aucun nouveau champ de protocole n'est
        // nécessaire — la cohérence est garantie par la symétrie de la
        // fonction de découpage.
        let negotiatedSize = TransferChunkSizing.chunkSize(
            forFileSize: request.fileSize
        )
        await setNegotiatedChunkSizeAndRequireEncryption(
            negotiatedSize,
            for: transferID
        )

        logger.info("Transfert entrant créé : \(request.fileName, privacy: .public)")

        return .accepted
    }

    /// Annule entièrement une annonce qui n'a pas pu devenir un writer
    /// utilisable. Le quota est réservé seulement pendant la préparation.
    private func rollbackAnnouncement(_ request: TransferRequestPayload) {
        store.removeTransfer(transferID: request.transferID)
        batchContexts[request.transferID] = nil

        guard let batchID = request.batchID,
              var tally = batchTallies[batchID] else {
            return
        }

        tally.fileCount = max(0, tally.fileCount - 1)
        tally.totalBytes = max(0, tally.totalBytes - request.fileSize)
        if tally.fileCount == 0 {
            batchTallies[batchID] = nil
        } else {
            batchTallies[batchID] = tally
        }
    }

    // MARK: - Réception d'un chunk

    /// Traite un chunk entrant. **API async** depuis la phase 2-bis :
    /// le travail lourd (déchiffrement + écriture disque + drainage)
    /// est sérialisé sur le `ChunkSink` actor, le MainActor reste
    /// libre pour l'UI et les autres Tasks. Les gardes rapides
    /// (annulation, état du transfert) restent synchrones car elles
    /// ne sont pas dans le chemin chaud du bottleneck.
    @discardableResult
    func appendChunk(
        transferID: UUID,
        offset: Int64,
        data: Data,
        sessionId: UUID,
        chunkSize: Int = 0
    ) async -> Bool {
        guard !cancelledTransfers.contains(transferID) else {
            logger.debug("Chunk ignoré : transfert annulé")
            return false
        }

        // La valeur n'est plus lue pour la trace, mais l'existence reste une
        // condition : un morceau pour un transfert inconnu n'a nulle part où
        // aller.
        guard let transfer = store.transfer(withID: transferID) else {
            logger.error("Transfert introuvable : \(transferID, privacy: .public)")
            return false
        }

        // Rien ne s'écrit avant que l'utilisateur ait accepté. Sans cette
        // condition, un pair remplit le disque pendant que sa demande attend
        // une réponse à l'écran — et les plafonds annoncés ne protègent
        // alors plus rien. `.interrupted` accepte de nouveau l'écriture :
        // c'est la reprise qui la réactive.
        switch transfer.state {
        case .accepted, .transferring, .interrupted:
            break

        case .requesting, .waitingForApproval,
             .completed, .rejected, .cancelled, .failed:

            logger.debug("Morceau ignoré : transfert en état « \(transfer.state.displayName, privacy: .public) »")

            return false
        }

        // Vérification que le sink possède un writer pour ce
        // transfert. Sans writer, on ne peut rien écrire. La
        // condition est consultée sur l'actor (l'absence de
        // writer est l'état stable le plus fréquent). Depuis la
        // mise en `async` de `createTransfer`, le writer est
        // toujours présent ici en succès de création — ce garde
        // reste utile pour les reprises ou les chemins où le
        // writer peut être refermé.
        let hasWriter = await sink.hasWriter(transferID: transferID)
        guard hasWriter else {
            logger.error("Aucun fichier temporaire pour : \(transferID, privacy: .public)")
            store.markFailed(transferID: transferID)
            return false
        }

        let result = await sink.processChunk(
            transferID: transferID,
            offset: offset,
            data: data,
            sessionId: sessionId,
            chunkSize: chunkSize,
            announcedSize: transfer.fileSize
        )

        return applyResult(
            result,
            transferID: transferID,
            announcedSize: transfer.fileSize
        )
    }

    /// Applique le résultat d'un `processChunk` au store. C'est la
    /// frontière qui isole l'actor de `TransferStore` (UI).
    private func applyResult(
        _ result: ChunkSinkResult,
        transferID: UUID,
        announcedSize: Int64
    ) -> Bool {
        switch result {
        case .written(let writtenBytes):
            store.updateProgress(
                transferID: transferID,
                transferredBytes: writtenBytes
            )
            return true

        case .buffered(let writtenBytes):
            // Le MainActor n'est pas mis au courant à chaque
            // chunk bufferisé : le prochain `.written` (drainage)
            // publiera la nouvelle taille. Mais pour la
            // lisibilité de la progression côté UI, on publie
            // l'offset actuel inchangé — l'utilisateur voit
            // l'avancement sauter quand le trou est comblé.
            store.updateProgress(
                transferID: transferID,
                transferredBytes: writtenBytes
            )
            return true

        case .duplicate:
            // Doublon silencieux : on retourne true pour ne pas
            // suggérer à l'émetteur un échec. La taille ne
            // change pas, pas de publication UI.
            return true

        case .decryptionFailed:
            logger.error("Chunk rejeté : authentification ChaCha20-Poly1305 invalide")
            store.markFailed(transferID: transferID)
            return false

        case .overflow:
            logger.error("Morceau au-delà de la taille annoncée : \(announcedSize) octets annoncés")
            store.markFailed(transferID: transferID)
            return false

        case .unknownTransfer:
            logger.error("Aucun fichier temporaire pour : \(transferID, privacy: .public)")
            store.markFailed(transferID: transferID)
            return false

        case .interrupted(let writtenBytes, let error):
            logger.warning("Interruption réseau pendant l'écriture : \(error, privacy: .public)")
            store.markInterrupted(
                transferID: transferID,
                transferredBytes: writtenBytes
            )
            return false

        case .writeFailed(let reason):
            logger.error("Impossible d'écrire le morceau : \(reason, privacy: .public)")
            store.markFailed(transferID: transferID)
            return false
        }
    }

    // MARK: - Finalisation

    @discardableResult
    func finalize(
        transferID: UUID,
        announcedTotalBytes: Int64
    ) async -> Bool {
        guard !cancelledTransfers.contains(
            transferID
        ) else {
            logger.debug("Finalisation ignorée : transfert annulé")

            return false
        }

        guard let transfer =
            store.transfer(withID: transferID) else {
            logger.error("Transfert introuvable : \(transferID, privacy: .public)")

            return false
        }

        let hasWriter = await sink.hasWriter(transferID: transferID)
        guard hasWriter else {
            logger.error("Aucun fichier temporaire pour : \(transferID, privacy: .public)")

            return false
        }

        let result = await sink.finalize(
            transferID: transferID,
            announcedSize: announcedTotalBytes
        )

        switch result {
        case .ok(let writtenBytes):
            store.updateProgress(
                transferID: transferID,
                transferredBytes: writtenBytes
            )
            return true

        case .holeDetected(let remaining):
            logger.error("Transfert incomplet : chunks manquants en mémoire. Manquants : \(remaining)")
            store.markFailed(transferID: transferID)
            return false

        case .sizeMismatch(_, let received):
            logger.error("Taille du transfert invalide — Attendue : \(transfer.fileSize), Annoncée : \(announcedTotalBytes), Reçue : \(received)")
            store.markFailed(transferID: transferID)
            return false

        case .unknown:
            logger.error("Writer inconnu pour finalisation : \(transferID, privacy: .public)")
            store.markFailed(transferID: transferID)
            return false

        case .writeFailed(let reason):
            logger.error("Purge du buffer impossible : \(reason, privacy: .public)")
            store.markFailed(transferID: transferID)
            return false
        }
    }

    // MARK: - Consultations (sync)

    /// URL du fichier temporaire. Peut être calculée à partir du
    /// `transferID` seul, mais on conserve la garde « writer
    /// connu » comme contrat historique. La présence d'un writer
    /// dans le sink est vérifiée de façon best-effort (la taille
    /// du fichier est lue depuis le disque, pas depuis
    /// l'instance writer).
    func temporaryFileURL(
        for transferID: UUID
    ) throws -> URL {
        let url = IncomingFileWriter.temporaryURL(for: transferID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TransferManagerError
                .receivedTemporaryFileNotFound
        }
        return url
    }

    /// Lot d'origine du transfert, `nil` pour un fichier isolé.
    func batchContext(
        for transferID: UUID
    ) -> ReceivedBatchContext? {
        batchContexts[transferID]
    }

    /// Taille écrite telle que l'actor la voit. **Sync** par
    /// convention : l'actor est mis à jour après chaque écriture,
    /// et la valeur reste cohérente avec le disque une fois
    /// l'appel `processChunk` retourné. Le getter historique
    /// `partialFileBytes` reste la vérité de référence (lit le
    /// disque via `FileManager`).
    func getWrittenBytes(transferID: UUID) -> Int64 {
        return partialFileBytes(transferID: transferID)
    }

    /// Taille réelle du fichier partiel sur disque, même sans writer ouvert
    /// (après redémarrage ou interruption).
    func partialFileBytes(transferID: UUID) -> Int64 {
        let url = IncomingFileWriter.temporaryURL(for: transferID)

        guard let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return 0
        }

        return Int64(size)
    }

    // MARK: - Reprise

    /// Rouvre le writer en mode append à l'offset accepté pour la reprise.
    ///
    /// L'offset est borné par la taille réellement écrite : reprendre au-delà
    /// créerait un trou invisible dans le fichier final.
    ///
    /// **Sync** : la reprise est un événement rare (déclenché par
    /// `resumeRequest`), pas un chemin chaud. La création du writer
    /// est une opération `O(1)` sur disque (open + seek), pas un
    /// bottleneck à paralleliser.
    /// Variante utilisée par le chemin de production : le retour ne
    /// survient qu'après l'ouverture effective du writer et sa configuration
    /// cryptographique.
    func reopenWriterForResumeAndWait(
        transferID: UUID,
        atOffset offset: Int64
    ) async -> Bool {
        cancelledTransfers.remove(transferID)

        let fileSize = store.transfer(withID: transferID)?.fileSize ?? 0
        let chunkSize = TransferChunkSizing.chunkSize(forFileSize: fileSize)
        let safeOffset = min(offset, partialFileBytes(transferID: transferID))

        do {
            await sink.setNegotiatedChunkSize(chunkSize, for: transferID)
            await sink.requireEncryption(for: transferID)
            _ = try await sink.reopenWriter(
                for: transferID,
                atOffset: safeOffset
            )
        } catch {
            logger.error("Impossible de rouvrir le writer : \(error.localizedDescription, privacy: .public)")
            return false
        }

        store.updateProgress(
            transferID: transferID,
            transferredBytes: partialFileBytes(transferID: transferID)
        )
        return true
    }

    func reopenWriterForResume(
        transferID: UUID,
        atOffset offset: Int64
    ) -> Bool {
        // Une reprise explicite lève le blocage posé à l'annulation.
        cancelledTransfers.remove(transferID)

        // Réaffirmer la taille de chunk négociée pour ce transfert :
        // le `ChunkSink` la conserve normalement à travers les
        // reconnexions Wi-Fi (l'actor survit), mais si une nouvelle
        // création de transfert a recalculé une autre valeur entre-temps
        // (test, second flux, etc.), la reprendre garantit que le
        // `chunkIndex` dérivé côté récepteur (`offset / chunkSize`)
        // reste cohérent avec l'émetteur. Sans cela, un
        // `negotiatedChunkSize` obsolète ferait dériver le `chunkIndex`
        // de l'AAD ChaCha20-Poly1305 et tous les chunks seraient
        // rejetés — ou pire, un décalage systématique dégraderait le
        // débit sans lever d'erreur visible.
        let fileSize = store.transfer(withID: transferID)?.fileSize ?? 0
        let chunkSize = TransferChunkSizing.chunkSize(forFileSize: fileSize)
        let safeOffset = min(offset, partialFileBytes(transferID: transferID))

        // Une seule transaction actorielle : configuration de la taille,
        // obligation de chiffrement, puis ouverture du writer. Un chunk de
        // reprise ne peut donc pas passer entre ces trois étapes.
        Task { [sink] in
            await sink.setNegotiatedChunkSize(chunkSize, for: transferID)
            await sink.requireEncryption(for: transferID)
            _ = try? await sink.reopenWriter(
                for: transferID,
                atOffset: safeOffset
            )
        }

        // La mise à jour de progression est immédiate :
        // l'offset est connu, le `.partial` existe déjà.
        store.updateProgress(
            transferID: transferID,
            transferredBytes: partialFileBytes(transferID: transferID)
        )

        return true
    }

    // MARK: - Interruption et annulation

    /// Ferme le writer d'un transfert interrompu SANS supprimer son
    /// `.partial`.
    ///
    /// Une coupure réseau n'invalide pas les octets déjà écrits : le
    /// fichier partiel est le point de départ de la reprise. Contrairement
    /// à `cancelTransfer()` (annulation volontaire), aucune suppression ni
    /// aucun blocage `cancelledTransfers` ici.
    func interruptTransfer(transferID: UUID) {
        let transferID = transferID
        Task { [sink] in
            await sink.interrupt(transferID: transferID)
        }

        // La taille réelle du `.partial` reste consultable après fermeture
        // via `partialFileBytes(transferID:)`, même sans writer ouvert.
        store.updateProgress(
            transferID: transferID,
            transferredBytes: partialFileBytes(transferID: transferID)
        )
    }

    func removeWriter(
        transferID: UUID
    ) {
        let transferID = transferID
        Task { [sink] in
            await sink.removeWriter(transferID: transferID)
        }
        batchContexts[transferID] = nil
    }


    func cancelTransfer(
        transferID: UUID
    ) {

        cancelledTransfers.insert(transferID)

        let transferID = transferID
        Task { [sink] in
            await sink.cancel(transferID: transferID)
        }
        batchContexts[transferID] = nil
    }



    func cleanupAll() {
        let activeWriters = writersForCleanup()

        cancelledTransfers.formUnion(activeWriters)
        batchContexts.removeAll()
        batchTallies.removeAll()

        Task { [sink] in
            await sink.cleanupAll()
        }

        logger.info("Toutes les réceptions temporaires ont été nettoyées")
    }

    /// Ferme les writers d'une liste de transferts sans supprimer leur
    /// `.partial` : sur déconnexion, le fichier partiel porte la
    /// progression déjà reçue et sert de point de départ à la reprise.
    ///
    /// Les contextes de lot sont conservés pour les mêmes identifiants :
    /// le rangement du fichier finalisé dépend d'eux.
    func closeWritersWithoutDeletingPartials(for transferIDs: [UUID]) {
        let preserved = Array(Set(transferIDs))

        Task { [sink] in
            await sink.closeWritersWithoutDeletingPartials(
                for: preserved
            )
        }
    }

    /// Snapshot des `transferID` pour lesquels l'actor détient
    /// actuellement un writer. Sert uniquement à `cleanupAll` pour
    /// marquer comme « cancelled » les transferts en cours. Best
    /// effort : un writer ouvert juste après le snapshot sera
    /// nettoyé par la suite via `cancelTransfer` ou un autre
    /// `cleanupAll`.
    private func writersForCleanup() -> [UUID] {
        // L'actor est Sendable et ses méthodes sont async.
        // Pour rester sync ici, on récupère la liste via le store
        // : tous les transferts actifs y sont référencés. Les
        // transferts terminaux (`.completed`, `.failed`, etc.)
        // n'ont plus de writer, ils n'apparaissent pas dans
        // `markCancelled` non plus.
        return store.transfers
            .filter { $0.direction == .incoming }
            .filter { transfer in
                switch transfer.state {
                case .requesting, .waitingForApproval,
                     .accepted, .transferring, .interrupted:
                    return true
                case .completed, .rejected, .cancelled, .failed:
                    return false
                }
            }
            .map { $0.id }
    }
}
