//
//  Transfer.swift
//  AirBridge
//

import Foundation

struct Transfer: Identifiable, Sendable {

    /// Conformance `Equatable` (synthétisée : enum sans valeur
    /// associée). Requise par les comparaisons d'état du Core
    /// (`transfer.state == .interrupted`), du ViewModel et des tests
    /// (`XCTAssertEqual`) — sans elle, ces comparaisons ne compilent
    /// pas.
    enum Direction: Sendable, Equatable {
        case incoming
        case outgoing
    }

    enum State: Sendable, Equatable {
        case requesting
        case waitingForApproval
        case accepted
        case transferring

        /// Tous les octets ont été envoyés et le `transferCompleted` a
        /// été émis : l'émetteur attend la validation finale du
        /// récepteur (`transferSucceeded`), qui seule autorise le
        /// passage à `.completed`.
        ///
        /// Cet état n'existe que côté émetteur : le récepteur valide
        /// dans son handler `transferCompleted` sans état intermédiaire.
        case awaitingConfirmation

        case interrupted
        case completed
        case rejected
        case cancelled
        case failed

        var displayName: String {
            switch self {
            case .requesting: "Préparation"
            case .waitingForApproval: "En attente"
            case .accepted: "Accepté"
            case .transferring: "En cours"
            case .awaitingConfirmation: "Validation du récepteur"
            case .interrupted: "Interrompu"
            case .completed: "Réussi"
            case .rejected: "Refusé"
            case .cancelled: "Annulé"
            case .failed: "Échec"
            }
        }

        /// Un état terminal ne peut plus évoluer : le transfert
        /// appartient alors à la liste des transferts terminés.
        var isTerminal: Bool {
            switch self {
            case .requesting,
                 .waitingForApproval,
                 .accepted,
                 .transferring,
                 .awaitingConfirmation,
                 .interrupted:
                false
            case .completed,
                 .rejected,
                 .cancelled,
                 .failed:
                true
            }
        }
    }

    let id: UUID
    var peer: Device
    let fileName: String
    let fileSize: Int64
    let direction: Direction

    var state: State
    var transferredBytes: Int64
    var sourceFileURL: URL?
    var localFileURL: URL?
    var pendingChunks: [(offset: Int64, data: Data)] = []

    /// Identifiant de la sélection d'origine, `nil` pour un fichier isolé.
    ///
    /// Purement descriptif : il permet à l'affichage de regrouper en un
    /// seul « dossier » les fichiers choisis en une même sélection, sans
    /// influencer le protocole ni le déroulement du transfert.
    var batchID: UUID?

    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var sha256: String?
    var chunkCount: Int
    var errorMessage: String?

    init(
        id: UUID,
        peer: Device,
        fileName: String,
        fileSize: Int64,
        direction: Direction,
        state: State,
        transferredBytes: Int64,
        sourceFileURL: URL? = nil,
        localFileURL: URL? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        sha256: String? = nil,
        chunkCount: Int = 0,
        errorMessage: String? = nil,
        batchID: UUID? = nil,
        pendingChunks: [(offset: Int64, data: Data)] = []
    ) {
        self.id = id
        self.peer = peer
        self.fileName = fileName
        self.fileSize = fileSize
        self.direction = direction
        self.state = state
        self.transferredBytes = transferredBytes
        self.sourceFileURL = sourceFileURL
        self.localFileURL = localFileURL
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.sha256 = sha256
        self.chunkCount = chunkCount
        self.errorMessage = errorMessage
        self.batchID = batchID
        self.pendingChunks = pendingChunks
    }

    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(max(Double(transferredBytes) / Double(fileSize), 0), 1)
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// Sépare les transferts affichés en cours de ceux qui alimentent la
/// liste d'aperçu des transferts terminés.
extension Sequence<Transfer> {

    var activeTransfers: [Transfer] {
        filter { !$0.state.isTerminal }
    }

    var completedTransfers: [Transfer] {
        filter { $0.state.isTerminal }
    }
}
