//
//  PendingApprovalCoordinator.swift
//  AirBridge
//

import Foundation

/// Regroupe les demandes de transfert reçues en rafale afin de ne
/// présenter qu'une seule autorisation pour une sélection multiple.
///
/// Le protocole reste inchangé : l'expéditeur envoie toujours un message
/// `transferRequest` par fichier. Le regroupement est purement local au
/// récepteur : la première demande ouvre une fenêtre de coalescence, et
/// toutes les demandes du même expéditeur qui arrivent pendant cette
/// fenêtre rejoignent le même lot avant tout affichage.
@MainActor
final class PendingApprovalCoordinator {

    private let coalescingWindow: Duration

    private(set) var batch: PendingTransferBatch?
    private(set) var isReady = false

    /// Appelé à chaque fois que le lot présentable change.
    var onReadyChanged: (() -> Void)?

    private var windowTask: Task<Void, Never>?

    init(coalescingWindow: Duration = .milliseconds(400)) {
        self.coalescingWindow = coalescingWindow
    }

    /// Demandes du lot courant, prêtes ou non.
    var requests: [PendingTransferRequest] {
        batch?.requests ?? []
    }

    /// Lot à présenter à l'utilisateur, `nil` tant que la fenêtre
    /// de coalescence n'est pas écoulée.
    var presentableBatch: PendingTransferBatch? {
        isReady ? batch : nil
    }

    func append(_ request: PendingTransferRequest) {
        guard var currentBatch = batch,
              currentBatch.accepts(request) else {
            // Le lot change d'expéditeur : si un lot était présenté,
            // on le signale immédiatement pour que la sheet affichée
            // soit retirée (elle décrirait sinon des fichiers qui ne
            // sont plus ceux qu'un clic sur « Accepter » enverrait).
            // Si aucun lot n'était présenté, on évite de notifier
            // inutilement — la nouvelle fenêtre démarre silencieusement.
            let wasReady = isReady
            batch = PendingTransferBatch(request: request)
            isReady = false
            restartWindow()
            if wasReady {
                onReadyChanged?()
            }
            return
        }

        let countBeforeAppend = currentBatch.fileCount
        currentBatch.append(request)

        guard currentBatch.fileCount != countBeforeAppend else {
            return
        }

        batch = currentBatch

        // Un lot déjà présenté ne repart pas en attente : le fichier
        // rejoint l'autorisation en cours d'affichage.
        if isReady {
            onReadyChanged?()
        } else {
            restartWindow()
        }
    }

    func clear() {
        windowTask?.cancel()
        windowTask = nil
        batch = nil
        isReady = false
        onReadyChanged?()
    }

    func remove(transferIDs: Set<UUID>) {
        guard var currentBatch = batch else {
            return
        }

        currentBatch.remove(transferIDs: transferIDs)

        guard !currentBatch.requests.isEmpty else {
            clear()
            return
        }

        batch = currentBatch
        onReadyChanged?()
    }

    private func restartWindow() {
        windowTask?.cancel()

        let window = coalescingWindow

        windowTask = Task { [weak self] in
            try? await Task.sleep(for: window)

            guard !Task.isCancelled else {
                return
            }

            self?.markReady()
        }
    }

    private func markReady() {
        guard batch != nil,
              !isReady else {
            return
        }

        windowTask = nil
        isReady = true
        onReadyChanged?()
    }
}
