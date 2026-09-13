//
//  IncomingFileWriter.swift
//  AirBridge
//

import Foundation

enum IncomingFileWriterError: Error {
    case invalidOffset(
        expected: Int64,
        received: Int64
    )

    case writerClosed
}

/// `nonisolated` : le writer encapsule un `FileHandle` mutable, mais
/// il est conçu pour être possédé par **un seul executor** (le
/// `ChunkSink` actor depuis la phase 2-bis, ou MainActor avant).
/// Cette classe n'est PAS `Sendable` au sens strict : on annule
/// l'isolation par défaut du projet (`-default-isolation=MainActor`)
/// pour qu'un actor non-MainActor puisse la manipuler. La sécurité
/// repose sur l'engagement de l'appelant à ne pas partager une
/// instance entre deux contexts concurrents.
nonisolated final class IncomingFileWriter {

    let transferID: UUID
    let temporaryURL: URL

    private var fileHandle: FileHandle?

    nonisolated(unsafe) private(set) var writtenBytes: Int64 = 0

    /// URL du fichier partiel d'un transfert, indépendante de toute
    /// instance : la reprise doit la retrouver après redémarrage.
    nonisolated static func temporaryURL(for transferID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AirBridgeIncoming",
                isDirectory: true
            )
            .appendingPathComponent("\(transferID.uuidString).partial")
    }

    /// Ouvre (ou crée) le fichier partiel et reprend l'écriture là où le
    /// disque s'arrête : la taille réelle du fichier fait foi, jamais une
    /// valeur annoncée.
    nonisolated init(transferID: UUID) throws {
        self.transferID = transferID

        let temporaryURL = Self.temporaryURL(for: transferID)

        try FileManager.default.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: temporaryURL.path) {
            let wasCreated = FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: nil
            )

            guard wasCreated else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        self.temporaryURL = temporaryURL
        self.fileHandle = try FileHandle(forWritingTo: temporaryURL)

        if let fileHandle {
            try fileHandle.seekToEnd()
            writtenBytes = try Int64(fileHandle.offset())
        }
    }

    /// Réouvre un fichier partiel existant pour une reprise, en bornant
    /// l'écriture à l'offset accepté par l'émetteur.
    ///
    /// Si le disque dépasse l'offset (fichier plus long que ce que
    /// l'émetteur reconnaît), il est tronqué : écrire au-delà laisserait
    /// des octets invérifiables dans le fichier final.
    nonisolated convenience init(
        transferID: UUID,
        appendAtOffset offset: Int64
    ) throws {
        try self.init(transferID: transferID)

        guard offset >= 0, offset <= writtenBytes else {
            throw IncomingFileWriterError.invalidOffset(
                expected: writtenBytes,
                received: offset
            )
        }

        guard let fileHandle else {
            throw IncomingFileWriterError.writerClosed
        }

        if offset < writtenBytes {
            try fileHandle.truncate(atOffset: UInt64(offset))
            writtenBytes = offset
        }

        fileHandle.seek(toFileOffset: UInt64(offset))
    }

    nonisolated func append(
        data: Data,
        at offset: Int64
    ) throws {
        guard let fileHandle else {
            throw IncomingFileWriterError.writerClosed
        }

        guard offset == writtenBytes else {
            throw IncomingFileWriterError.invalidOffset(
                expected: writtenBytes,
                received: offset
            )
        }

        try fileHandle.seekToEnd()
        try fileHandle.write(
            contentsOf: data
        )

        writtenBytes += Int64(data.count)
    }

    /// Écrit `data` à la suite immédiate du contenu déjà sur disque, sans
    /// imposer d'offset explicite.
    ///
    /// C'est la brique que le manager utilise pour purger son buffer de
    /// chunks en attente, dans l'ordre, une fois que chaque trou est
    /// comblé. Le compteur `writtenBytes` reste la seule vérité sur la
    /// position d'écriture.
    nonisolated func appendInOrder(
        data: Data
    ) throws {
        guard let fileHandle else {
            throw IncomingFileWriterError.writerClosed
        }

        try fileHandle.seekToEnd()
        try fileHandle.write(
            contentsOf: data
        )

        writtenBytes += Int64(data.count)
    }

    nonisolated func close() throws {
        guard let fileHandle else {
            return
        }

        try fileHandle.synchronize()
        try fileHandle.close()

        self.fileHandle = nil
    }

    nonisolated func cancel() {
        if let fileHandle {
            try? fileHandle.close()
            self.fileHandle = nil
        }

        guard FileManager.default.fileExists(
            atPath: temporaryURL.path
        ) else {
            return
        }

        do {
            try FileManager.default.removeItem(
                at: temporaryURL
            )

            print(
                "🧹 Fichier temporaire supprimé : \(temporaryURL.lastPathComponent)"
            )
        } catch {
            print(
                "⚠️ Impossible de supprimer le fichier temporaire : \(error)"
            )
        }
    }

    deinit {
        if let fileHandle {
            try? fileHandle.close()
        }
    }
}
