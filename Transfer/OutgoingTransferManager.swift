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
    private let messageCodec = MessageCodec()
    /// `FrameCodec` réutilisé entre envois : l'instancier par chunk
    /// allouait inutilement. `FrameCodec` est sans état (struct), donc
    /// sûr à partager entre threads.
    private let frameCodec = FrameCodec()
    private let localDevice: Device
    private var connection: NWConnection?

    /// Version du protocole négociée (défaut v1, passe à v2 après handshake)
    private var negotiatedProtocolVersion: Int = 1

    /// Identifiant de session actif (généré au handshake sécurisé).
    /// Utilisé pour lier les chunks binaires v2 à la session courante.
    private var sessionId: UUID? = nil

    /// Chiffreur de flux optionnel : en mode transparent tant qu'aucune
    /// clé n'est installée (ChunkStreamCipher retournant plaintext tel
    /// quel). Une fois la clé dérivée du handshake ECDH P-256 installée
    /// via `installSessionKey(_:)`, chaque chunk binaire v2 est scellé
    /// par ChaCha20-Poly1305 avant d'être encodé dans la trame réseau.
    private var chunkCipher: ChunkStreamCipher = ChunkStreamCipher()

    // File sources
    private var fileSources: [UUID: OutgoingFileSource] = [:]

    enum OutgoingTransferManagerError: Error {
        case noActiveConnection
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

    /// Réinitialise le chiffreur en mode transparent (clé oubliée).
    func clearSessionKey() {
        self.chunkCipher = ChunkStreamCipher()
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

        let frame: Data
        if protocolVersion >= 2 {
            // Calcul du chunkIndex : entier séquentiel basé sur l'offset
            // et la taille de chunk négociée. Cohérent avec le calcul
            // côté réception (même fonction de dérivation). Le
            // `chunkIndex` est intégré à l'AAD du `ChunkStreamCipher` :
            // déplacer un chunk d'un offset à l'autre invalide le tag.
            let chunkIndex: UInt32 = {
                guard chunkSize > 0 else { return UInt32(offset >> 32) }
                return UInt32(offset / Int64(chunkSize))
            }()

            // 1. Chiffrement du payload de chunk (transparent si pas de clé).
            let activeSession = sessionId ?? UUID()
            let encryptedData = cipher.encrypt(
                data,
                transferID: transferID,
                chunkIndex: chunkIndex,
                sessionId: activeSession
            )

            // 2. Encodage binaire du chunk avec les octets chiffrés.
            //    Le `length` dans l'en-tête binaire est la taille des
            //    octets effectivement transportés (chiffrés), ce qui
            //    permet au récepteur de borner la lecture.
            let binaryChunk = BinaryFileChunkPayload(
                transferID: transferID,
                offset: offset,
                data: encryptedData,
                isLastChunk: isLastChunk,
                sessionId: activeSession
            )
            let payloadData = binaryChunk.encode()
            frame = try frameCodec.encode(payloadData)
        } else {
            // v1 : chemin JSON (conservé pour la compatibilité ascendante)
            let payload = FileChunkPayload(
                transferID: transferID,
                offset: offset,
                data: data,
                isLastChunk: isLastChunk
            )
            let payloadData = try JSONEncoder().encode(payload)
            // Construction d'un AirBridgeMessage v1 (en-tête JSON standard)
            let message = AirBridgeMessage(
                protocolVersion: protocolVersion,
                type: .fileChunk,
                sender: Device(
                    id: UUID(),
                    name: "",
                    model: "",
                    systemVersion: ""
                ),
                payload: payloadData
            )
            let messageData = try JSONEncoder().encode(message)
            frame = try frameCodec.encode(messageData)
        }

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

        let encodeStart = Date()

        // v2+ : format binaire direct (pas de JSON/base64)
        // v1 : JSON/base64 (compatibilité)
        let payloadData: Data
        do {
            if negotiatedProtocolVersion >= 2 {
                // chunkIndex cohérent avec la version async.
                let chunkIndex: UInt32 = {
                    guard chunkSize > 0 else { return UInt32(offset >> 32) }
                    return UInt32(offset / Int64(chunkSize))
                }()

                let activeSession = sessionId ?? UUID()
                let encryptedData = chunkCipher.encrypt(
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
                payloadData = binaryChunk.encode()

                // Pour v2+: envoyer un frame binaire direct (pas d'AirBridgeMessage JSON)
                // Format: [FrameHeader][BinaryFileChunkPayload]
                let frame = try frameCodec.encode(payloadData)

                let encodeDuration = Date().timeIntervalSince(encodeStart)
                let sendStart = Date()

                // `completion` est invoquée exactement une fois par le
                // framework Network, sur sa propre file, avant que cet envoi
                // ne soit terminé : la copie explicitement non isolée ne
                // crée aucune course de données.
                nonisolated(unsafe) let completion = completion

                connection.send(
                    content: frame,
                    completion: .contentProcessed { error in
                        if let error {
                            // L'erreur brute est propagée sous `.sendError` :
                            // l'emballer dans `.encodingError` la ferait
                            // classer comme échec définitif, alors qu'une
                            // coupure réseau reste reprisable.
                            self.logger.error("Erreur d'envoi fileChunk v2 : \(error.localizedDescription, privacy: .public)")
                            completion(.failure(OutgoingTransferManagerError.sendError(error)))
                            return
                        }
                        TransferPerformanceLog.recordSend(
                            transferID: transferID,
                            bytes: Int64(data.count),
                            encodeTime: encodeDuration,
                            sendTime: Date().timeIntervalSince(sendStart)
                        )
                        completion(.success(()))
                    }
                )
                return
            } else {
                let payload = FileChunkPayload(
                    transferID: transferID,
                    offset: offset,
                    data: data,
                    isLastChunk: isLastChunk
                )
                payloadData = try messageCodec.encodePayload(payload)
            }
        } catch {
            logger.error("Impossible d'encoder fileChunk : \(error.localizedDescription, privacy: .public)")
            completion(.failure(OutgoingTransferManagerError.encodingError(error)))
            return
        }

        // v1: utiliser le format JSON standard
        // Important: utiliser la version négociée, pas la version courante par défaut
        let message = AirBridgeMessage(
            protocolVersion: negotiatedProtocolVersion,
            type: .fileChunk,
            sender: localDevice,
            payload: payloadData
        )

        send(message, on: connection, completion: completion)
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

    // MARK: - Private Network Send

    private func send(
        _ message: AirBridgeMessage,
        on connection: NWConnection,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let messageData = try messageCodec.encode(message)
            // Réutilisation de l'instance `frameCodec` : instancier
            // `FrameCodec()` à chaque envoi allouait inutilement.
            let frame = try frameCodec.encode(messageData)

            // La complétion est appelée une seule fois, par la file du
            // framework Network : la copie explicitement non isolée ne crée
            // aucune course de données.
            nonisolated(unsafe) let completion = completion

            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    completion(.success(()))
                }
            )
        } catch {
            completion(.failure(error))
        }
    }
}
