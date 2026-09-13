//
//  ChunkIndexConsistencyTests.swift
//  AirBridge
//
//  Test de non-régression pour le bug "iPhone rejette les chunks ChaCha20
//  -Poly1305 avec authentification invalide".
//
//  Symptôme : le récepteur ne connaissait pas la taille de chunk négociée
//  par l'émetteur. Sans `setNegotiatedChunkSize`, le `ChunkSink` retombait
//  sur `offset >> 32` pour dériver le `chunkIndex` de l'AAD — soit 0 pour
//  tout fichier de moins de 4 Gio. L'émetteur chiffre avec
//  `chunkIndex = 0, 1, 2, ...` : seul le premier chunk était authentifié,
//  tous les suivants étaient rejetés par Poly1305 (`decryptionFailed`).
//
//  Le fix : `IncomingTransferManager.createTransfer` appelle désormais
//  `self.setNegotiatedChunkSize(TransferChunkSizing.chunkSize(forFileSize:))`
//  après `sink.prepareWriter`. La régression testée ici traverse le chemin
//  PUBLIC : `createIncomingTransfer` (sans appeler manuellement
//  `setNegotiatedChunkSize`) puis `appendReceivedChunk` (sans paramètre
//  `chunkSize`). Si la production ne configure plus la taille, tous les
//  chunks sauf le premier échouent.
//

import XCTest
import CryptoKit
@testable import AirBridge

@MainActor
final class ChunkIndexConsistencyTests: XCTestCase {

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

    // MARK: - Régression : chunkIndex cohérent côté récepteur

