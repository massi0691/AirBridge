//
//  ChunkSink.swift
//  AirBridge
//
//  Sérialise hors MainActor le travail lourd de la réception de chunks :
//  - déchiffrement ChaCha20-Poly1305 (CPU-bound)
//  - écriture disque via `IncomingFileWriter` (I/O synchrone sur `FileHandle`)
//  - drainage du buffer de chunks en désordre
//  - calcul d'intégrité (overflow, taille annoncée)
//
//  L'actor possède **un** `IncomingFileWriter` par transfert et **un**
//  `ChunkStreamCipher` global. La sérialisation naturelle de l'actor
//  garantit qu'aucun writer n'est jamais manipulé en concurrence, ce
//  qui dispense de rendre `IncomingFileWriter` lui-même `Sendable`.
//
//  L'actor ne touche JAMAIS `TransferStore` (UI, `@MainActor`). À la
//  place, il retourne un `ChunkSinkResult` sérialisable que le
//  `IncomingTransferManager` publie lui-même sur le store depuis le
//  MainActor. C'est l'API publique (toujours sur MainActor) qui fait
//  foi pour l'observabilité.
//

import Foundation
import CryptoKit

/// Résultat d'un appel à `processChunk`.
///
/// Valeur `Sendable` : l'actor n'a pas accès au `TransferStore` (UI),
/// c'est l'appelant sur MainActor qui traduit le résultat en mutation
/// du store. C'est aussi la frontière qui permet d'éviter tout
/// `@MainActor` à l'intérieur de l'actor.
enum ChunkSinkResult: Sendable {

    /// Le chunk a été écrit (et le buffer drainé). `writtenBytes` est
    /// la nouvelle taille sur disque. Le MainActor peut publier
    /// l'avancement.
    case written(writtenBytes: Int64)

    /// Le chunk a été bufferisé en attente d'un prédécesseur. Aucune
    /// écriture disque n'a eu lieu, mais le chunk n'est pas perdu :
    /// il sera drainé dès que le trou sera comblé. `writtenBytes`
    /// reste la taille actuelle.
    case buffered(writtenBytes: Int64)

    /// Le chunk est un doublon (offset < writtenBytes). Ignoré sans
    /// erreur, le fichier reste intègre.
    case duplicate

    /// Le chunk a déclenché un échec de déchiffrement
    /// ChaCha20-Poly1305. Le buffer est vidé. Le transfert doit
    /// passer en `.failed`.
    case decryptionFailed

    /// Le chunk dépasse la taille annoncée. Le writer est fermé, le
    /// buffer vidé. Le transfert doit passer en `.failed`.
    case overflow

    /// Le chunk ne correspond à aucun writer connu. Le transfert doit
    /// passer en `.failed`.
    case unknownTransfer

    /// Une interruption réseau récupérable a été détectée pendant
    /// l'écriture : le `.partial` est conservé, le buffer vidé. Le
    /// transfert doit passer en `.interrupted` à l'offset
    /// effectivement écrit sur disque.
    case interrupted(writtenBytes: Int64, error: String)

    /// Une erreur d'écriture irrécupérable s'est produite. Le
    /// `.partial` est supprimé, le buffer vidé. Le transfert doit
    /// passer en `.failed`.
    case writeFailed(reason: String)
}

/// Résultat de `finalize`.
enum ChunkSinkFinalizeResult: Sendable {

    /// Finalisation réussie. Le writer est fermé (le `.partial`
    /// existe, n'est pas supprimé). `writtenBytes` est la taille
    /// finale.
    case ok(writtenBytes: Int64)

    /// Le buffer contenait encore des chunks non contigus au moment
    /// de la finalisation : un trou central. Le `.partial` est
    /// supprimé, le transfert doit passer en `.failed`.
    case holeDetected(remaining: Int)

    /// La taille écrite ne correspond pas à la taille annoncée.
    /// Le `.partial` est supprimé, le transfert doit passer en
    /// `.failed`.
    case sizeMismatch(expected: Int64, received: Int64)

    /// Le writer n'existe pas (transfert inconnu ou déjà nettoyé).
    /// Le transfert doit passer en `.failed`.
    case unknown

    /// Une erreur d'écriture s'est produite pendant le drainage.
    /// Le `.partial` est supprimé, le transfert doit passer en
    /// `.failed`.
    case writeFailed(reason: String)
}

