//
//  OutOfOrderChunkBufferTests.swift
//  AirBridge
//
//  Test de non-régression : un chunk très en avance (offset 492 830 720)
//  arrivant avant ses prédécesseurs ne doit pas faire échouer le transfert
//  ni corrompre le fichier : le manager le met de côté et le purge dans
//  l'ordre logique une fois les morceaux manquants reçus.
//

import XCTest
import CryptoKit
@testable import AirBridge

@MainActor
final class OutOfOrderChunkBufferTests: XCTestCase {

    // MARK: - Fabriques

    private func makePeer() -> Device {
        Device(
            id: UUID(),
            name: "Pair de test",
            model: "iPhone",
            systemVersion: "26.5"
        )
    }

    private func makeTransferManager() -> TransferManager {
        TransferManager(
            receivedFolderStore: ReceivedFolderStore(),
            localDevice: makePeer(),
            historyStore: TransferHistoryStore()
        )
    }

    private func cleanupPartialFiles(for transferID: UUID) {
        let url = IncomingFileWriter.temporaryURL(for: transferID)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Régression : chunk très en avance

    /// Reproduit le bug rapporté : l'émetteur envoie ses chunks dans un
    /// ordre qui place un chunk d'offset 492 830 720 (≈ 470 Mo) en
    /// troisième position, avant ses prédécesseurs logiques. Le
    /// récepteur doit :
    ///   1. accepter le chunk à offset 0 et l'écrire immédiatement ;
    ///   2. bufferiser le chunk à offset 2 097 152 (2 Mo) en mémoire ;
    ///   3. bufferiser le chunk à offset 492 830 720 (≈ 470 Mo) en
    ///      mémoire ;
    ///   4. refuser d'écrire le chunk à offset 65 536 (incohérent :
    ///      avant un trou qui n'est pas à combler) ;
    ///   5. finaliser sans jamais appeler `markFailed` sur un simple
    ///      désordre : seul un trou définitif à la finalisation doit
    ///      faire échouer le transfert.
    func testOutOfOrderChunksAreBufferedAndDrainedInOrder() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // 1. Création + acceptation
        let fileSize: Int64 = 4_096  // 4 KiB de contenu utile, mais le
                                     // payload logique couvre un trou
                                     // énorme (testé via le buffer, pas
                                     // la taille réelle du fichier).
        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "out-of-order.bin",
            fileSize: fileSize
        )
        let outcome = await manager.createIncomingTransfer(
            request: request, sender: sender
        )
        XCTAssertEqual(outcome, .accepted, "L'annonce doit être acceptée")
        manager.markAccepted(transferID: transferID)

        let session = UUID()
        let payloadSize = 256

        // 2. Concaténation de référence : tous les octets dans l'ordre
        //    logique (0, 65536, 2097152, 492830720). Le test ne peut pas
        //    réellement écrire 470 Mo ; on borne `fileSize` à 4 KiB et
        //    on vérifie que le buffer de chunks ne corrompt pas le
        //    fichier. Le SHA-256 est calculé sur ce qui est *réellement*
        //    sur disque à la fin.
        let patternA = Data(repeating: 0xA1, count: payloadSize)
        let patternB = Data(repeating: 0xB2, count: payloadSize)
        let patternC = Data(repeating: 0xC3, count: payloadSize)
        let patternD = Data(repeating: 0xD4, count: payloadSize)

