import Foundation
import Network
import Observation
import CryptoKit
import OSLog

@MainActor
@Observable
final class OutgoingTransferManager {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "transfer.outgoing"
    )

    /// Snapshot immutable des compteurs nécessaires au pipeline
    /// d'envoi async. Capturé sous `@MainActor` une seule fois au
    /// début du transfert, puis passé en paramètres aux tâches
    /// enfant (non isolées) — évite un saut MainActor par chunk pour
    /// relire des `var` (connexion, version, session, chiffreur).
    struct SendSnapshot: Sendable {
        let connection: NWConnection?
        let protocolVersion: Int
        let sessionId: UUID?
        let cipher: ChunkStreamCipher
    }

    /// Capture un snapshot immuable des variables d'instance
    /// nécessaires au pipeline. À appeler depuis un contexte
    /// `@MainActor` (typiquement le début de
    /// `runChunkPipeline`).
    func snapshotForSending() -> SendSnapshot {
        SendSnapshot(
            connection: connection,
            protocolVersion: negotiatedProtocolVersion,
            sessionId: sessionId,
            cipher: chunkCipher
        )
    }

    private let store: TransferStore
    /// `FrameCodec` réutilisé entre envois : l'instancier par chunk
    /// allouait inutilement. `FrameCodec` est sans état (struct), donc
    /// sûr à partager entre threads.
    private let frameCodec = FrameCodec()
    private let localDevice: Device
    private var connection: NWConnection?

    /// Version du protocole négociée. La valeur initiale est déjà v2 afin
    /// qu'un transfert ne puisse jamais se rabattre implicitement vers v1.
    /// La file reste toutefois bloquée tant que la clé ECDH n'est pas prête.
    private var negotiatedProtocolVersion: Int = ProtocolCompatibility.currentVersion

    /// Identifiant de session actif (généré au handshake sécurisé).
    /// Utilisé pour lier les chunks binaires v2 à la session courante.
    private var sessionId: UUID? = nil

    /// Chiffreur de flux. Un snapshot sans clé est inutilisable par le
    /// chemin réseau : le pipeline refuse alors le transfert au lieu de
    /// transporter les données en clair.
    private var chunkCipher: ChunkStreamCipher = ChunkStreamCipher()

    // File sources
    private var fileSources: [UUID: OutgoingFileSource] = [:]

    enum OutgoingTransferManagerError: Error {
        case noActiveConnection
        case secureSessionNotReady
        case sourceNotFound
        case encodingError(Error)
        /// Échec de l'envoi réseau lui-même (ECONNRESET, ECANCELED, erreur
        /// Network.framework) : distinct d'une erreur d'encodage, qui est
        /// définitive tandis qu'un envoi rompu reste reprisable.
        case sendError(Error)
        case fileNotFound
    }

    init(
        store: TransferStore,
        localDevice: Device
    ) {
        self.store = store
        self.localDevice = localDevice
    }

    /// Met à jour la version du protocole négociée
    func setProtocolVersion(_ version: Int) {
        negotiatedProtocolVersion = version
    }

    /// Définit l'identifiant de session pour les chunks sortants.
    func setSessionId(_ id: UUID?) {
        self.sessionId = id
    }

    /// Définit la connexion active pour l'envoi de chunks.
    func setConnection(_ connection: NWConnection?) {
        self.connection = connection
    }

    /// Installe la clé symétrique de session dérivée du handshake ECDH.
    /// À partir de cet appel, les chunks sortants sont chiffrés par
    /// ChaCha20-Poly1305 via `ChunkStreamCipher`.
    ///
    /// - Parameter key: clé 256 bits dérivée via HKDF-SHA256
    func installSessionKey(_ key: SymmetricKey) {
        self.chunkCipher = ChunkStreamCipher(key: key)
    }

    /// Réinitialise la session cryptographique. Cette méthode est appelée
    /// à chaque fermeture de connexion pour éviter qu'une clé d'une
    /// session précédente soit réutilisée.
    func clearSessionKey() {
        self.chunkCipher = ChunkStreamCipher()
        self.sessionId = nil
        self.negotiatedProtocolVersion = ProtocolCompatibility.currentVersion
    }

    // MARK: - Chunk Sending (Pipeline géré par TransferManager)

    /// API compatibilité : envoie immédiatement sans pipeline.
    /// Conservée pour les chemins qui n'utilisent pas le pipeline async
    /// (reprise, tests).
    func sendChunk(
        transferID: UUID,
        offset: Int64,
        data: Data,
        isLastChunk: Bool = false,
        chunkSize: Int = 0,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        sendChunkImmediately(
            transferID: transferID,
            offset: offset,
            data: data,
            isLastChunk: isLastChunk,
            chunkSize: chunkSize,
            completion: completion
        )
    }

    /// Variante async du pipeline : ne bloque pas le fil appelant et ne
    /// traverse pas `@MainActor` à chaque chunk.
    ///
    /// `connection.send` est invoqué de manière concurrente, avec
    /// `nonisolated(unsafe)` pour la complétion (Network.framework
    /// appelle la complétion sur sa propre file, hors isolation du
    /// manager `@MainActor`).
    ///
    /// La latence d'acheminement d'un chunk est ~1 ms sur réseau local
    /// (cf. benchmark `FrameEncode100MB` à 1800 MB/s) : la
    /// parallélisation est portée par la fenêtre en vol du pipeline
    /// appelant (`PipelineWindow` dans `runChunkPipeline`), pas par
    /// cette fonction. Un appel `sendChunkAsync` traite un chunk à
    /// la fois ; c'est l'orchestrateur qui décide d'en lancer
    /// plusieurs en parallèle.
    ///
    /// **Note importante** : `sendChunkAsync` reste une méthode
    /// `@MainActor` (lecture d'état d'instance). Le pipeline appelant
    /// doit pré-snapshoter l'état via `snapshotForSending()` et
    /// appeler directement `Self.sendChunkOverConnection` avec le
    /// snapshot pour éviter un saut MainActor par chunk.
    @available(*, deprecated, message: "Use snapshotForSending() + sendChunkOverConnectionStatic to avoid per-chunk MainActor hop")
    func sendChunkAsync(
        transferID: UUID,
        offset: Int64,
        data: Data,
        isLastChunk: Bool,
        chunkSize: Int
    ) async throws {
        let snap = snapshotForSending()
        guard let connection = snap.connection else {
            throw OutgoingTransferManagerError.noActiveConnection
        }

        try await Self.sendChunkOverConnectionStatic(
            transferID: transferID,
            offset: offset,
            data: data,
            isLastChunk: isLastChunk,
            chunkSize: chunkSize,
            snapshot: snap,
            frameCodec: frameCodec,
            connection: connection
        )
    }

    /// Variante statique et `@MainActor`-indépendante : prépare et envoie
    /// un chunk en utilisant uniquement des types valeur (Data, frame,
    /// etc.). Cela permet au pipeline async de continuer à travailler
    /// sans repasser par le MainActor entre chaque chunk.
    ///
    /// `snapshot` capture la version de protocole, l'identifiant de
    /// session et le chiffreur de flux au moment du démarrage du
    /// pipeline. Aucune lecture d'état d'instance n'est faite ici :
    /// un appel ne traverse jamais `@MainActor`, ce qui élimine le
    /// goulot principal qui bridait le débit à ~8 Mo/s.
    static func sendChunkOverConnectionStatic(
        transferID: UUID,
        offset: Int64,
        data: Data,
        isLastChunk: Bool,
        chunkSize: Int,
        snapshot: SendSnapshot,
        frameCodec: FrameCodec,
        connection: NWConnection
    ) async throws {
        let protocolVersion = snapshot.protocolVersion
        let sessionId = snapshot.sessionId
        let cipher = snapshot.cipher
        let encodeStart = Date()

        guard protocolVersion >= ProtocolCompatibility.currentVersion,
              let activeSession = sessionId,
              cipher.hasKey else {
            throw OutgoingTransferManagerError.secureSessionNotReady
        }

        guard chunkSize > 0 else {
            throw OutgoingTransferManagerError.encodingError(
                ChunkStreamCipherError.encryptionFailed
            )
        }

        // v2 uniquement : le chunkIndex est intégré à l'AAD et la clé
        // ECDH est obligatoire. Il n'existe plus de chemin JSON/base64 v1
        // ni de fallback en clair.
        let chunkIndex = UInt32(offset / Int64(chunkSize))
        let encryptedData = try cipher.encryptChecked(
            data,
            transferID: transferID,
            chunkIndex: chunkIndex,
            sessionId: activeSession
        )

        let binaryChunk = BinaryFileChunkPayload(
            transferID: transferID,
            offset: offset,
            data: encryptedData,
            isLastChunk: isLastChunk,
            sessionId: activeSession
        )
        let payloadData = binaryChunk.encode()
        let frame = try frameCodec.encode(payloadData)

        let encodeDuration = Date().timeIntervalSince(encodeStart)
        let sendStart = Date()

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: OutgoingTransferManagerError.sendError(error)
                        )
                        return
                    }
                    TransferPerformanceLog.recordSend(
                        transferID: transferID,
                        bytes: Int64(data.count),
                        encodeTime: encodeDuration,
                        sendTime: Date().timeIntervalSince(sendStart)
                    )
                    continuation.resume()
                }
            )
        }
    }

    private func sendChunkImmediately(
        transferID: UUID,
        offset: Int64,
        data: Data,
        isLastChunk: Bool,
        chunkSize: Int = 0,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let connection else {
            completion(.failure(OutgoingTransferManagerError.noActiveConnection))
            return
        }

        guard negotiatedProtocolVersion >= ProtocolCompatibility.currentVersion,
              let activeSession = sessionId,
              chunkCipher.hasKey,
              chunkSize > 0 else {
            completion(.failure(OutgoingTransferManagerError.secureSessionNotReady))
            return
        }

        do {
            let chunkIndex = UInt32(offset / Int64(chunkSize))
            let encryptedData = try chunkCipher.encryptChecked(
                data,
                transferID: transferID,
                chunkIndex: chunkIndex,
                sessionId: activeSession
            )
            let binaryChunk = BinaryFileChunkPayload(
                transferID: transferID,
                offset: offset,
                data: encryptedData,
                isLastChunk: isLastChunk,
                sessionId: activeSession
            )
            let frame = try frameCodec.encode(binaryChunk.encode())
            nonisolated(unsafe) let completion = completion
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error {
                        completion(.failure(OutgoingTransferManagerError.sendError(error)))
                        return
                    }
                    completion(.success(()))
                }
            )
        } catch {
            completion(.failure(OutgoingTransferManagerError.encodingError(error)))
        }
    }

    // MARK: - File Source Management

    func registerSource(
        transferID: UUID,
        fileURL: URL,
        originalFileURL: URL? = nil,
        isTemporary: Bool = false
    ) {
        fileSources[transferID] = OutgoingFileSource(
            transferID: transferID,
            url: fileURL,
            protectedOriginalURL: originalFileURL,
            isTemporary: isTemporary
        )
    }

    func removeSource(
        transferID: UUID,
        deleteFile: Bool = false
    ) {
        if let source = fileSources[transferID] {
            if deleteFile && source.isTemporary {
                try? FileManager.default.removeItem(at: source.url)
            }
            if let originalURL = source.protectedOriginalURL {
                originalURL.stopAccessingSecurityScopedResource()
            }
        }
        fileSources[transferID] = nil
    }

    func fileURL(for transferID: UUID) throws -> URL {
        guard let source = fileSources[transferID] else {
            throw OutgoingTransferManagerError.sourceNotFound
        }
        return source.url
    }

    func cleanupAll() {
        for (_, source) in fileSources {
            if source.isTemporary {
                try? FileManager.default.removeItem(at: source.url)
            }
            if let originalURL = source.protectedOriginalURL {
                originalURL.stopAccessingSecurityScopedResource()
            }
        }
        fileSources.removeAll()
    }

    /// Nettoie toutes les sources sortantes sauf celles d'une liste de
    /// transferts à préserver : une entrée interrompue garde sa source
    /// (temporaire ou non) pour que la reprise reprenne les octets déjà
    /// envoyés au lieu de repartir de zéro.
    func cleanupAllExcept(transferIDs: [UUID]) {
        let preserved = Set(transferIDs)

        for (transferID, source) in fileSources where !preserved.contains(transferID) {
            if source.isTemporary {
                try? FileManager.default.removeItem(at: source.url)
            }
            if let originalURL = source.protectedOriginalURL {
                originalURL.stopAccessingSecurityScopedResource()
            }
            fileSources[transferID] = nil
        }
    }

    // Les chunks v2 sont envoyés exclusivement par les deux chemins
    // chiffrés ci-dessus (`sendChunkOverConnectionStatic` et
    // `sendChunkImmediately`). Aucun encodeur de message générique ne
    // doit rester ici : il pourrait contourner la signature des contrôles
    // ou le chiffrement obligatoire.

}