/// Actor dédié au pipeline de réception (déchiffrement + écriture +
/// drainage). Voir commentaire en tête de fichier pour la
/// justification.
actor ChunkSink {

    /// Writers en cours, indexés par `transferID`. L'actor possède
    /// chaque writer et en sérialise tous les accès.
    private var writers: [UUID: IncomingFileWriter] = [:]

    /// Tampon de chunks en désordre, indexés par offset. Voir le
    /// commentaire équivalent dans `IncomingTransferManager` pour
    /// la politique de drainage.
    private var pendingChunks: [UUID: [Int64: Data]] = [:]

    /// Chiffreur de session. En mode transparent tant qu'aucune clé
    /// n'est installée.
    private var cipher: ChunkStreamCipher = ChunkStreamCipher()

    /// Taille de chunk de secours conservée pour les tests et les anciens
    /// appels directs. Le chemin réseau utilise `negotiatedChunkSizes`,
    /// indexé par transfert.
    private var negotiatedChunkSize: Int = 0
    private var negotiatedChunkSizes: [UUID: Int] = [:]
    private var encryptionRequiredFor: Set<UUID> = []

    /// Limites de mémoire indépendantes de la taille annoncée par le pair.
    /// Une annonce de 64 Gio ne doit jamais autoriser 64 Gio de buffer RAM.
    private let maximumPendingBytes: Int64 = 32 * 1024 * 1024
    private let maximumPendingChunks = 128
    private let maximumPendingGap: Int64 = 64 * 1024 * 1024

    // MARK: - Configuration

    /// Installe le chiffreur de session. À partir de cet appel, les
    /// chunks binaires v2 sont déchiffrés par ChaCha20-Poly1305.
    func setCipher(_ cipher: ChunkStreamCipher) {
        self.cipher = cipher
    }

    /// Réinitialise le chiffreur en mode transparent.
    func clearCipher() {
        self.cipher = ChunkStreamCipher()
    }

    /// Mémorise une taille de chunk de secours.
    func setNegotiatedChunkSize(_ size: Int) {
        self.negotiatedChunkSize = size
    }

    /// Mémorise la taille propre à un transfert. Elle entre dans l'AAD
    /// indirectement via le `chunkIndex` et ne doit jamais être remplacée
    /// par celle d'un autre fichier du même lot.
    func setNegotiatedChunkSize(_ size: Int, for transferID: UUID) {
        negotiatedChunkSizes[transferID] = size
    }

    func requireEncryption(for transferID: UUID) {
        encryptionRequiredFor.insert(transferID)
    }

    // MARK: - Cycle de vie d'un writer

    /// Crée un nouveau writer pour un transfert.
    func prepareWriter(for transferID: UUID) throws {
        let writer = try IncomingFileWriter(transferID: transferID)
        writers[transferID] = writer
        pendingChunks[transferID] = nil
        negotiatedChunkSizes[transferID] = nil
        encryptionRequiredFor.remove(transferID)
    }

    /// Rouvre un writer existant à un offset donné (cas de la
    /// reprise). Le buffer en mémoire est vidé : l'émetteur rejoue
    /// ce qui manque depuis l'offset accepté, on repart d'un état
    /// propre.
    func reopenWriter(
        for transferID: UUID,
        atOffset offset: Int64
    ) throws -> Int64 {
        let writer = try IncomingFileWriter(
            transferID: transferID,
            appendAtOffset: offset
        )
        writers[transferID] = writer
        pendingChunks[transferID] = nil
        return writer.writtenBytes
    }

    /// Annulation : le writer est fermé, le `.partial` supprimé.
    func cancel(transferID: UUID) {
        writers[transferID]?.cancel()
        writers[transferID] = nil
        pendingChunks[transferID] = nil
        negotiatedChunkSizes[transferID] = nil
        encryptionRequiredFor.remove(transferID)
    }

    /// Interruption récupérable : le writer est fermé sans
    /// suppression du `.partial`.
    func interrupt(transferID: UUID) {
        guard let writer = writers[transferID] else { return }
        try? writer.close()
        writers[transferID] = nil
        pendingChunks[transferID] = nil
    }

    /// Ferme tous les writers (chacun avec annulation — supprime
    /// les `.partial`). Utilisé par `cleanupAll`.
    func cleanupAll() {
        let activeWriters = writers
        writers.removeAll()
        pendingChunks.removeAll()
        negotiatedChunkSizes.removeAll()
        encryptionRequiredFor.removeAll()
        for (_, writer) in activeWriters {
            writer.cancel()
        }
    }

    /// Ferme sans supprimer les `.partial` des transferts indiqués
    /// (déconnexion). Les autres writers sont fermés avec
    /// annulation.
    func closeWritersWithoutDeletingPartials(for transferIDs: [UUID]) {
        let preserved = Set(transferIDs)
        for (transferID, writer) in writers {
            if preserved.contains(transferID) {
                try? writer.close()
                writers[transferID] = nil
                pendingChunks[transferID] = nil
            }
        }
    }

    // MARK: - Pipeline principal

    /// Traite un chunk : déchiffre, écrit (ou bufferise), draine.
    /// Retourne un résultat sérialisable que l'appelant (sur
    /// MainActor) traduit en mise à jour du `TransferStore`.
    func processChunk(
        transferID: UUID,
        offset: Int64,
        data: Data,
        sessionId: UUID,
        chunkSize: Int,
        announcedSize: Int64
    ) -> ChunkSinkResult {

        guard let writer = writers[transferID] else {
            return .unknownTransfer
        }

        // 1) Déchiffrement ChaCha20-Poly1305. Pour un transfert v2,
        // l'absence de clé est une erreur, jamais un mode transparent.
        guard !encryptionRequiredFor.contains(transferID) || cipher.hasKey else {
            return .decryptionFailed
        }

        let plaintext: Data
        if cipher.hasKey {
            let effectiveChunkSize = chunkSize > 0
                ? chunkSize
                : (negotiatedChunkSizes[transferID] ?? negotiatedChunkSize)
            let chunkIndex: UInt32 = {
                guard effectiveChunkSize > 0 else {
                    return UInt32(offset >> 32)
                }
                return UInt32(offset / Int64(effectiveChunkSize))
            }()
            guard let decrypted = cipher.decrypt(
                data,
                transferID: transferID,
                chunkIndex: chunkIndex,
                sessionId: sessionId
            ) else {
                pendingChunks[transferID] = nil
                return .decryptionFailed
            }
            plaintext = decrypted
        } else {
            plaintext = data
        }

        // 2) Garde anti-saturation. Le plafond porte sur ce qui est
        // *écrit* plus ce qui est déjà retenu en mémoire, en
        // *plaintext* (cf. commentaire équivalent dans
        // `IncomingTransferManager`).
        let pendingBytes = pendingChunks[transferID]?
            .values.reduce(Int64(0)) { $0 + Int64($1.count) } ?? 0
        let (projectedBytes, didOverflow) = writer.writtenBytes
            .addingReportingOverflow(
                pendingBytes + Int64(plaintext.count)
            )

        if didOverflow || projectedBytes > announcedSize {
            writer.cancel()
            writers[transferID] = nil
            pendingChunks[transferID] = nil
            return .overflow
        }

        // 3) Trois cas selon l'offset reçu.
        if offset < writer.writtenBytes {
            return .duplicate
        } else if offset > writer.writtenBytes {
            let pendingCount = pendingChunks[transferID]?.count ?? 0
            let gap = offset - writer.writtenBytes
            guard pendingCount < maximumPendingChunks,
                  pendingBytes + Int64(plaintext.count) <= maximumPendingBytes,
                  gap <= maximumPendingGap else {
                writer.cancel()
                writers[transferID] = nil
                pendingChunks[transferID] = nil
                return .overflow
            }
            pendingChunks[transferID, default: [:]][offset] = plaintext
            return .buffered(writtenBytes: writer.writtenBytes)
        }

        // offset == writer.writtenBytes : on est dans l'ordre.
        do {
            try writer.append(data: plaintext, at: offset)
            try drainPending(for: transferID)
        } catch {
            if NetworkErrorClassifier.isRecoverableNetworkInterruption(error) {
                try? writer.close()
                writers[transferID] = nil
                pendingChunks[transferID] = nil
                return .interrupted(
                    writtenBytes: writtenBytesFromDisk(transferID: transferID),
                    error: String(describing: error)
                )
            }
            writer.cancel()
            writers[transferID] = nil
            pendingChunks[transferID] = nil
            return .writeFailed(reason: String(describing: error))
        }

        return .written(writtenBytes: writer.writtenBytes)
    }

    /// Purge séquentielle du buffer de chunks en attente.
    private func drainPending(for transferID: UUID) throws {
        guard let writer = writers[transferID] else { return }
        while let nextOffset = pendingChunks[transferID]?
            .keys.sorted().first(where: { $0 == writer.writtenBytes }) {
            let data = pendingChunks[transferID]?.removeValue(
                forKey: nextOffset
            )
            if pendingChunks[transferID]?.isEmpty == true {
                pendingChunks[transferID] = nil
            }
            guard let data else { break }
            try writer.appendInOrder(data: data)
        }
    }

    // MARK: - Finalisation

    /// Finalise un transfert. Le buffer est d'abord drainé (un
    /// transfert en désordre se termine souvent avec tous ses
    /// chunks disponibles). Si des chunks restent en mémoire
    /// après drainage, c'est qu'un trou central n'a jamais été
    /// comblé : on échoue sans inventer d'octets.
    func finalize(
        transferID: UUID,
        announcedSize: Int64
    ) -> ChunkSinkFinalizeResult {

        guard let writer = writers[transferID] else {
            return .unknown
        }

        do {
            try drainPending(for: transferID)
        } catch {
            writer.cancel()
            writers[transferID] = nil
            pendingChunks[transferID] = nil
            return .writeFailed(reason: String(describing: error))
        }

        if let remaining = pendingChunks[transferID],
           !remaining.isEmpty {
            writer.cancel()
            writers[transferID] = nil
            pendingChunks[transferID] = nil
            return .holeDetected(remaining: remaining.count)
        }

        let receivedBytes = writer.writtenBytes

        guard receivedBytes == announcedSize else {
            writer.cancel()
            writers[transferID] = nil
            pendingChunks[transferID] = nil
            return .sizeMismatch(
                expected: announcedSize,
                received: receivedBytes
            )
        }

        do {
            try writer.close()
            pendingChunks[transferID] = nil
            return .ok(writtenBytes: receivedBytes)
        } catch {
            writer.cancel()
            writers[transferID] = nil
            pendingChunks[transferID] = nil
            return .writeFailed(reason: String(describing: error))
        }
    }

    // MARK: - Consultations

    /// Taille écrite sur disque, telle que l'actor la voit. N'est
    /// PAS synchronisée avec le getter sync `partialFileBytes` qui
    /// lit depuis `FileManager` : les deux coïncident dès qu'un
    /// `writer.append` a fini, mais entre l'incrément de
    /// `writer.writtenBytes` et la mise à jour de la table
    /// d'indexation du fichier, ils peuvent diverger d'une fraction
    /// d'octet. Le getter sync reste la vérité de référence pour
    /// l'extérieur.
    func writtenBytes(transferID: UUID) -> Int64 {
        writers[transferID]?.writtenBytes ?? 0
    }

    /// URL du fichier `.partial` d'un transfert, ou `nil` si le
    /// writer n'existe pas dans l'actor.
    func temporaryURL(transferID: UUID) -> URL? {
        writers[transferID]?.temporaryURL
    }

    /// Indique si un writer existe pour ce transfert.
    func hasWriter(transferID: UUID) -> Bool {
        writers[transferID] != nil
    }

    /// Retire un writer du dictionnaire sans toucher au fichier
    /// (utilisé après `saveReceivedFile` côté `TransferManager`).
    func removeWriter(transferID: UUID) {
        writers[transferID] = nil
        pendingChunks[transferID] = nil
        negotiatedChunkSizes[transferID] = nil
        encryptionRequiredFor.remove(transferID)
    }

    // MARK: - Helpers

    /// Taille réelle sur disque d'un `.partial`, indépendamment
    /// de l'état de l'actor. Utilisé en cas d'interruption pour
    /// rapporter la bonne valeur à `markInterrupted`.
    private func writtenBytesFromDisk(transferID: UUID) -> Int64 {
        let url = IncomingFileWriter.temporaryURL(for: transferID)
        guard let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return 0
        }
        return Int64(size)
    }
}