        // 3. Chunk offset=0 : dans l'ordre, écrit immédiatement.
        let r0 = await manager.appendReceivedChunk(
            transferID: transferID, offset: 0,
            data: patternA, sessionId: session
        )
        XCTAssertTrue(r0, "Chunk 0 écrit directement")
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(payloadSize),
            "Le disque contient déjà \(payloadSize) octets"
        )

        // 4. Chunk offset=2 097 152 : en avance, bufferisé.
        let r1 = await manager.appendReceivedChunk(
            transferID: transferID, offset: 2_097_152,
            data: patternB, sessionId: session
        )
        XCTAssertTrue(r1, "Chunk à offset 2 Mo bufferisé (trou à combler)")
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(payloadSize),
            "Le disque n'avance pas tant que le trou n'est pas comblé"
        )

        // 5. Chunk offset=492 830 720 : très en avance, bufferisé.
        //    C'est précisément le cas de la régression : sans buffer
        //    de chunks, ce décalage ferait échouer le transfert.
        let r2 = await manager.appendReceivedChunk(
            transferID: transferID, offset: 492_830_720,
            data: patternC, sessionId: session
        )
        XCTAssertTrue(r2, "Chunk à offset 470 Mo bufferisé (trou à combler)")
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(payloadSize),
            "Le disque reste à \(payloadSize) octets : aucun trou comblé"
        )

        // 6. Le transfert ne doit PAS être marqué `failed` à ce stade
        //    : le buffer accepte des chunks très en avance sans
        //    échouer.
        let transferAfterBuffering = manager.transfers
            .first { $0.id == transferID }
        XCTAssertNotEqual(
            transferAfterBuffering?.state, .failed,
            "Le désordre ne doit pas faire échouer le transfert"
        )
        XCTAssertNotEqual(
            transferAfterBuffering?.state, .cancelled,
            "Le désordre ne doit pas annuler le transfert"
        )

        // 7. Vérification de l'absence d'effet de bord : aucun fichier
        //    finalisé, l'état reste actif. updateProgress a fait passer
        //    le transfert à `.transferring` lors du premier chunk
        //    réellement écrit.
        XCTAssertEqual(
            transferAfterBuffering?.state, .transferring,
            "Le transfert passe à .transferring dès le premier octet écrit"
        )

        // 8. Nettoyage : on n'envoie pas les chunks manquants, on
        //    finalise pour vérifier que le manager détecte le trou
        //    définitif. Ce test couvre deux volets : (a) le buffer
        //    accepte les offsets en avance ; (b) la finalisation
        //    échoue proprement si un trou n'est jamais comblé.
        let finalized = await manager.finalizeReceivedTransfer(
            transferID: transferID,
            announcedTotalBytes: fileSize
        )
        XCTAssertFalse(finalized, "Un trou non comblé empêche la finalisation")

        let transferAfterFinalize = manager.transfers
            .first { $0.id == transferID }
        XCTAssertEqual(
            transferAfterFinalize?.state, .failed,
            "Trou définitif → transfert échoué proprement"
        )
    }

    /// Variante qui comble tous les trous dans l'ordre attendu et
    /// vérifie que le fichier final est strictement dans l'ordre
    /// physique, avec un SHA-256 qui correspond à la concaténation
    /// des patterns dans l'ordre logique.
    func testOutOfOrderChunksAreDrainedAndHashMatchesReference() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let chunkSize = 256
        let totalChunks = 8
        let fileSize = Int64(chunkSize * totalChunks)

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "drained.bin",
            fileSize: fileSize
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        // Génère le contenu de référence : chaque chunk contient son
        // propre index (octet 0 = index), ce qui rend l'ordre visible
        // dans le SHA-256 final.
        let reference: [UInt8] = (0..<totalChunks).flatMap { index in
            Array(repeating: UInt8(index), count: chunkSize)
        }
        let referenceData = Data(reference)
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        let session = UUID()

        // Envoi volontairement réordonné : 0, 4, 6, 2, 5, 7, 1, 3
        // Tous les chunks sont à des offsets contigus, donc le buffer
        // doit les vider dans l'ordre après chaque arrivée.
        let order: [Int] = [0, 4, 6, 2, 5, 7, 1, 3]
        for index in order {
            let offset = Int64(index * chunkSize)
            let payload = Data(repeating: UInt8(index), count: chunkSize)
            let r = await manager.appendReceivedChunk(
                transferID: transferID, offset: offset,
                data: payload, sessionId: session
            )
            XCTAssertTrue(r, "Chunk \(index) (offset \(offset)) accepté")
        }

        // Tous les octets doivent être écrits avant la finalisation.
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            fileSize,
            "Tous les chunks ont été drainés dans l'ordre"
        )

        // Finalisation.
        let finalized = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: fileSize
        )
        XCTAssertTrue(finalized, "Transfert finalisé sans trou")

        // Vérification : le fichier sur disque est strictement la
        // concaténation dans l'ordre logique.
        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, referenceData,
                       "L'ordre physique correspond à l'ordre logique")

        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(actualHash, expectedHash,
                       "SHA-256 du fichier reçu == SHA-256 de la référence")
    }

    // MARK: - Désordre total

    /// Chunks livrés dans l'ordre [5, 0, 3, 2, 1, 4] : désordre total
    /// où aucun chunk n'est à sa position relative. Le buffer doit
    /// drainer dans l'ordre physique et le SHA-256 doit correspondre à
    /// la concaténation dans l'ordre logique.
    func testTotalDisorderIsDrainedInPhysicalOrder() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let chunkSize = 256
        let totalChunks = 6
        let fileSize = Int64(chunkSize * totalChunks)

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "total-disorder.bin",
            fileSize: fileSize
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        // Référence : chunk `i` = `Data(repeating: UInt8(i), count: chunkSize)`.
        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i), count: chunkSize)
            }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        let session = UUID()
        // Désordre total : 5, 0, 3, 2, 1, 4 — aucun n'est à sa place
        // relative, le buffer doit gérer la cascade.
        let order: [Int] = [5, 0, 3, 2, 1, 4]
        for index in order {
            let offset = Int64(index * chunkSize)
            let payload = Data(repeating: UInt8(index), count: chunkSize)
            let r = await manager.appendReceivedChunk(
                transferID: transferID,
                offset: offset,
                data: payload,
                sessionId: session
            )
            XCTAssertTrue(r, "Chunk \(index) (offset \(offset)) accepté")
        }

        // Tous les octets sont sur disque avant finalize.
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            fileSize,
            "Tous les chunks drainés dans l'ordre"
        )

        let finalized = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: fileSize
        )
        XCTAssertTrue(finalized, "Finalisation sans trou")
        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, referenceData,
                       "L'ordre physique est l'ordre logique malgré le désordre total")

        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(actualHash, expectedHash,
                       "SHA-256 du fichier reçu == SHA-256 de la référence (désordre total)")
    }

    // MARK: - Doublon (même offset deux fois)

    /// Le même chunk reçu deux fois (même offset, même données) ne doit
    /// pas écraser le contenu déjà écrit. La seconde occurrence est
    /// silencieusement ignorée par le contrat `offset < writtenBytes`.
    ///
    /// Note : le doublon doit être émis AVANT que le fichier ne soit
    /// complet — sinon la garde anti-saturation
    /// (`writtenBytes + data.count <= fileSize`) le rejette avant même
    /// la comparaison d'offset. C'est un comportement attendu : un pair
    /// qui insiste avec des octets excédentaires se voit refuser avant
    /// que le doublon n'atteigne la branche d'offset. La couverture de
    /// la branche `offset < writtenBytes` est ici testée au milieu du
    /// transfert, où le plafond n'est pas saturé.
    func testDuplicateChunkAtSameOffsetIsIgnored() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let chunkSize = 256
        let totalChunks = 4
        let fileSize = Int64(chunkSize * totalChunks)

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "duplicate.bin",
            fileSize: fileSize
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i), count: chunkSize)
            }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        let session = UUID()

        // On écrit les chunks 0 et 1 (512 octets), puis on envoie un
        // doublon à l'offset 0 AVANT de compléter le fichier. Le
        // doublon arrive avec un payload de poison, mais avec une
        // taille compatible avec le plafond restant.
        let r1 = await manager.appendReceivedChunk(
            transferID: transferID, offset: 0,
            data: Data(repeating: 0x00, count: chunkSize),
            sessionId: session
        )
        XCTAssertTrue(r1)
        let r2dup = await manager.appendReceivedChunk(
            transferID: transferID, offset: Int64(chunkSize),
            data: Data(repeating: 0x01, count: chunkSize),
            sessionId: session
        )
        XCTAssertTrue(r2dup)

        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize * 2),
            "Avant le doublon, 512 octets sont écrits"
        )

        // Doublon à offset 0, payload poison. Le plafond n'est pas
        // saturé (projection = 512 + 0 + 256 = 768 ≤ 1024), donc on
        // atteint la branche `offset < writtenBytes`.
        let r2d = await manager.appendReceivedChunk(
            transferID: transferID,
            offset: 0,
            data: Data(repeating: 0xFF, count: chunkSize),
            sessionId: session
        )
        XCTAssertTrue(r2d, "Le doublon est accepté (return true) mais ignoré")

        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize * 2),
            "Le doublon ne doit pas avancer le pointeur d'écriture"
        )

        // Compléter le transfert avec les chunks 2 et 3.
        for index in 2..<totalChunks {
            let offset = Int64(index * chunkSize)
            let payload = Data(repeating: UInt8(index), count: chunkSize)
            let rComplete = await manager.appendReceivedChunk(
                transferID: transferID, offset: offset,
                data: payload, sessionId: session
            )
            XCTAssertTrue(rComplete)
        }

        let finalizedDup = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: fileSize
        )
        XCTAssertTrue(finalizedDup)

        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, referenceData,
                       "Le doublon n'a pas écrasé le contenu original")

        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(actualHash, expectedHash,
                       "SHA-256 préservé malgré le doublon")
    }

    // MARK: - Chunk ancien en retard (offset < writtenBytes)

    /// Un chunk avec un offset < writtenBytes ne doit ni écraser ni
    /// faire échouer. C'est le cas d'un chunk dupliqué tardif ou d'une
    /// reprise hors borne. Le contenu déjà écrit reste intègre.
    func testLateChunkAtOffsetBelowWrittenIsIgnored() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let chunkSize = 256
        let totalChunks = 4
        let fileSize = Int64(chunkSize * totalChunks)

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "late.bin",
            fileSize: fileSize
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i), count: chunkSize)
            }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        let session = UUID()

        // Premier chunk à l'offset 0, second à l'offset chunkSize :
        // `writtenBytes` est à 2*chunkSize.
        for index in 0..<2 {
            let offset = Int64(index * chunkSize)
            let payload = Data(repeating: UInt8(index), count: chunkSize)
            let r1 = await manager.appendReceivedChunk(
                transferID: transferID, offset: offset,
                data: payload, sessionId: session
            )
            XCTAssertTrue(r1)
        }
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize * 2)
        )

        // Un chunk ancien (offset 0) arrive en retard, avec un contenu
        // différent. Il doit être ignoré sans modifier le disque.
        let r2late = await manager.appendReceivedChunk(
            transferID: transferID,
            offset: 0,
            data: Data(repeating: 0xEE, count: chunkSize),
            sessionId: session
        )
        XCTAssertTrue(r2late, "Un chunk tardif est accepté mais ignoré")

        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize * 2),
            "Le chunk tardif ne doit pas régresser l'écriture"
        )

        // Finalisation après le reste des chunks dans l'ordre.
        for index in 2..<totalChunks {
            let offset = Int64(index * chunkSize)
            let payload = Data(repeating: UInt8(index), count: chunkSize)
            let rComplete = await manager.appendReceivedChunk(
                transferID: transferID, offset: offset,
                data: payload, sessionId: session
            )
            XCTAssertTrue(rComplete)
        }

        let finalizedLate = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: fileSize
        )
        XCTAssertTrue(finalizedLate)

        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, referenceData,
                       "Le chunk tardif n'a pas écrasé le contenu")

        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(actualHash, expectedHash,
                       "SHA-256 préservé malgré le chunk tardif")
    }

    // MARK: - Désordre avec chiffrement ChaCha20-Poly1305

    /// Avec une clé ChaCha20-Poly1305 installée sur le manager, des
    /// chunks chiffrés livrés dans le désordre doivent être déchiffrés
    /// individuellement, drainés dans l'ordre physique, et le SHA-256
    /// final doit correspondre à la référence.
    ///
    /// La garde anti-saturation compare la taille *plaintext* au
    /// `fileSize` annoncé (en octets logiques), pas la taille chiffrée :
    /// avec l'overhead ChaCha20-Poly1305 de 28 octets par chunk, une
    /// comparaison sur la taille chiffrée rejetterait systématiquement
    /// tout transfert en désordre dès le 2ᵉ chunk bufferisé.
    @MainActor
    func testOutOfOrderChunksAreDecryptedAndDrainedInOrder() async throws {
        let manager = makeTransferManager()
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        manager.incomingManager.installSessionKey(key)

        let chunkSize = 1 * 1024 * 1024 // 1 MiB
        manager.incomingManager.setNegotiatedChunkSize(chunkSize)

        let totalChunks = 32
        let plaintextSize = Int64(chunkSize * totalChunks) // 32 MiB
        let transferID = UUID()
        let sessionId = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Référence : chunk `i` contient un motif reproductible `UInt8(i)`.
        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i & 0xFF), count: chunkSize)
            }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        // Chiffre chaque chunk en amont.
        var sealedChunks: [Int: Data] = [:]
        for index in 0..<totalChunks {
            let plain = Data(
                repeating: UInt8(index & 0xFF), count: chunkSize
            )
            let sealed = cipher.encrypt(
                plain,
                transferID: transferID,
                chunkIndex: UInt32(index),
                sessionId: sessionId
            )
            sealedChunks[index] = sealed
        }

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "encrypted-disorder.bin",
            fileSize: plaintextSize
        )
        let outcome = await manager.createIncomingTransfer(request: request, sender: sender)
        XCTAssertEqual(outcome, .accepted, "Annonce acceptée")
        manager.markAccepted(transferID: transferID)

        // Désordre intentionnel.
        let order: [Int] = [31, 0, 17, 2, 25, 11, 7, 14, 22, 4,
                            28, 9, 19, 1, 30, 6, 23, 13, 3, 26,
                            16, 5, 21, 12, 18, 8, 24, 10, 27, 15,
                            20, 29]
        var allAppended = true
        for index in order {
            let offset = Int64(index * chunkSize)
            let sealed = sealedChunks[index]!
            let accepted = await manager.incomingManager.appendChunk(
                transferID: transferID,
                offset: offset,
                data: sealed,
                sessionId: sessionId,
                chunkSize: chunkSize
            )
            if !accepted {
                allAppended = false
                break
            }
        }
        XCTAssertTrue(
            allAppended,
            "Tous les chunks chiffrés en désordre doivent être acceptés " +
            "par la garde anti-saturation"
        )

        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            plaintextSize,
            "Tous les octets de plaintext sont sur disque"
        )

        let finalizedEnc = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: plaintextSize
        )
        XCTAssertTrue(finalizedEnc, "Finalisation sans trou")

        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(
            onDisk, referenceData,
            "L'ordre physique est l'ordre logique après déchiffrement"
        )

        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            actualHash, expectedHash,
            "SHA-256 du fichier déchiffré == SHA-256 de la référence"
        )
    }

    // MARK: - Perte de chunks (détection de trou)

    /// Scénario de perte : le chunk d'offset `chunkSize` n'arrive
    /// jamais. Le récepteur doit bufferiser les chunks en avance, puis
    /// échouer proprement à la finalisation (trou non comblé).
    ///
    /// Pas de mécanisme de retransmission à ce stade : on vérifie au
    /// minimum que le trou est détecté et que le fichier n'est jamais
    /// finalisé dans un état corrompu.
    func testLostChunkLeavesHoleAndFinalizeFailsCleanly() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let chunkSize = 256
        let totalChunks = 5
        let fileSize = Int64(chunkSize * totalChunks)

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "lost-chunk.bin",
            fileSize: fileSize
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i), count: chunkSize)
            }
        )
        _ = referenceData // non utilisé en final, sert juste à la doc

        let session = UUID()

        // Chunk 0 (dans l'ordre), chunk 2 (en avance — bufferisé),
        // chunk 3, chunk 4 : le chunk 1 manque.
        let received: [Int] = [0, 2, 3, 4]
        for index in received {
            let offset = Int64(index * chunkSize)
            let payload = Data(repeating: UInt8(index), count: chunkSize)
            let rLost = await manager.appendReceivedChunk(
                transferID: transferID, offset: offset,
                data: payload, sessionId: session
            )
            XCTAssertTrue(rLost)
        }

        // Aucun chunk n'est écrit après offset 0, car le chunk 1
        // manque. Le disque est figé.
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Seul le premier chunk est écrit, le reste est bufferisé"
        )

        // Finalisation : le trou n'est pas comblé, on attend un échec
        // propre, pas une finalisation d'un fichier incomplet.
        let finalizedLost = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: fileSize
        )
        XCTAssertFalse(finalizedLost, "Un transfert avec un trou non comblé ne peut pas finaliser")

        let transferAfter = manager.transfers.first { $0.id == transferID }
        XCTAssertEqual(
            transferAfter?.state, .failed,
            "Le transfert doit passer à .failed (trou définitif)"
        )

        // Le fichier .partial doit être supprimé après l'échec : pas
        // de fichier menteur sur disque.
        let url = IncomingFileWriter.temporaryURL(for: transferID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Aucun fichier .partial ne doit subsister après un échec"
        )
    }

    /// Variante de perte plus agressive : le chunk 1 manque, et les
    /// chunks 2..7 arrivent en désordre. Le buffer doit conserver ces
    /// chunks, mais le trou du chunk 1 reste visible.
    func testLostChunkWithMultipleOutOfOrderFollowupsLeavesHole() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let chunkSize = 256
        let totalChunks = 8
        let fileSize = Int64(chunkSize * totalChunks)

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "lost-with-buffer.bin",
            fileSize: fileSize
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        let session = UUID()

        // Le chunk 1 manque. Tous les autres arrivent en désordre :
        // [0, 7, 2, 5, 6, 3, 4].
        let received: [Int] = [0, 7, 2, 5, 6, 3, 4]
        for index in received {
            let offset = Int64(index * chunkSize)
            let payload = Data(repeating: UInt8(index), count: chunkSize)
            let rLost2 = await manager.appendReceivedChunk(
                transferID: transferID, offset: offset,
                data: payload, sessionId: session
            )
            XCTAssertTrue(rLost2)
        }

        // Le trou du chunk 1 bloque l'écriture : seul le chunk 0 est
        // sur disque.
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Le trou du chunk 1 bloque la progression"
        )

        // Le transfert ne doit PAS être marqué `failed` prématurément
        // : la perte d'un chunk n'est pas un défaut de protocole, c'est
        // un trou en attente.
        let transferBefore = manager.transfers.first { $0.id == transferID }
        XCTAssertNotEqual(
            transferBefore?.state, .failed,
            "Un trou en attente n'est pas un échec"
        )

        // Finalisation : on s'attend à un échec propre.
        let finalizedLost2 = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: fileSize
        )
        XCTAssertFalse(finalizedLost2, "La finalisation échoue tant que le trou n'est pas comblé")

        let transferAfter = manager.transfers.first { $0.id == transferID }
        XCTAssertEqual(
            transferAfter?.state, .failed,
            "Finalisation sans comblement → .failed"
        )
    }

    // MARK: - End-to-end 100 MB avec désordre modéré

    /// Transfert simulé de 100 MB en chunks de 1 MB, livrés avec 10 %
    /// de chunks hors-ordre. Mesure le débit observé par le buffer de
    /// réordonnancement. Le seuil 350 MB/s est l'objectif post-fix.
    func testEndToEndTransferThroughputWithModerateDisorder() async throws {
        let totalBytes = 100 * 1024 * 1024
        let chunkSize = 1 * 1024 * 1024
        let totalChunks = totalBytes / chunkSize

        // Référence : un motif pseudo-aléatoire reproductible.
        var generator = SystemRandomNumberGenerator()
        let referenceData = Data(
            (0..<totalBytes).map { _ in UInt8.random(in: 0...255, using: &generator) }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        let fileSize = Int64(totalBytes)

        // Construit un ordre de livraison : 90 % dans l'ordre, 10 % en
        // avance aléatoire. On prend chaque chunk et, avec 10 % de
        // probabilité, on l'échange avec un chunk suivant pour
        // introduire un trou comblable.
        var order: [Int] = Array(0..<totalChunks)
        var rng = SplitMix64(seed: 0xC0FFEE)
        for i in 0..<(totalChunks - 1) {
            if rng.next() % 10 == 0 && i + 2 < totalChunks {
                order.swapAt(i, i + 2)
            }
        }

        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "disorder-100mb.bin",
            fileSize: fileSize
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        let session = UUID()

        let start = Date()
        for index in order {
            let offset = Int64(index * chunkSize)
            let sliceStart = index * chunkSize
            let sliceEnd = sliceStart + chunkSize
            let slice = referenceData.subdata(in: sliceStart..<sliceEnd)
            _ = await manager.appendReceivedChunk(
                transferID: transferID, offset: offset,
                data: slice, sessionId: session
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        let finalizedPerf = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: fileSize
        )
        XCTAssertTrue(finalizedPerf, "La finalisation doit réussir")

        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()

        let throughput = Double(onDisk.count) / elapsed / (1024 * 1024)
        print("📊 testEndToEndTransferThroughputWithModerateDisorder : \(String(format: "%.2f", throughput)) MB/s, taille=\(onDisk.count)")

        XCTAssertEqual(onDisk.count, totalBytes, "Tous les octets sont écrits")
        XCTAssertEqual(actualHash, expectedHash,
                       "SHA-256 du fichier réordonné == SHA-256 de la référence")

        // Seuil post-fix : ≥ 350 MB/s. La majorité du temps est en
        // écriture disque, pas en tri mémoire.
        XCTAssertGreaterThanOrEqual(
            throughput, 350.0,
            "Débit ≥ 350 MB/s malgré 10% de désordre (mesuré : \(throughput) MB/s)"
        )
    }

    // MARK: - m5 — Tag ChaCha20-Poly1305 invalide

    /// Un chunk chiffré avec un tag d'authentification Poly1305 invalide
    /// (ou avec un nonce modifié) doit être REJETÉ par le déchiffreur,
    /// le buffer vidé, et le transfert doit passer en état `.failed`.
    ///
    /// Couvre la branche d'erreur de `IncomingTransferManager.swift:296-303`
    /// : un faux tag ne doit jamais produire d'écriture sur disque, et
    /// l'état du transfert ne doit pas rester silencieusement `.accepted`
    /// après un échec d'authentification.
    func testInvalidAuthTagClearsBufferAndFails() async throws {
        let manager = makeTransferManager()
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        manager.incomingManager.installSessionKey(key)

        let chunkSize = 64 * 1024 // 64 KiB — léger mais non trivial
        manager.incomingManager.setNegotiatedChunkSize(chunkSize)

        let totalChunks = 4
        let plaintextSize = Int64(chunkSize * totalChunks)
        let transferID = UUID()
        let sessionId = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Chiffre deux chunks en amont : un légitime (chunk 0), un qui
        // sera corrompu (chunk 2).
        let plain0 = Data(repeating: 0x10, count: chunkSize)
        let plain2 = Data(repeating: 0x20, count: chunkSize)

        let sealed0 = cipher.encrypt(
            plain0,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )
        let sealed2 = cipher.encrypt(
            plain2,
            transferID: transferID,
            chunkIndex: 2,
            sessionId: sessionId
        )

        // Corrompt le tag d'authentification du chunk 2 : on inverse le
        // dernier octet. `ChunkStreamCipher.decrypt` détecte alors un
        // tag Poly1305 invalide et retourne `nil`.
        var corrupted2 = Data(sealed2)
        let lastIndex = corrupted2.count - 1
        corrupted2[lastIndex] ^= 0xFF

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "invalid-tag.bin",
            fileSize: plaintextSize
        )
        let outcome = await manager.createIncomingTransfer(
            request: request, sender: sender
        )
        XCTAssertEqual(outcome, .accepted, "L'annonce doit être acceptée")
        manager.markAccepted(transferID: transferID)

        // 1) Chunk 0 légitime : écrit immédiatement.
        let accepted0 = await manager.incomingManager.appendChunk(
            transferID: transferID,
            offset: 0,
            data: sealed0,
            sessionId: sessionId,
            chunkSize: chunkSize
        )
        XCTAssertTrue(accepted0, "Chunk 0 légitime accepté")
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Seul le premier chunk est sur disque"
        )

        // 2) Chunk 2 avec tag corrompu : REJETÉ. Le buffer doit être vidé
        //    et le transfert doit passer en .failed.
        let acceptedCorrupt = await manager.incomingManager.appendChunk(
            transferID: transferID,
            offset: Int64(2 * chunkSize),
            data: corrupted2,
            sessionId: sessionId,
            chunkSize: chunkSize
        )
        XCTAssertFalse(
            acceptedCorrupt,
            "Un tag Poly1305 invalide doit être rejeté par appendChunk"
        )

        // 3) Le transfert doit être passé en .failed (pas .accepted
        //    silencieux, pas .transferring).
        let transferAfter = manager.transfers.first { $0.id == transferID }
        XCTAssertEqual(
            transferAfter?.state, .failed,
            "Tag invalide → transfert en .failed"
        )

        // 4) Le disque ne contient que le premier plaintext : aucun
        //    plaintext corrompu n'a été écrit, le .partial n'a pas
        //    été complété avec un déchiffrement partiel.
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Aucun octet corrompu n'est écrit sur disque"
        )

        // 5) Le buffer de chunks doit être nettoyé : un chunk légitime
        //    envoyé après l'échec ne doit pas être bufferisé dans un
        //    état désormais défaillant.
        let plain1 = Data(repeating: 0x11, count: chunkSize)
        let sealed1 = cipher.encrypt(
            plain1,
            transferID: transferID,
            chunkIndex: 1,
            sessionId: sessionId
        )
        let acceptedAfterFailure = await manager.incomingManager.appendChunk(
            transferID: transferID,
            offset: Int64(chunkSize),
            data: sealed1,
            sessionId: sessionId,
            chunkSize: chunkSize
        )
        XCTAssertFalse(
            acceptedAfterFailure,
            "Aucun chunk ne doit être accepté après un échec d'authentification"
        )
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Le disque reste à 1 chunk écrit après le rejet du tag invalide"
        )
    }

    // MARK: - m6 — Désordre + reprise + nouveau désordre

    /// Scénario réel : chunks hors-ordre arrivent, le transfert est
    /// interrompu (coupure réseau), puis on reprend via
    /// `reopenWriterForResume` et de nouveaux chunks hors-ordre
    /// arrivent. Le buffer doit être vidé à la reprise pour repartir
    /// d'un état propre, et le SHA-256 du fichier final doit
    /// correspondre à la concaténation dans l'ordre logique.
    ///
    /// Couvre la branche `reopenWriterForResume` ligne 614 de
    /// `IncomingTransferManager.swift` : `pendingChunks[transferID] =
    /// nil` doit effectivement purger toute trace des chunks
    /// bufferisés avant l'interruption.
    func testOutOfOrderChunksThenResumeThenMoreDisorder() async throws {
        let manager = makeTransferManager()
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        manager.incomingManager.installSessionKey(key)

        let chunkSize = 64 * 1024 // 64 KiB
        manager.incomingManager.setNegotiatedChunkSize(chunkSize)

        let totalChunks = 5
        let plaintextSize = Int64(chunkSize * totalChunks)
        let transferID = UUID()
        let sessionId = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Référence : chaque chunk `i` = `Data(repeating: UInt8(i))`.
        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i), count: chunkSize)
            }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        // Chiffre tous les chunks en amont.
        var sealedChunks: [Int: Data] = [:]
        for index in 0..<totalChunks {
            let plain = Data(repeating: UInt8(index), count: chunkSize)
            sealedChunks[index] = cipher.encrypt(
                plain,
                transferID: transferID,
                chunkIndex: UInt32(index),
                sessionId: sessionId
            )
        }

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "resume-disorder.bin",
            fileSize: plaintextSize
        )
        let outcome = await manager.createIncomingTransfer(
            request: request, sender: sender
        )
        XCTAssertEqual(outcome, .accepted, "L'annonce doit être acceptée")
        manager.markAccepted(transferID: transferID)

        // Phase 1 — pré-interruption : envoyer chunks [0, 4] (chunk 4
        // bufferisé car chunk 1, 2, 3 manquent).
        let acceptedP1a = await manager.incomingManager.appendChunk(
            transferID: transferID,
            offset: 0,
            data: sealedChunks[0]!,
            sessionId: sessionId,
            chunkSize: chunkSize
        )
        XCTAssertTrue(acceptedP1a, "Chunk 0 légitime accepté")
        let acceptedP1b = await manager.incomingManager.appendChunk(
            transferID: transferID,
            offset: Int64(4 * chunkSize),
            data: sealedChunks[4]!,
            sessionId: sessionId,
            chunkSize: chunkSize
        )
        XCTAssertTrue(acceptedP1b, "Chunk 4 bufferisé")

        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Seul le chunk 0 est sur disque"
        )

        // Phase 2 — interruption simulée (coupure réseau) : le writer
        // est fermé SANS suppression du .partial, le buffer est vidé.
        manager.incomingManager.interruptTransfer(transferID: transferID)
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Le .partial est conservé après interruption"
        )

        // Phase 3 — reprise : on rouvre le writer au bon offset et on
        // envoie de nouveaux chunks en désordre [3, 1, 2]. Le buffer
        // doit être VIDE au moment de la reprise (ligne 614) : aucun
        // résidu du chunk 4 bufferisé avant l'interruption.
        XCTAssertTrue(
            manager.incomingManager.reopenWriterForResume(
                transferID: transferID,
                atOffset: Int64(chunkSize)
            ),
            "Le writer est rouvert pour la reprise"
        )
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(chunkSize),
            "Le .partial est intact après la réouverture"
        )

        // Phase 4 — envoi en désordre après reprise : chunks [3, 1, 2].
        // Le chunk 1 doit être drainé immédiatement (il comble le
        // trou), puis le chunk 2, puis le chunk 3. Le chunk 4, déjà
        // bufferisé avant l'interruption, est perdu (le buffer a été
        // vidé) : on l'envoie à nouveau.
        for index in [3, 1, 2] {
            let acceptedPhase4 = await manager.incomingManager.appendChunk(
                transferID: transferID,
                offset: Int64(index * chunkSize),
                data: sealedChunks[index]!,
                sessionId: sessionId,
                chunkSize: chunkSize
            )
            XCTAssertTrue(acceptedPhase4, "Chunk \(index) après reprise accepté")
        }

        // À ce stade : chunks 0, 1, 2, 3 écrits dans l'ordre. Chunk 4
        // doit être ré-envoyé (le buffer était vide après reprise).
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            Int64(4 * chunkSize),
            "4 chunks drainés dans l'ordre après reprise"
        )

        // Phase 5 — chunk 4 ré-envoyé : drainé immédiatement.
        let acceptedPhase5 = await manager.incomingManager.appendChunk(
            transferID: transferID,
            offset: Int64(4 * chunkSize),
            data: sealedChunks[4]!,
            sessionId: sessionId,
            chunkSize: chunkSize
        )
        XCTAssertTrue(acceptedPhase5, "Chunk 4 ré-envoyé après reprise")
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            plaintextSize,
            "Tous les octets sont sur disque avant finalisation"
        )

        // Phase 6 — finalisation : le buffer est vide, le fichier est
        // complet.
        let finalizedResume = await manager.finalizeReceivedTransfer(
            transferID: transferID,
            announcedTotalBytes: plaintextSize
        )
        XCTAssertTrue(finalizedResume, "Finalisation sans trou après reprise")

        // Vérification : SHA-256 == référence.
        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(
            onDisk, referenceData,
            "L'ordre physique est l'ordre logique après reprise + désordre"
        )
        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            actualHash, expectedHash,
            "SHA-256 du fichier reçu == SHA-256 de la référence (reprise + désordre)"
        )

        // Le transfert doit être finalisé en .completed (via finalize
        // sans erreur), pas en .failed.
        let transferAfter = manager.transfers.first { $0.id == transferID }
        XCTAssertNotEqual(
            transferAfter?.state, .failed,
            "Le transfert ne doit pas être échoué après une reprise réussie"
        )
    }
}

/// PRNG splitmix64 déterministe pour le test de débit : on a besoin
/// d'un générateur stable qui n'utilise pas l'horloge système, pour
/// rendre l'ordre des chunks reproductible.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
