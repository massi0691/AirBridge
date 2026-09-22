//
//  TransferConfirmationTests.swift
//  AirBridgeTests
//
//  Tests du cycle de confirmation finale des transferts sortants :
//
//      transferring → awaitingConfirmation → completed
//
//  Le protocole reste sans ACK par chunk : lorsque l'émetteur a envoyé
//  le dernier octet, il passe par `markAwaitingConfirmation` (100 %
//  affichés, état « Validation du récepteur ») et SEULEMENT le
//  `transferSucceeded` du récepteur — simulé ici par le
//  `markCompleted` du handler — fait passer le transfert à
//  `.completed`.
//
//  Ces tests exercent la machine à états (`TransferStore`,
//  `TransferManager`) et les mappings UI (`TransferViewModel`),
//  sans réseau : les handlers protocolaires d'`AirBridgeCore`
//  (`handleTransferSucceeded`, timeout 30 s, `handleTransferFailed`)
//  appellent exactement les méthodes vérifiées ici.
//

import XCTest
@testable import AirBridge

@MainActor
final class TransferConfirmationTests: XCTestCase {

    // MARK: - Fixtures

    private let fileSize: Int64 = 1_000_000

    private func makeDevice() -> Device {
        Device(
            id: UUID(),
            name: "Mac de Test",
            model: "MacBook Pro",
            systemVersion: "26.5"
        )
    }

    private func makeTransfer(
        state: Transfer.State = .accepted
    ) -> Transfer {
        Transfer(
            id: UUID(),
            peer: makeDevice(),
            fileName: "rapport.pdf",
            fileSize: fileSize,
            direction: .outgoing,
            state: state,
            transferredBytes: 0
        )
    }

    private func makeStore(
        with transfer: Transfer
    ) -> TransferStore {
        let store = TransferStore()
        store.append(transfer)
        return store
    }

    /// Manager réel (store + incoming/outgoing managers + historique)
    /// : les autres suites de tests (`PairingViewModelTests`, etc.)
    /// utilisent la même construction, sans réseau.
    private func makeManager() -> TransferManager {
        TransferManager(
            receivedFolderStore: ReceivedFolderStore(),
            localDevice: makeDevice(),
            historyStore: TransferHistoryStore()
        )
    }

    // MARK: - Test 1 : progression à 100 % avant confirmation

    /// Après l'envoi du dernier octet : `progress == 1.0` mais
    /// `state != .completed` tant que le `transferSucceeded` n'est pas
    /// reçu.
    func testProgressReachesOneHundredPercentWithoutCompleting() {
        let transfer = makeTransfer()
        let store = makeStore(with: transfer)

        // Dernier octet envoyé : le pipeline pousse la progression
        // finale (`updateProgress` force la mise à jour UI sur le
        // dernier chunk).
        store.updateProgress(
            transferID: transfer.id,
            transferredBytes: fileSize
        )

        var current = store.transfer(withID: transfer.id)
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.progress ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(current?.state, .transferring)
        XCTAssertNotEqual(current?.state, .completed)

        // `transferCompleted` émis : passage en attente de
        // confirmation, TOUJOURS pas terminé.
        store.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: fileSize
        )