    /// Reproduit le bug rapporté par le terrain : l'iPhone rejette tous
    /// les chunks chiffrés sauf le premier car `negotiatedChunkSize == 0`
    /// fait dériver le `chunkIndex` de l'AAD à 0 pour tous les offsets.
    ///
    /// Ce test NE DOIT PAS appeler `setNegotiatedChunkSize` manuellement :
    /// c'est précisément ce masquage qui a laissé passer le bug jusqu'ici
    /// (uniquement testé par les tests unitaires qui pré-peuplaient
    /// l'état interne). Le chemin exercé est la voie publique :
    /// `createIncomingTransfer` puis `appendReceivedChunk`, exactement
    /// comme un pair distant les appellerait.
    ///
    /// Avant le fix : les chunks 1..7 sont rejetés avec
    /// `decryptionFailed`, le transfert passe en `.failed`, le SHA-256 du
    /// fichier reçu ne correspond pas à l'original.
    ///
    /// Après le fix : `createTransfer` appelle en interne
    /// `TransferChunkSizing.chunkSize(forFileSize:)`, le `ChunkSink` dérive
    /// un `chunkIndex` cohérent avec l'émetteur, tous les chunks
    /// déchiffrent, le SHA-256 correspond.
    func testProductionPathNegotiatesChunkSizeForChaChaPolyDecryption() async throws {
        let manager = makeTransferManager()
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        manager.incomingManager.installSessionKey(key)

        // Taille de fichier qui déclenche un chunkSize non-trivial depuis
        // `TransferChunkSizing` (≥ 1 Mio → medium chunk size 256 Kio).
        // On prend 2 Mio = 8 × 256 Kio pile, pour avoir 8 chunks entiers
        // sans chunk final raccourci. Aucun appel manuel à
        // `setNegotiatedChunkSize` ici : c'est précisément ce que le bug
        // exploitait.
        let fileSize: Int64 = 2 * 1024 * 1024 // 2 Mio → medium bucket
        let negotiatedChunkSize = TransferChunkSizing.chunkSize(
            forFileSize: fileSize
        )
        XCTAssertGreaterThan(
            negotiatedChunkSize, 0,
            "Le chunkSize dérivé doit être strictement positif"
        )

        // On force un bucket connu (medium) en choisissant une taille ≥ 1 Mio.
        // Le chunkSize medium est 256 Kio, donc on prend
        // `fileSize = 8 * 256 Kio = 2 Mio` pour avoir exactement 8 chunks
        // entiers, sans chunk final raccourci. C'est la situation
        // nominale côté production.
        let totalChunks = 8
        let plaintextSize = Int64(totalChunks) * Int64(negotiatedChunkSize)
        XCTAssertEqual(
            plaintextSize, fileSize,
            "La somme des chunks couvre exactement la taille annoncée"
        )

        let transferID = UUID()
        let sessionId = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Référence : chaque chunk `i` contient `UInt8(i)` répété.
        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i & 0xFF), count: negotiatedChunkSize)
            }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        // Chiffre chaque chunk comme l'émetteur le ferait : avec
        // `chunkIndex = UInt32(i)` dérivé de la position du chunk.
        var sealedChunks: [Int: Data] = [:]
        for index in 0..<totalChunks {
            let plain = Data(
                repeating: UInt8(index & 0xFF),
                count: negotiatedChunkSize
            )
            let sealed = cipher.encrypt(
                plain,
                transferID: transferID,
                chunkIndex: UInt32(index),
                sessionId: sessionId
            )
            sealedChunks[index] = sealed
        }

        // Voie publique : createIncomingTransfer configure
        // automatiquement `negotiatedChunkSize` via
        // `TransferChunkSizing.chunkSize(forFileSize:)`. AUCUN appel
        // manuel à `setNegotiatedChunkSize`.
        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "chunk-index-consistency.bin",
            fileSize: plaintextSize
        )
        let outcome = await manager.createIncomingTransfer(
            request: request, sender: sender
        )
        XCTAssertEqual(outcome, .accepted, "L'annonce doit être acceptée")
        manager.markAccepted(transferID: transferID)

        // Voie publique : appendReceivedChunk sans paramètre `chunkSize`.
        // Le manager doit déduire la taille négociée et dériver
        // correctement `chunkIndex = offset / chunkSize`.
        var allAppended = true
        for index in 0..<totalChunks {
            let offset = Int64(index * negotiatedChunkSize)
            let sealed = sealedChunks[index]!
            let accepted = await manager.appendReceivedChunk(
                transferID: transferID,
                offset: offset,
                data: sealed,
                sessionId: sessionId
            )
            if !accepted {
                allAppended = false
                break
            }
        }

        // Avant le fix : au moins les chunks 1..7 étaient rejetés avec
        // `decryptionFailed` car `negotiatedChunkSize == 0` côté récepteur
        // → `chunkIndex = offset >> 32 = 0` pour tous les chunks
        // → AAD ChaCha20-Poly1305 diverge de celui de l'émetteur.
        XCTAssertTrue(
            allAppended,
            "Tous les chunks chiffrés doivent être acceptés : " +
            "le récepteur doit dériver le même chunkIndex que l'émetteur"
        )

        // Le transfert ne doit PAS être passé en `.failed` : un échec
        // d'auth ChaCha20-Poly1305 aurait fait passer le store à
        // `.failed` (cf. `applyResult(.decryptionFailed)`).
        let transferAfterAppends = manager.transfers
            .first { $0.id == transferID }
        XCTAssertNotEqual(
            transferAfterAppends?.state, .failed,
            "Aucun chunk ne doit être rejeté pour auth ChaCha20 invalide"
        )

        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            plaintextSize,
            "Tous les octets de plaintext sont sur disque"
        )

        let finalized = await manager.finalizeReceivedTransfer(
            transferID: transferID,
            announcedTotalBytes: plaintextSize
        )
        XCTAssertTrue(finalized, "Finalisation sans trou")

        // Vérification finale : le SHA-256 du fichier reçu doit
        // correspondre à la concaténation des patterns dans l'ordre
        // logique. Avant le fix, seuls les premiers octets
        // (chunk 0) étaient écrits correctement, le reste étant soit vide
        // soit issu d'un déchiffrement silencieusement corrompu.
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

    /// Variante : le fichier est petit (512 Kio) — il reste dans le
    /// bucket small (64 Kio). Avant le fix, ce bucket causait le même
    /// symptôme (`offset >> 32 == 0` pour tous les offsets), le bug
    /// n'était pas spécifique aux fichiers ≥ 1 Mio.
    func testProductionPathNegotiatesChunkSizeForSmallFiles() async throws {
        let manager = makeTransferManager()
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        manager.incomingManager.installSessionKey(key)

        // 512 Kio → bucket small (chunkSize = 64 Kio).
        let fileSize: Int64 = 512 * 1024
        let negotiatedChunkSize = TransferChunkSizing.chunkSize(
            forFileSize: fileSize
        )
        XCTAssertGreaterThan(negotiatedChunkSize, 0)
        XCTAssertLessThan(
            negotiatedChunkSize, Int(Int64.max),
            "Le chunkSize reste dans Int"
        )

        let totalChunks = Int(fileSize / Int64(negotiatedChunkSize))
        let plaintextSize = fileSize
        let transferID = UUID()
        let sessionId = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let referenceData = Data(
            (0..<totalChunks).flatMap { i in
                Array(repeating: UInt8(i & 0xFF), count: negotiatedChunkSize)
            }
        )
        let expectedHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }
            .joined()

        var sealedChunks: [Int: Data] = [:]
        for index in 0..<totalChunks {
            let plain = Data(
                repeating: UInt8(index & 0xFF),
                count: negotiatedChunkSize
            )
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
            fileName: "small-encrypted.bin",
            fileSize: plaintextSize
        )
        let outcome = await manager.createIncomingTransfer(
            request: request, sender: sender
        )
        XCTAssertEqual(outcome, .accepted)
        manager.markAccepted(transferID: transferID)

        for index in 0..<totalChunks {
            let offset = Int64(index * negotiatedChunkSize)
            let accepted = await manager.appendReceivedChunk(
                transferID: transferID,
                offset: offset,
                data: sealedChunks[index]!,
                sessionId: sessionId
            )
            XCTAssertTrue(
                accepted,
                "Chunk \(index) rejeté — chunkIndex incohérent côté récepteur"
            )
        }

        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: transferID),
            plaintextSize
        )

        let finalized = await manager.finalizeReceivedTransfer(
            transferID: transferID,
            announcedTotalBytes: plaintextSize
        )
        XCTAssertTrue(finalized)

        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        let actualHash = SHA256.hash(data: onDisk)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            actualHash, expectedHash,
            "SHA-256 du fichier reçu == SHA-256 de la référence (small bucket)"
        )
    }
}
