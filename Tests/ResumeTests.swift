//
//  ResumeTests.swift
//  AirBridge
//

import XCTest
import Network
import CryptoKit
@testable import AirBridge

@MainActor
final class ResumeTests: XCTestCase {

    // MARK: - Fabriques

    private func makePeer() -> Device {
        Device(
            id: UUID(),
            name: "Pair de test",
            model: "iPhone",
            systemVersion: "26.5"
        )
    }

    private func makeTransfer(
        id: UUID = UUID(),
        fileSize: Int64,
        transferredBytes: Int64,
        direction: Transfer.Direction = .incoming,
        state: Transfer.State = .transferring
    ) -> Transfer {
        Transfer(
            id: id,
            peer: makePeer(),
            fileName: "fichier-test.bin",
            fileSize: fileSize,
            direction: direction,
            state: state,
            transferredBytes: transferredBytes
        )
    }

    private func makeTransferManager() -> TransferManager {
        TransferManager(
            receivedFolderStore: ReceivedFolderStore(),
            localDevice: makePeer(),
            historyStore: TransferHistoryStore()
        )
    }

    private func makeConnectionManager(
        transferManager: TransferManager
    ) -> ConnectionManager {
        let manager = ConnectionManager(
            localDevice: makePeer(),
            messageRouter: MessageRouter(),
            pairingStore: PairingStore()
        )
        _ = transferManager
        return manager
    }