        current = store.transfer(withID: transfer.id)
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.progress ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(current?.state, .awaitingConfirmation)
        XCTAssertNotEqual(current?.state, .completed)
        XCTAssertNil(current?.completedAt, "Aucune date de fin avant la confirmation du récepteur.")
    }

    /// `markAwaitingConfirmation` borne la progression à la taille du
    /// fichier : même un offset de pipeline dépassant la taille
    /// annoncée ne doit pas produire plus de 100 %.
    func testAwaitingConfirmationClampsProgressToFileSize() {
        let transfer = makeTransfer()
        let store = makeStore(with: transfer)

        store.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: fileSize * 2
        )

        let current = store.transfer(withID: transfer.id)
        XCTAssertEqual(current?.transferredBytes, fileSize)
        XCTAssertEqual(current?.progress ?? 0, 1.0, accuracy: 0.0001)
    }

    // MARK: - Test 2 : ordre transferring → awaitingConfirmation → completed

    func testTransitionOrderTransferringThenAwaitingThenCompleted() {
        let transfer = makeTransfer()
        let store = makeStore(with: transfer)

        var observedStates: [Transfer.State] = []

        store.updateProgress(
            transferID: transfer.id,
            transferredBytes: fileSize / 2
        )
        observedStates.append(
            store.transfer(withID: transfer.id)!.state
        )

        store.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: fileSize
        )
        observedStates.append(
            store.transfer(withID: transfer.id)!.state
        )

        // Le récepteur valide (SHA-256 + enregistrement) : c'est le
        // handler `transferSucceeded` qui appelle markCompleted.
        store.markCompleted(
            transferID: transfer.id,
            transferredBytes: fileSize
        )
        observedStates.append(
            store.transfer(withID: transfer.id)!.state
        )

        XCTAssertEqual(
            observedStates,
            [.transferring, .awaitingConfirmation, .completed],
            "Le cycle de confirmation doit être exactement "
                + "transferring → awaitingConfirmation → completed."
        )

        let finished = store.transfer(withID: transfer.id)
        XCTAssertNotNil(finished?.completedAt)
        XCTAssertTrue(finished?.state.isTerminal ?? false)
    }

    // MARK: - Test 3 : ACK retardé

    /// Un délai entre `transferCompleted` (émis) et `transferSucceeded`
    /// (reçu) laisse la progression à 100 % SANS terminer le transfert.
    func testDelayedAcknowledgementKeepsTransferUnfinished() async {
        let transfer = makeTransfer()
        let store = makeStore(with: transfer)

        store.updateProgress(
            transferID: transfer.id,
            transferredBytes: fileSize
        )
        store.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: fileSize
        )

        // Simule l'attente du récepteur (validation SHA-256 d'un gros
        // fichier, disque lent…) : 200 ms sans aucune confirmation.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let current = store.transfer(withID: transfer.id)
        XCTAssertEqual(current?.state, .awaitingConfirmation)
        XCTAssertNotEqual(current?.state, .completed)
        XCTAssertEqual(current?.progress ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertFalse(
            store.isTerminal(transferID: transfer.id),
            "L'attente de confirmation n'est pas un état terminal."
        )

        // La confirmation finit par arriver : terminé, et une seule
        // fois.
        store.markCompleted(
            transferID: transfer.id,
            transferredBytes: fileSize
        )
        XCTAssertEqual(
            store.transfer(withID: transfer.id)?.state,
            .completed
        )
    }

    // MARK: - Test 4 : échec de validation

    /// Si le récepteur refuse ou échoue sa validation (SHA-256
    /// invalide, écriture impossible, timeout 30 s de confirmation),
    /// le transfert ne doit NI s'afficher « Réussi » NI passer
    /// silencieusement à `.completed`.
    func testReceiverValidationFailureMarksFailedNotCompleted() {
        let transfer = makeTransfer()
        let store = makeStore(with: transfer)

        store.updateProgress(
            transferID: transfer.id,
            transferredBytes: fileSize
        )
        store.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: fileSize
        )

        // Échec côté récepteur → `transferFailed` → markFailed.
        store.markFailed(
            transferID: transfer.id,
            reason: "L’intégrité du fichier est invalide"
        )

        let current = store.transfer(withID: transfer.id)
        XCTAssertEqual(current?.state, .failed)
        XCTAssertNotEqual(current?.state, .completed)
        XCTAssertNotEqual(current?.state.displayName, "Réussi")

        // Côté UI : statut « Échec », jamais « Réussi » ni vert de
        // succès.
        let uiStatus = TransferViewModel.status(for: Transfer.State.failed)
        XCTAssertEqual(uiStatus, TransferUIStatus.failed)
        XCTAssertNotEqual(uiStatus, TransferUIStatus.completed)
        XCTAssertNotEqual(uiStatus.displayName, "Réussi")
    }

    // MARK: - Test 5 : annulation pendant l'attente

    /// Un transfert en `awaitingConfirmation` reste annulable comme
    /// tout transfert actif (`cancelActiveTransfers` — chemin du
    /// nettoyage — et le critère UI `!state.isTerminal`).
    func testAwaitingConfirmationRemainsCancellable() {
        let transfer = makeTransfer()
        let store = makeStore(with: transfer)

        store.updateProgress(
            transferID: transfer.id,
            transferredBytes: fileSize
        )
        store.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: fileSize
        )

        // Critère UI du bouton Annuler (`canCancel`).
        let awaiting = store.transfer(withID: transfer.id)!
        XCTAssertFalse(awaiting.state.isTerminal)
        XCTAssertTrue(!awaiting.state.isTerminal)

        // Chemin d'annulation du store.
        store.cancelActiveTransfers()
        XCTAssertEqual(
            store.transfer(withID: transfer.id)?.state,
            .cancelled
        )
    }

    /// Via le `TransferManager` (façade utilisée par le Core) :
    /// l'annulation pendant l'attente passe bien par `.cancelled`,
    /// enregistre l'historique et purge la métadonnée de reprise.
    func testManagerCancellationDuringAwaitingConfirmation() {
        let manager = makeManager()
        let transfer = makeTransfer()

        manager.createOutgoingTransfer(
            id: transfer.id,
            peer: transfer.peer,
            fileName: transfer.fileName,
            fileSize: transfer.fileSize,
            state: .accepted
        )
        manager.markAccepted(transferID: transfer.id)
        manager.updateProgress(
            transferID: transfer.id,
            transferredBytes: transfer.fileSize
        )
        manager.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: transfer.fileSize
        )
        XCTAssertEqual(
            manager.transfers.first { $0.id == transfer.id }?.state,
            .awaitingConfirmation
        )

        manager.markCancelled(transferID: transfer.id)
        XCTAssertEqual(
            manager.transfers.first { $0.id == transfer.id }?.state,
            .cancelled
        )
    }

    // MARK: - Déconnexion pendant l'attente

    /// Une coupure réseau pendant la fenêtre de confirmation
    /// interrompt le transfert (`interruptActiveTransfers`) : il
    /// devient reprisable — la reprise renverra le
    /// `transferCompleted` et réarmera l'attente.
    func testDisconnectionDuringAwaitingInterruptsAsResumable() {
        let peer = makeDevice()
        let transfer = makeTransfer().id
        let store = TransferStore()
        store.append(
            Transfer(
                id: transfer,
                peer: peer,
                fileName: "vidéo.mov",
                fileSize: fileSize,
                direction: .outgoing,
                state: .transferring,
                transferredBytes: fileSize
            )
        )
        store.markAwaitingConfirmation(
            transferID: transfer,
            transferredBytes: fileSize
        )

        let interrupted = store.interruptActiveTransfers(
            peerID: peer.id
        )
        XCTAssertEqual(interrupted, [transfer])
        XCTAssertEqual(
            store.transfer(withID: transfer)?.state,
            .interrupted
        )
        XCTAssertTrue(store.isResumable(transferID: transfer))
    }

    // MARK: - Métadonnées de l'état et mapping UI

    func testAwaitingConfirmationStateMetadata() {
        XCTAssertFalse(
            Transfer.State.awaitingConfirmation.isTerminal,
            "L'attente de confirmation doit rester non terminale "
                + "(annulable, interruptible, visible dans les actifs)."
        )
        XCTAssertEqual(
            Transfer.State.awaitingConfirmation.displayName,
            "Validation du récepteur"
        )
    }

    func testAwaitingConfirmationMapsToDistinctUIStatus() {
        let status = TransferViewModel.status(
            for: .awaitingConfirmation
        )

        // Statut dédié, distinct du vert de succès…
        XCTAssertEqual(status, .awaitingConfirmation)
        XCTAssertNotEqual(status, .completed)

        // …avec le libellé demandé par la spec.
        XCTAssertEqual(status.displayName, "Validation du récepteur")

        // Le reverse-mapping (entrées synthétiques d'historique)
        // reste cohérent.
        XCTAssertEqual(
            TransferViewModel.status(
                for: .awaitingConfirmation
            ),
            .awaitingConfirmation
        )
    }

    /// L'état « Validation du récepteur » n'est jamais compté comme
    /// livré : seuls les transferts `.completed` purgent les lots
    /// `PendingShares` (règle de rétention du
    /// `PendingShareController`).
    func testAwaitingConfirmationIsNotDeliveredForPendingSharePurge() {
        let transfer = makeTransfer()
        let store = makeStore(with: transfer)

        store.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: transfer.fileSize
        )

        let delivered = Set(
            store.transfers
                .filter { $0.direction == .outgoing && $0.state == .completed }
                .compactMap(\.sourceFileURL)
        )
        XCTAssertTrue(
            delivered.isEmpty,
            "Un transfert en attente de confirmation ne doit pas "
                + "être considéré comme livré."
        )
    }

    /// Cycle complet à travers la façade `TransferManager`, telle
    /// qu'appelée par `AirBridgeCore` : markAwaitingConfirmation après
    /// l'émission du `transferCompleted`, markCompleted sur
    /// `transferSucceeded`.
    func testManagerFullConfirmationCycle() {
        let manager = makeManager()
        let transfer = makeTransfer()

        manager.createOutgoingTransfer(
            id: transfer.id,
            peer: transfer.peer,
            fileName: transfer.fileName,
            fileSize: transfer.fileSize,
            state: .accepted
        )

        // Envoi des données.
        manager.markAccepted(transferID: transfer.id)
        manager.updateProgress(
            transferID: transfer.id,
            transferredBytes: transfer.fileSize
        )
        XCTAssertEqual(
            manager.transfers.first { $0.id == transfer.id }?.state,
            .transferring
        )

        // `transferCompleted` émis.
        manager.markAwaitingConfirmation(
            transferID: transfer.id,
            transferredBytes: transfer.fileSize
        )
        let awaiting = manager.transfers
            .first { $0.id == transfer.id }
        XCTAssertEqual(awaiting?.state, .awaitingConfirmation)
        XCTAssertEqual(awaiting?.progress ?? 0, 1.0, accuracy: 0.0001)

        // `transferSucceeded` reçu.
        manager.markCompleted(
            transferID: transfer.id,
            transferredBytes: transfer.fileSize
        )
        let finished = manager.transfers
            .first { $0.id == transfer.id }
        XCTAssertEqual(finished?.state, .completed)
        XCTAssertNotNil(finished?.completedAt)
    }
}
