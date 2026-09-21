//
//  TransferStore.swift
//  AirBridge
//

import Foundation
import Observation

@MainActor
@Observable
final class TransferStore {

    private(set) var transfers: [Transfer] = []
    private var removalTasks: [UUID: Task<Void, Never>] = [:]

    /// Programme le retrait différé d'un transfert terminé.
    ///
    /// Historiquement coquille vide : la tâche était annulée sans jamais
    /// être planifiée. Elle planifie désormais réellement le retrait, mais
    /// uniquement si le transfert est terminal au moment venu — un transfert
    /// non terminal (dont `.interrupted`) reste visible pour la reprise.
    /// Aucun chemin de production ne l'appelle encore : la fonction est
    /// conservée car la suite de tests en couvre le contrat.
    func scheduleRemoval(transferID: UUID, after delay: Duration) {
        removalTasks[transferID]?.cancel()

        removalTasks[transferID] = Task { [weak self] in
            try? await Task.sleep(for: delay)

            guard !Task.isCancelled else { return }
            guard let self else { return }

            guard let transfer = self.transfer(withID: transferID),
                  transfer.state.isTerminal else {
                self.removalTasks[transferID] = nil
                return
            }

            self.removeTransfer(transferID: transferID)
        }
    }

    func transfer(withID transferID: UUID) -> Transfer? {
        transfers.first { $0.id == transferID }
    }

    func hasTransfer(_ transferID: UUID) -> Bool {
        transfers.contains { $0.id == transferID }
    }

    func isTerminal(transferID: UUID) -> Bool {
        guard let transfer = transfer(withID: transferID) else { return false }
        // .interrupted est non terminal : le transfert reste visible dans la
        // liste active et peut être repris.
        switch transfer.state {
        case .completed, .rejected, .cancelled, .failed: return true
        case .requesting, .waitingForApproval, .accepted,
             .transferring, .awaitingConfirmation, .interrupted: return false
        }
    }

    func append(_ newTransfer: Transfer) {
        guard transfer(withID: newTransfer.id) == nil else { return }
        transfers.append(newTransfer)
    }

    func markWaitingForApproval(transferID: UUID) {
        guard let index = index(of: transferID) else { return }
        transfers[index].state = .waitingForApproval
    }

    func markAccepted(transferID: UUID) {
        guard let index = index(of: transferID) else { return }
        transfers[index].state = .accepted
        transfers[index].startedAt = transfers[index].startedAt ?? Date()
    }

    /// Repose l'horodatage de départ à maintenant : la reprise est une
    /// continuation logique, la durée affichée ne doit pas inclure le temps
    /// d'interruption.
    func resetStartedAt(transferID: UUID) {
        guard let index = index(of: transferID) else { return }
        transfers[index].startedAt = Date()
    }

    func markRejected(transferID: UUID, reason: String? = nil) {
        guard let index = index(of: transferID) else { return }
        transfers[index].state = .rejected
        transfers[index].completedAt = Date()
        transfers[index].errorMessage = reason
    }

    func markFailed(transferID: UUID, reason: String? = nil) {
        guard let index = index(of: transferID) else { return }
        transfers[index].state = .failed
        transfers[index].completedAt = Date()
        transfers[index].errorMessage = reason
    }

    func updateProgress(transferID: UUID, transferredBytes: Int64) {
        guard let index = index(of: transferID) else { return }
        let fileSize = transfers[index].fileSize
        transfers[index].transferredBytes = min(max(transferredBytes, 0), fileSize)
        transfers[index].state = .transferring
        transfers[index].startedAt = transfers[index].startedAt ?? Date()
        transfers[index].chunkCount += 1
    }

    /// Fait passer un transfert sortant à `.awaitingConfirmation` :
    /// tous les octets ont été envoyés, le `transferCompleted` est parti,
    /// et la validation du récepteur (`transferSucceeded`) est attendue.
    ///
    /// La progression est ramenée à 100 % (dernier offset consommé par
    /// le pipeline) : l'interface affiche « 100 % — Validation du
    /// récepteur » sans jamais présenter le transfert comme réussi
    /// avant confirmation. Non terminal : annulable, interruptible
    /// (déconnexion), et sans `completedAt`.
    func markAwaitingConfirmation(
        transferID: UUID,
        transferredBytes: Int64
    ) {
        guard let index = index(of: transferID) else { return }
        let fileSize = transfers[index].fileSize
        transfers[index].transferredBytes = min(max(transferredBytes, 0), fileSize)
        transfers[index].state = .awaitingConfirmation
    }

    func setSHA256(transferID: UUID, sha256: String) {
        guard let index = index(of: transferID) else { return }
        transfers[index].sha256 = sha256
    }