    private var partialDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AirBridgeIncoming", isDirectory: true)
    }

    /// Supprime les artefacts disque d'un transfert, sans jamais lever :
    /// un fichier déjà absent n'est pas une erreur de test.
    private func cleanupPartialFiles(for transferID: UUID) {
        let url = IncomingFileWriter.temporaryURL(for: transferID)
        try? FileManager.default.removeItem(at: url)
        let metadataURL = ResumePersistence.fileURL(for: transferID)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    /// Installe une clé de session ChaCha20-Poly1305 et renvoie le
    /// chiffreur correspondant. Le chiffrement est obligatoire pour un
    /// transfert entrant (v2) : sans clé, tout chunk est rejeté en
    /// `.decryptionFailed` avant la moindre écriture.
    @discardableResult
    private func installEncryption(
        on manager: TransferManager,
        chunkSize: Int
    ) -> ChunkStreamCipher {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        manager.incomingManager.installSessionKey(key)
        manager.incomingManager.setNegotiatedChunkSize(chunkSize)
        return cipher
    }

    /// Chiffre un chunk puis l'injecte par le chemin réel
    /// (`incomingManager.appendChunk`), avec le `chunkIndex` dérivé côté
    /// récepteur (`offset / chunkSize`).
    private func appendEncrypted(
        _ plaintext: Data,
        transferID: UUID,
        offset: Int64,
        chunkSize: Int,
        sessionId: UUID,
        using cipher: ChunkStreamCipher,
        on manager: TransferManager
    ) async -> Bool {
        let chunkIndex = chunkSize > 0
            ? UInt32(offset / Int64(chunkSize))
            : UInt32(offset >> 32)
        let sealed = cipher.encrypt(
            plaintext,
            transferID: transferID,
            chunkIndex: chunkIndex,
            sessionId: sessionId
        )
        return await manager.incomingManager.appendChunk(
            transferID: transferID,
            offset: offset,
            data: sealed,
            sessionId: sessionId,
            chunkSize: chunkSize
        )
    }

    // MARK: - Interruption et resumabilité

    func testInterruptionAt50PercentIsResumable() throws {
        let store = TransferStore()
        let id = UUID()
        store.append(makeTransfer(id: id, fileSize: 100, transferredBytes: 50))

        store.updateProgress(transferID: id, transferredBytes: 50)
        store.markInterrupted(transferID: id, transferredBytes: 50)

        XCTAssertEqual(store.transfer(withID: id)?.state, .interrupted)
        XCTAssertTrue(store.isResumable(transferID: id))
    }

    func testInterruptionBeforeFirstChunkKeepsProgressVisible() throws {
        let store = TransferStore()
        let id = UUID()
        store.append(makeTransfer(id: id, fileSize: 100, transferredBytes: 0))

        store.markInterrupted(transferID: id, transferredBytes: 0)

        XCTAssertEqual(store.transfer(withID: id)?.transferredBytes, 0)
        XCTAssertNil(store.transfer(withID: id)?.completedAt,
                     ".interrupted est non terminal : pas de date de fin")
        XCTAssertFalse(store.transfer(withID: id)!.state.isTerminal)
        XCTAssertTrue(store.isResumable(transferID: id))
    }

    func testInterruptionAlmostCompleteIsResumable() throws {
        let store = TransferStore()
        let id = UUID()
        store.append(makeTransfer(id: id, fileSize: 100, transferredBytes: 95))

        store.markInterrupted(transferID: id, transferredBytes: 95)

        XCTAssertTrue(store.isResumable(transferID: id))
        XCTAssertEqual(store.transfer(withID: id)?.transferredBytes, 95)
    }

    func testInterruptionPreservesUIProgression() throws {
        // La progression affichée ne doit pas repartir à zéro après une
        // interruption : markInterrupted conserve le compteur d'octets.
        let store = TransferStore()
        let id = UUID()
        store.append(makeTransfer(id: id, fileSize: 1_000, transferredBytes: 0))
        store.markAccepted(transferID: id)
        store.updateProgress(transferID: id, transferredBytes: 400)
        store.updateProgress(transferID: id, transferredBytes: 700)

        store.markInterrupted(transferID: id, transferredBytes: 700)

        XCTAssertEqual(store.transfer(withID: id)?.transferredBytes, 700,
                       "La progression doit être conservée pour la reprise")
        XCTAssertEqual(store.transfer(withID: id)?.progress ?? 0, 0.7,
                       accuracy: 0.0001)
    }

    func testInterruptionClampsNegativeAndOversizedByteCounts() throws {
        let store = TransferStore()
        let id = UUID()
        store.append(makeTransfer(id: id, fileSize: 100, transferredBytes: 10))

        store.markInterrupted(transferID: id, transferredBytes: -5)
        XCTAssertEqual(store.transfer(withID: id)?.transferredBytes, 0)

        store.markInterrupted(transferID: id, transferredBytes: 500)
        XCTAssertEqual(store.transfer(withID: id)?.transferredBytes, 100)
    }

    // MARK: - Annulation pendant interruption

    func testCancelWhileInterruptedMakesTransferNonResumable() throws {
        let store = TransferStore()
        let id = UUID()
        let transfer = makeTransfer(
            id: id,
            fileSize: 100,
            transferredBytes: 50,
            state: .interrupted
        )
        store.append(transfer)

        store.markCancelled(transferID: id)

        XCTAssertEqual(store.transfer(withID: id)?.state, .cancelled)
        XCTAssertFalse(store.isResumable(transferID: id),
                       "Un transfert annulé ne doit plus être reprisable")
        XCTAssertTrue(store.isTerminal(transferID: id))
        XCTAssertNotNil(store.transfer(withID: id)?.completedAt)
    }

    func testCancelActiveTransfersPreservesInterruptedTransfers() throws {
        let store = TransferStore()
        let active = makeTransfer(fileSize: 100, transferredBytes: 20)
        let interrupted = makeTransfer(
            fileSize: 100,
            transferredBytes: 60,
            state: .interrupted
        )
        store.append(active)
        store.append(interrupted)

        store.cancelActiveTransfers()

        XCTAssertEqual(store.transfer(withID: active.id)?.state, .cancelled,
                       "Le transfert actif doit être annulé par la déconnexion")
        XCTAssertEqual(store.transfer(withID: interrupted.id)?.state, .interrupted,
                       "Un transfert interrompu doit rester reprisable après déconnexion")
        XCTAssertTrue(store.isResumable(transferID: interrupted.id))
    }

    // MARK: - Persistance des métadonnées de reprise

    func testResumePersistenceRoundTrip() async throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let persistence = ResumePersistence.makePersistence(transferID: transferID)
        let info = ResumeTransferInfo(
            transferID: transferID,
            fileSize: 1_000,
            transferredBytes: 500,
            fileName: "fichier-test.bin",
            direction: "incoming",
            peerID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            partialFileURL: IncomingFileWriter.temporaryURL(for: transferID)
        )

        try await persistence.save(info)

        let loaded = try await persistence.load()
        XCTAssertEqual(loaded?.transferID, info.transferID)
        XCTAssertEqual(loaded?.fileSize, info.fileSize)
        XCTAssertEqual(loaded?.transferredBytes, info.transferredBytes)
        XCTAssertEqual(loaded?.fileName, info.fileName)
        XCTAssertEqual(loaded?.direction, info.direction)
        XCTAssertEqual(loaded?.peerID, info.peerID)
        XCTAssertEqual(loaded?.partialFileURL, info.partialFileURL)
        XCTAssertEqual(
            loaded?.timestamp.timeIntervalSince1970 ?? 0,
            info.timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )

        try await persistence.clear()

        let afterClear = try await persistence.load()
        XCTAssertNil(afterClear,
                     "Après clear(), aucune métadonnée ne doit subsister")
    }

    func testResumePersistenceLoadWithoutFileReturnsNil() async throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let persistence = ResumePersistence.makePersistence(transferID: transferID)
        let loaded = try await persistence.load()
        XCTAssertNil(loaded)
    }

    func testReconciledTransferredBytesNeverExceedsMetadata() {
        // La taille disque fait foi à la baisse, jamais à la hausse.
        XCTAssertEqual(
            ResumeTransferInfo.reconciledTransferredBytes(
                metadataBytes: 500,
                onDiskBytes: 300
            ),
            300,
            "Le disque plus court que les métadonnées fait foi (troncature)"
        )
        XCTAssertEqual(
            ResumeTransferInfo.reconciledTransferredBytes(
                metadataBytes: 500,
                onDiskBytes: 900
            ),
            500,
            "Des octets au-delà des métadonnées sont invérifiables : bornés"
        )
        XCTAssertEqual(
            ResumeTransferInfo.reconciledTransferredBytes(
                metadataBytes: 500,
                onDiskBytes: -10
            ),
            0,
            "Une taille négative est ramenée à zéro"
        )
        XCTAssertEqual(
            ResumeTransferInfo.reconciledTransferredBytes(
                metadataBytes: -5,
                onDiskBytes: 100
            ),
            0
        )
    }

    // MARK: - Double reprise bloquée

    func testSecondResumeRejectedOnceStateLeftInterrupted() throws {
        // handleResumeAccepted exige l'état .interrupted ; après la première
        // reprise l'état devient .accepted, donc une seconde demande est
        // refusée : une seule tâche peut être relancée.
        let manager = makeTransferManager()
        let id = UUID()

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-tests-\(id.uuidString).bin")
        try Data(count: 100).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        manager.createOutgoingTransfer(
            id: id,
            peer: makePeer(),
            fileName: "fichier-test.bin",
            fileSize: 100,
            state: .interrupted
        )
        manager.registerOutgoingSource(transferID: id, fileURL: sourceURL)
        defer { manager.cleanupOutgoingTransfer(transferID: id) }

        let firstAccepted = manager.handleResumeAccepted(
            transferID: id,
            offset: 40
        )
        XCTAssertTrue(firstAccepted, "La première reprise doit être acceptée")

        let secondAccepted = manager.handleResumeAccepted(
            transferID: id,
            offset: 40
        )
        XCTAssertFalse(secondAccepted,
                       "Une double reprise doit être refusée : le transfert n'est plus interrompu")
    }

    // MARK: - Reprise entrante

    func testIncomingResumeRequiresPartialOnDisk() async throws {
        let manager = makeTransferManager()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { connection.cancel() }
        let connectionManager = makeConnectionManager(transferManager: manager)
        let id = UUID()
        defer { cleanupPartialFiles(for: id) }

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: id,
            fileName: "fichier-test.bin",
            fileSize: 100
        )

        // Création entrante standard : le transfert existe dans le store
        // avec un writer, mais rien n'a encore été écrit sur disque.
        let outcome = await manager.createIncomingTransfer(
            request: request,
            sender: sender
        )
        guard case .accepted = outcome else {
            XCTFail("La demande devrait être acceptée, obtenue : \(outcome)")
            return
        }

        manager.markInterrupted(transferID: id, transferredBytes: 0)

        // Sans aucun octet sur disque (0 < fileSize), receivedBytes vaut 0 :
        // la reprise doit être refusée plutôt qu'envoyée avec un offset vide.
        XCTAssertFalse(manager.resumeIncomingTransfer(
            transferID: id,
            connectionManager: connectionManager
        ))
    }

    func testIncomingResumeRejectedWhenPartialComplete() async throws {
        let manager = makeTransferManager()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { connection.cancel() }
        let connectionManager = makeConnectionManager(transferManager: manager)
        let id = UUID()
        defer { cleanupPartialFiles(for: id) }

        let request = TransferRequestPayload(
            transferID: id,
            fileName: "fichier-test.bin",
            fileSize: 4
        )
        _ = await manager.createIncomingTransfer(
            request: request,
            sender: makePeer()
        )
        manager.markInterrupted(transferID: id, transferredBytes: 4)

        // Le .partial couvre déjà tout le fichier : reprendre n'a pas de
        // sens et la garde `receivedBytes < fileSize` l'interdit.
        XCTAssertFalse(manager.resumeIncomingTransfer(
            transferID: id,
            connectionManager: connectionManager
        ))
    }

    // MARK: - Append mode du writer entrant

    func testIncomingWriterAppendRejectsWrongOffset() throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let writer = try IncomingFileWriter(transferID: transferID)
        do {
            try writer.append(data: Data([0x01]), at: 1)
            XCTFail("Écrire à un offset autre que la fin doit échouer")
        } catch let error as IncomingFileWriterError {
            guard case .invalidOffset(let expected, let received) = error else {
                XCTFail("Erreur inattendue : \(error)")
                return
            }
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(received, 1)
        }
        try writer.close()
    }

    func testIncomingWriterAppendModeContinuesExistingPartial() throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Premier passage : écrire 4 octets puis fermer (interruption).
        let firstWriter = try IncomingFileWriter(transferID: transferID)
        try firstWriter.append(data: Data([1, 2, 3, 4]), at: 0)
        try firstWriter.close()

        // Reprise : réouvrir en mode append à l'offset connu du pair.
        let resumedWriter = try IncomingFileWriter(
            transferID: transferID,
            appendAtOffset: 4
        )
        XCTAssertEqual(resumedWriter.writtenBytes, 4,
                       "L'append démarre depuis ce qui existe déjà sur disque")
        try resumedWriter.append(data: Data([5, 6]), at: 4)
        XCTAssertEqual(resumedWriter.writtenBytes, 6)

        let data = try Data(contentsOf: resumedWriter.temporaryURL)
        XCTAssertEqual(data, Data([1, 2, 3, 4, 5, 6]),
                       "Le fichier finalisé doit contenir les deux segments dans l'ordre")
        try resumedWriter.close()
    }

    func testIncomingWriterTruncatesDiskBeyondAcceptedOffset() throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let firstWriter = try IncomingFileWriter(transferID: transferID)
        try firstWriter.append(data: Data([1, 2, 3, 4]), at: 0)
        try firstWriter.close()

        // L'émetteur ne reconnaît que 2 octets : le disque dépasse l'offset
        // accepté, il doit être tronqué sinon des octets invérifiables
        // resteraient dans le fichier final.
        let resumedWriter = try IncomingFileWriter(
            transferID: transferID,
            appendAtOffset: 2
        )
        XCTAssertEqual(resumedWriter.writtenBytes, 2)
        let data = try Data(contentsOf: resumedWriter.temporaryURL)
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data, Data([1, 2]))
        try resumedWriter.close()
    }

    func testIncomingWriterRejectsOffsetBeyondDisk() throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let firstWriter = try IncomingFileWriter(transferID: transferID)
        try firstWriter.append(data: Data([1, 2, 3, 4]), at: 0)
        try firstWriter.close()

        XCTAssertThrowsError(
            try IncomingFileWriter(transferID: transferID, appendAtOffset: 10)
        ) { error in
            guard case IncomingFileWriterError.invalidOffset(_, _) = error else {
                XCTFail("Erreur inattendue : \(error)")
                return
            }
        }
    }

    func testIncomingWriterCancelRemovesPartialFile() throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let writer = try IncomingFileWriter(transferID: transferID)
        try writer.append(data: Data([1, 2, 3]), at: 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: writer.temporaryURL.path
        ))

        writer.cancel()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: writer.temporaryURL.path
        ), "cancel() doit supprimer le fichier partiel")
    }

    func testIncomingWriterClosedAfterFinalizationRefusesAppends() throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let writer = try IncomingFileWriter(transferID: transferID)
        try writer.close()

        XCTAssertThrowsError(
            try writer.append(data: Data([1]), at: 0)
        ) { error in
            guard case IncomingFileWriterError.writerClosed = error else {
                XCTFail("Erreur inattendue : \(error)")
                return
            }
        }
    }

    // MARK: - Stratégie min : taille réelle du .partial vs métadonnées

    func testPartialFileBytesUsesRealFileSizeNotMetadata() throws {
        let manager = makeTransferManager()
        let id = UUID()
        defer { cleanupPartialFiles(for: id) }

        let writer = try IncomingFileWriter(transferID: id)
        try writer.append(data: Data(count: 128), at: 0)

        XCTAssertEqual(manager.incomingPartialFileBytes(transferID: id), 128,
                       "La taille réelle sur disque fait foi")

        try writer.close()

        // Même sans writer ouvert (post-interruption), la taille du
        // fichier .partial reste lisible.
        XCTAssertEqual(
            manager.incomingPartialFileBytes(transferID: id), 128,
            "partialFileBytes doit lire le disque même sans writer actif"
        )
    }

    // MARK: - Nettoyage automatique vs .interrupted

    func testScheduleRemovalDoesNotRemoveInterruptedTransfer() throws {
        let store = TransferStore()
        let id = UUID()
        store.append(makeTransfer(
            id: id,
            fileSize: 100,
            transferredBytes: 50,
            state: .interrupted
        ))

        // Le nettoyage différé ne doit pas effacer un transfert non
        // terminal : .interrupted reste visible pour la reprise.
        store.scheduleRemoval(transferID: id, after: .milliseconds(10))

        XCTAssertNotNil(store.transfer(withID: id),
                        ".interrupted ne doit pas être retiré par scheduleRemoval")
    }

    func testTerminalTransfersAreDetectedCorrectly() throws {
        let store = TransferStore()
        let completed = makeTransfer(fileSize: 100, transferredBytes: 100, state: .completed)
        let interrupted = makeTransfer(fileSize: 100, transferredBytes: 50, state: .interrupted)
        store.append(completed)
        store.append(interrupted)

        XCTAssertTrue(store.isTerminal(transferID: completed.id))
        XCTAssertFalse(store.isTerminal(transferID: interrupted.id),
                       ".interrupted est non terminal")
    }

    // MARK: - Compatibilité protocole v1 / v2 / fallback

    func testV1ChunkPayloadRoundTripsThroughJSON() throws {
        let payload = FileChunkPayload(
            transferID: UUID(),
            offset: 123,
            data: Data([9, 8, 7]),
            isLastChunk: false
        )

        let codec = MessageCodec()
        let encoded = try codec.encodePayload(payload, protocolVersion: 1)
        let decoded = try codec.decodePayload(
            FileChunkPayload.self,
            from: encoded,
            protocolVersion: 1,
            messageType: .fileChunk
        )

        XCTAssertEqual(decoded.transferID, payload.transferID)
        XCTAssertEqual(decoded.offset, payload.offset)
        XCTAssertEqual(decoded.data, payload.data)
        XCTAssertEqual(decoded.isLastChunk, payload.isLastChunk)
    }

    func testV2BinaryChunkPayloadRoundTrips() throws {
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 456,
            data: Data([5, 4, 3, 2, 1]),
            isLastChunk: false
        )

        let encoded = payload.encode()
        let decoded = try BinaryFileChunkPayload.decode(encoded)

        XCTAssertEqual(decoded.transferID, payload.transferID)
        XCTAssertEqual(decoded.offset, payload.offset)
        XCTAssertEqual(decoded.data, payload.data)
        XCTAssertEqual(decoded.isLastChunk, payload.isLastChunk)
    }

    func testV2BinaryChunkEncodesLastFlagAndLength() throws {
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data([1, 2, 3]),
            isLastChunk: true
        )

        let encoded = payload.encode()
        XCTAssertEqual(encoded.count, BinaryFileChunkPayload.headerSize + 3)

        // Flags (octet 28) : bit 0 positionné pour isLastChunk.
        XCTAssertEqual(encoded[encoded.startIndex + 28], 0x01)

        // Length (UInt32BE aux 4 premiers octets) : taille des données.
        let length = UInt32(encoded[encoded.startIndex]) << 24
            | UInt32(encoded[encoded.startIndex + 1]) << 16
            | UInt32(encoded[encoded.startIndex + 2]) << 8
            | UInt32(encoded[encoded.startIndex + 3])
        XCTAssertEqual(length, 3)
    }

    func testResumeRequestPayloadFallsBackToJSONInV1() throws {
        let payload = ResumeRequestPayload(
            transferID: UUID(),
            offset: 250,
            fileName: "fichier-test.bin",
            sha256: "",
            chunkSize: 0,
            receivedBytes: 250,
            fileSize: 1_000,
            protocolVersion: 1
        )

        let codec = MessageCodec()
        let encoded = try codec.encodePayload(payload, protocolVersion: 1)
        let decoded = try codec.decodePayload(
            ResumeRequestPayload.self,
            from: encoded,
            protocolVersion: 1,
            messageType: .resumeRequest
        )

        XCTAssertEqual(decoded.transferID, payload.transferID)
        XCTAssertEqual(decoded.offset, 250)
        XCTAssertEqual(decoded.receivedBytes, 250)
        XCTAssertEqual(decoded.fileSize, 1_000)
        XCTAssertEqual(decoded.protocolVersion, 1)
    }

    func testResumeAcceptedPayloadRoundTripsThroughJSON() throws {
        let payload = ResumeAcceptedPayload(
            transferID: UUID(),
            offset: 750,
            fileName: "fichier-test.bin",
            sha256: "",
            chunkSize: 65_536,
            fileSize: 1_000
        )

        let codec = MessageCodec()
        let encoded = try codec.encodePayload(payload)
        let decoded = try codec.decodePayload(
            ResumeAcceptedPayload.self,
            from: encoded,
            messageType: .resumeAccepted
        )

        XCTAssertEqual(decoded.transferID, payload.transferID)
        XCTAssertEqual(decoded.offset, 750)
        XCTAssertEqual(decoded.chunkSize, 65_536)
        XCTAssertEqual(decoded.fileSize, 1_000)
    }

    /// La plage de versions acceptée : la v1 n'est plus acceptée
    /// (contrôle non authentiqué + chunks en clair, downgrade silencieux
    /// possible), seule la version courante l'est.
    func testProtocolVersionsRejectV1AndAcceptCurrentV2() {
        XCTAssertFalse(
            ProtocolCompatibility.isSupported(1),
            "v1 n'est plus acceptée (anti-downgrade)"
        )
        XCTAssertTrue(ProtocolCompatibility.isSupported(
            ProtocolCompatibility.currentVersion
        ))
        XCTAssertFalse(ProtocolCompatibility.isSupported(99))
        XCTAssertFalse(ProtocolCompatibility.isSupported(0))
    }

    func testMessageRouterStillRoutesChunkAndResumeMessages() {
        let router = MessageRouter()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { connection.cancel() }
        let sender = makePeer()

        var routedTypes: [AirBridgeMessageType] = []
        router.onEvent = { event in
            switch event {
            case .fileChunk: routedTypes.append(.fileChunk)
            case .resumeRequest: routedTypes.append(.resumeRequest)
            case .resumeAccepted: routedTypes.append(.resumeAccepted)
            default: break
            }
        }

        for type in [AirBridgeMessageType.fileChunk, .resumeRequest, .resumeAccepted] {
            router.route(
                AirBridgeMessage(type: type, sender: sender),
                on: connection
            )
        }

        XCTAssertEqual(routedTypes, [.fileChunk, .resumeRequest, .resumeAccepted],
                       "Les types chunk/resume doivent continuer d'être routés")
    }

    // MARK: - Restauration au démarrage (GAP4)

    func testStartupRestorationCreatesInterruptedTransfer() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Écrire un .partial sur disque
        let writer = try IncomingFileWriter(transferID: transferID)
        try writer.append(data: Data(count: 300), at: 0)
        try writer.close()

        let peerID = UUID()
        let info = ResumeTransferInfo(
            transferID: transferID,
            fileSize: 1_000,
            transferredBytes: 250, // métadonnées disent 250
            fileName: "fichier-test.bin",
            direction: "incoming",
            peerID: peerID,
            timestamp: Date(),
            partialFileURL: writer.temporaryURL
        )

        // Le `.partial` existe : les octets sont réconciliés (min des
        // deux sources), puis le transfert est recréé en état interrompu.
        let bytes = AirBridgeCore.resolvedRestorationBytes(for: info)
        XCTAssertEqual(bytes, 250,
                       "Réconciliation min(disque=300, métadonnées=250)")

        guard let bytes else { return }
        manager.restoreInterruptedTransfer(info: info, transferredBytes: bytes)

        let restored = manager.transfers.first { $0.id == transferID }
        XCTAssertNotNil(restored, "Le transfert doit être restauré")
        XCTAssertEqual(restored?.state, .interrupted)
        XCTAssertEqual(restored?.transferredBytes, 250)
        XCTAssertEqual(restored?.direction, .incoming)
        XCTAssertEqual(restored?.fileName, "fichier-test.bin")
        XCTAssertEqual(restored?.peer.id, peerID)
        XCTAssertFalse(restored?.state.isTerminal ?? true,
                       ".interrupted est non terminal")

        // Une restauration rejouée ne duplique pas l'entrée.
        manager.restoreInterruptedTransfer(info: info, transferredBytes: bytes)
        XCTAssertEqual(manager.transfers.filter { $0.id == transferID }.count, 1)
    }

    func testStartupRestorationSkipsOrphanMetadata() async throws {
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Métadonnées sans .partial sur disque : orpheline
        let info = ResumeTransferInfo(
            transferID: transferID,
            fileSize: 1_000,
            transferredBytes: 500,
            fileName: "fichier-test.bin",
            direction: "incoming",
            peerID: UUID(),
            timestamp: Date(),
            partialFileURL: IncomingFileWriter.temporaryURL(for: transferID)
        )

        // La boucle de démarrage s'appuie sur cette décision : `nil`
        // signifie « rien à restaurer », la métadonnée sera purgée.
        let resolved = AirBridgeCore.resolvedRestorationBytes(for: info)
        XCTAssertNil(resolved,
                     "Métadonnée orpheline (.partial absent) doit être ignorée")
    }

    func testStartupRestorationReconcilesDiskVsMetadata() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Disque plus grand que métadonnées (écriture au-delà d'un crash)
        let writer = try IncomingFileWriter(transferID: transferID)
        try writer.append(data: Data(count: 800), at: 0)
        try writer.close()

        let info = ResumeTransferInfo(
            transferID: transferID,
            fileSize: 1_000,
            transferredBytes: 500, // métadonnées disent 500
            fileName: "fichier-test.bin",
            direction: "incoming",
            peerID: UUID(),
            timestamp: Date(),
            partialFileURL: writer.temporaryURL
        )

        // La réconciliation doit prendre le MIN : 500 (métadonnées),
        // jamais les 800 octets réels du disque.
        let reconciled = AirBridgeCore.resolvedRestorationBytes(for: info)
        XCTAssertEqual(reconciled, 500,
                       "La réconciliation doit borner aux métadonnées")

        guard let reconciled else { return }
        manager.restoreInterruptedTransfer(
            info: info,
            transferredBytes: reconciled
        )

        let restored = manager.transfers.first { $0.id == transferID }
        XCTAssertEqual(restored?.transferredBytes, 500)
    }

    // MARK: - Reprise et session sécurisée (GAP3)

    /// La reprise d'un transfert entrant exige une session sécurisée prête
    /// (`isSessionReady` + `isSecureSessionReady`) avec un pair correspondant.
    /// Sans elle, la demande est refusée et le transfert reste `.interrupted` :
    /// un transfert ne doit jamais se réactiver silencieusement sur une
    /// session non authentifiée — ce serait le vecteur d'un downgrade.
    func testIncomingResumeRefusedWithoutSecureSession() async throws {
        let manager = makeTransferManager()

        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        // Créer un transfert interrompu côté réception, avec des octets
        // réellement sur disque : la progression est valide, c'est donc
        // uniquement l'absence de session sécurisée qui bloque.
        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "test.bin",
            fileSize: 1_000
        )
        let cipher = installEncryption(on: manager, chunkSize: 200)
        _ = await manager.createIncomingTransfer(request: request, sender: sender)

        manager.markAccepted(transferID: transferID)
        let wasWritten = await appendEncrypted(
            Data(count: 200),
            transferID: transferID,
            offset: 0,
            chunkSize: 200,
            sessionId: UUID(),
            using: cipher,
            on: manager
        )
        XCTAssertTrue(wasWritten, "Le chunk doit être écrit sur disque")
        XCTAssertEqual(manager.incomingPartialFileBytes(transferID: transferID), 200)

        // Interruption : état non terminal, resumable.
        manager.markInterrupted(transferID: transferID, transferredBytes: 200)
        XCTAssertEqual(manager.transfers.first { $0.id == transferID }?.state,
                       .interrupted)

        // Aucune session sécurisée prête : la reprise est refusée.
        let connectionManager = makeConnectionManager(transferManager: manager)
        let attempt = manager.resumeIncomingTransfer(
            transferID: transferID,
            connectionManager: connectionManager
        )
        XCTAssertFalse(
            attempt,
            "Sans session sécurisée prête, la reprise doit être refusée"
        )

        // L'état reste .interrupted : rien n'a été réactivé silencieusement.
        XCTAssertEqual(
            manager.transfers.first { $0.id == transferID }?.state,
            .interrupted,
            "Un refus ne doit pas muter l'état du transfert"
        )
    }

    // MARK: - Désordre de chunks (GAP réordonnancement)

    /// Vérifie le buffer de chunks en désordre : un envoi dans l'ordre
    /// 0, 2, 1, 3 doit produire un fichier identique à un envoi strict
    /// 0, 1, 2, 3, et la purge doit vider le buffer sans perdre d'octets.
    func testOutOfOrderChunksAreReassembledInFileOrder() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "desordre.bin",
            fileSize: 8
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        let session = UUID()
        let chunk0 = Data([0xAA, 0xAA])   // offset 0
        let chunk1 = Data([0xBB, 0xBB])   // offset 2 (arrive en 2e)
        let chunk2 = Data([0xCC, 0xCC])   // offset 4 (arrive en 3e, désordre)
        let chunk3 = Data([0xDD, 0xDD])   // offset 6 (arrive en dernier)

        // Envoi volontairement réordonné : 0, 2, 1, 3.
        let cipher = installEncryption(on: manager, chunkSize: 2)
        let r1 = await appendEncrypted(
            chunk0, transferID: transferID, offset: 0,
            chunkSize: 2, sessionId: session,
            using: cipher, on: manager
        )
        XCTAssertTrue(r1)
        let r2 = await appendEncrypted(
            chunk2, transferID: transferID, offset: 4,
            chunkSize: 2, sessionId: session,
            using: cipher, on: manager
        )
        XCTAssertTrue(r2, "Chunk 2 bufferisé : offset 4 > writtenBytes 2")
        XCTAssertEqual(manager.incomingPartialFileBytes(transferID: transferID), 2,
                       "Le disque ne progresse pas tant que le trou n'est pas comblé")
        let r3 = await appendEncrypted(
            chunk1, transferID: transferID, offset: 2,
            chunkSize: 2, sessionId: session,
            using: cipher, on: manager
        )
        XCTAssertTrue(r3, "Chunk 1 comble le trou et déclenche la purge du buffer")
        XCTAssertEqual(manager.incomingPartialFileBytes(transferID: transferID), 6,
                       "Après purge, les offsets 0,2,4 sont écrits")
        let r4 = await appendEncrypted(
            chunk3, transferID: transferID, offset: 6,
            chunkSize: 2, sessionId: session,
            using: cipher, on: manager
        )
        XCTAssertTrue(r4)
        XCTAssertEqual(manager.incomingPartialFileBytes(transferID: transferID), 8,
                       "Tous les octets sont sur disque avant finalize")

        let finalized = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: 8
        )
        XCTAssertTrue(finalized, "Le transfert se finalise sans trou")

        let url = try manager.receivedTemporaryFileURL(transferID: transferID)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, Data([0xAA, 0xAA, 0xBB, 0xBB, 0xCC, 0xCC, 0xDD, 0xDD]),
                       "Le fichier final est strictement dans l'ordre logique")
    }

    /// Un trou non comblé à la finalisation doit échouer proprement,
    /// pas laisser un fichier partiel menteur.
    func testFinalizeWithUnresolvedHoleFailsCleanly() async throws {
        let manager = makeTransferManager()
        let transferID = UUID()
        defer { cleanupPartialFiles(for: transferID) }

        let sender = makePeer()
        let request = TransferRequestPayload(
            transferID: transferID,
            fileName: "hole.bin",
            fileSize: 6
        )
        _ = await manager.createIncomingTransfer(request: request, sender: sender)
        manager.markAccepted(transferID: transferID)

        let session = UUID()
        let cipher = installEncryption(on: manager, chunkSize: 2)
        let r1 = await appendEncrypted(
            Data([0x01, 0x02]), transferID: transferID, offset: 0,
            chunkSize: 2, sessionId: session,
            using: cipher, on: manager
        )
        XCTAssertTrue(r1)
        let r2 = await appendEncrypted(
            Data([0x05, 0x06]), transferID: transferID, offset: 4,
            chunkSize: 2, sessionId: session,
            using: cipher, on: manager
        )
        XCTAssertTrue(r2, "Le chunk 2 (offset 4) reste en mémoire : offset 2 manque")

        let finalized = await manager.finalizeReceivedTransfer(
            transferID: transferID, announcedTotalBytes: 6
        )
        XCTAssertFalse(finalized, "Un trou non comblé ne peut pas finaliser")

        XCTAssertEqual(manager.transfers.first { $0.id == transferID }?.state,
                       .failed,
                       "Le transfert est marqué en échec")
    }
}