    func markCompleted(transferID: UUID, transferredBytes: Int64) {
        guard let index = index(of: transferID) else { return }
        let fileSize = transfers[index].fileSize
        transfers[index].transferredBytes = min(max(transferredBytes, 0), fileSize)
        transfers[index].state = .completed
        transfers[index].startedAt = transfers[index].startedAt ?? transfers[index].createdAt
        transfers[index].completedAt = Date()
    }

    func markCancelled(transferID: UUID, reason: String? = nil) {
        guard let index = index(of: transferID) else { return }
        transfers[index].state = .cancelled
        transfers[index].completedAt = Date()
        transfers[index].errorMessage = reason
    }

    func removeTransfer(transferID: UUID) {
        removalTasks[transferID]?.cancel()
        removalTasks[transferID] = nil
        transfers.removeAll { $0.id == transferID }
    }

    func setLocalFileURL(transferID: UUID, url: URL) {
        guard let index = index(of: transferID) else { return }
        transfers[index].localFileURL = url
    }

    func setSourceFileURL(transferID: UUID, url: URL) {
        guard let index = index(of: transferID) else { return }
        transfers[index].sourceFileURL = url
    }

    func setBatchID(transferID: UUID, batchID: UUID) {
        guard let index = index(of: transferID) else { return }
        transfers[index].batchID = batchID
    }

    private func index(of transferID: UUID) -> Int? {
        transfers.firstIndex { $0.id == transferID }
    }

    /// Rattache un transfert interrompu à un pair redécouvert.
    ///
    /// Une reprise restaurée au démarrage ne connaît pas le nom du pair
    /// (« Appareil inconnu ») : la redécouverte Bonjour du pair visé est
    /// l'occasion de réparer l'affichage sans toucher au reste.
    func updatePeer(transferID: UUID, peer: Device) {
        guard let index = index(of: transferID) else { return }
        transfers[index].peer = peer
    }

    func markInterrupted(transferID: UUID, transferredBytes: Int64) {
        guard let index = index(of: transferID) else { return }
        transfers[index].state = .interrupted
        transfers[index].transferredBytes = min(max(transferredBytes, 0), transfers[index].fileSize)
        // .interrupted est non-terminal : ne pas définir completedAt,
        // la progression doit rester visible pour la reprise.
    }

    /// Fait passer à `.interrupted` tous les transferts actifs vis-à-vis du
    /// pair dont la session vient de tomber.
    ///
    /// Une déconnexion n'est pas un échec définitif : le `.partial` côté
    /// réception et l'offset côté envoi restent valides, le transfert peut
    /// donc reprendre là où il s'était arrêté. Les transferts d'un autre
    /// pair, ou déjà terminaux, ne sont pas touchés. Renvoie les
    /// identifiants réellement interrompus.
    func interruptActiveTransfers(peerID: UUID) -> [UUID] {
        var interruptedIDs: [UUID] = []

        for index in transfers.indices {
            guard transfers[index].peer.id == peerID else { continue }

            switch transfers[index].state {
            case .requesting, .waitingForApproval, .accepted, .transferring:
                transfers[index].state = .interrupted
                interruptedIDs.append(transfers[index].id)

            // Une déconnexion pendant la fenêtre de confirmation ne
            // perd rien : tous les octets sont partis, la reprise
            // renverra le `transferCompleted` et réarmera l'attente.
            case .awaitingConfirmation:
                transfers[index].state = .interrupted
                interruptedIDs.append(transfers[index].id)

            case .completed, .rejected, .cancelled, .failed, .interrupted:
                break
            }
        }

        return interruptedIDs
    }

    /// Un transfert interrompu est reprisable dans les deux sens : côté
    /// réception le `.partial` est conservé, côté envoi la copie locale
    /// sert de source à l'offset accepté par le pair.
    func isResumable(transferID: UUID) -> Bool {
        guard let transfer = transfer(withID: transferID) else { return false }
        return transfer.state == .interrupted
    }

    func cancelActiveTransfers() {
        for index in transfers.indices {
            switch transfers[index].state {
            case .requesting, .waitingForApproval, .accepted, .transferring:
                transfers[index].state = .cancelled
                transfers[index].completedAt = Date()
            // L'attente de confirmation reste annulable comme tout
            // transfert actif : le pair tranchera de son côté.
            case .awaitingConfirmation:
                transfers[index].state = .cancelled
                transfers[index].completedAt = Date()
            case .completed, .rejected, .cancelled, .failed:
                break
            case .interrupted:
                // Un transfert déjà interrompu reste resumable après une
                // déconnexion : le nettoyer ici détruirait la reprise.
                break
            }
        }
    }
}
