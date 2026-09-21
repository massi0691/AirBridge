//
//  IncomingInterruptionStateTests.swift
//  AirBridge
//
//  Test de non-régression : une réception interrompue ne doit jamais
//  revenir à « En cours » (`.transferring`).
//
//  Symptôme observé : après une coupure de session, l'iPhone affichait un
//  transfert « En cours » figé à 0 %, impossible à reprendre. La cause :
//  `IncomingTransferManager.interruptTransfer` terminait par
//  `store.updateProgress(...)`, qui **force** l'état `.transferring`
//  (c'est son rôle pendant un flux de chunks). Comme `AirBridgeCore`
//  marquait `.interrupted` avant — ou comme `interruptActiveTransfers`
//  l'avait déjà fait sur fermeture de session — l'appel suivant
//  ressuscitait le transfert dans un état actif.
//
//  Conséquences de la résurrection :
//    - la campagne de reprise automatique ne sélectionne que les états
//      `.interrupted`, donc le transfert n'était plus jamais repris ;
//    - `resumeIncoming` exige `store.isResumable`, donc la reprise
//      manuelle échouait aussi ;
//    - l'UI restait sur « En cours » sans qu'aucun octet n'arrive.
//
//  Le fix : `interruptTransfer` appelle `store.markInterrupted`, qui pose
//  `.interrupted` sans toucher au caractère non terminal de l'état.
//

import XCTest
@testable import AirBridge

@MainActor
final class IncomingInterruptionStateTests: XCTestCase {

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

    /// Prépare une réception acceptée par l'utilisateur, exactement comme
    /// le fait le pipeline après un `transferRequest` suivi d'un
    /// `transferAccepted`.
    private func makeAcceptedIncomingTransfer(
        on manager: TransferManager,
        fileSize: Int64 = 4_194_304
    ) async throws -> (transferID: UUID, sender: Device) {
        let sender = makePeer()
        let transferID = UUID()

        let outcome = await manager.createIncomingTransfer(
            request: TransferRequestPayload(
                transferID: transferID,
                fileName: "interruption-state.bin",
                fileSize: fileSize
            ),
            sender: sender
        )
        XCTAssertEqual(
            outcome, .accepted,
            "La réception doit être préparée avant d'être interrompue"
        )

        manager.markAccepted(transferID: transferID)

        let state = try XCTUnwrap(state(of: transferID, in: manager))
        XCTAssertEqual(
            state, .accepted,
            "Précondition : le transfert doit être accepté avant l'interruption"
        )

        return (transferID, sender)
    }

    private func state(
        of transferID: UUID,
        in manager: TransferManager
    ) -> Transfer.State? {
        manager.transfers.first { $0.id == transferID }?.state
    }

    // MARK: - Régression : résurrection d'une réception interrompue

    /// Séquence exacte de `AirBridgeCore.interruptStalledIncomingTransfer` :
    /// fermeture du writer, puis persistance de la métadonnée de reprise.
    /// L'état final doit être `.interrupted` — jamais `.transferring`.
    func testStallInterruptionLeavesTheReceptionInterrupted() async throws {
        let manager = makeTransferManager()
        let (transferID, _) = try await makeAcceptedIncomingTransfer(on: manager)
        defer { cleanupPartialFiles(for: transferID) }

        manager.interruptIncomingTransfer(transferID: transferID)
        manager.markInterrupted(
            transferID: transferID,
            transferredBytes: manager.incomingPartialFileBytes(transferID: transferID),
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        let finalState = try XCTUnwrap(state(of: transferID, in: manager))
        XCTAssertEqual(
            finalState, .interrupted,
            "Une réception interrompue doit rester « Interrompu » (\(finalState.displayName))"
        )
        XCTAssertFalse(manager.isTerminal(transferID: transferID))
        XCTAssertTrue(manager.hasTransfer(transferID: transferID))
    }

    /// Cas rapporté par le terrain : la session tombe, `AirBridgeCore`
    /// marque tous les transferts actifs du pair `.interrupted`, puis le
    /// chemin de fermeture du writer (`interruptTransfer`) repasse derrière.
    /// Avant le fix, ce second appel réécrivait `.transferring` et le
    /// transfert n'était plus jamais repris.
    func testWriterInterruptionAfterSessionCloseDoesNotResurrectTheTransfer() async throws {
        let manager = makeTransferManager()
        let (transferID, sender) = try await makeAcceptedIncomingTransfer(on: manager)
        defer { cleanupPartialFiles(for: transferID) }

        // 1. Fermeture de session : interruption en masse du pair.
        let interrupted = manager.interruptActiveTransfers(
            peerID: sender.id,
            peerName: sender.name,
            protocolVersion: ProtocolCompatibility.currentVersion
        )
        XCTAssertEqual(
            interrupted, [transferID],
            "La fermeture de session doit interrompre la réception en cours"
        )
        XCTAssertEqual(state(of: transferID, in: manager), .interrupted)

        // 2. Le writer est fermé ensuite (timeout d'activité tardif,
        //    nettoyage, ou second appel du Core).
        manager.interruptIncomingTransfer(transferID: transferID)

        XCTAssertEqual(
            state(of: transferID, in: manager), .interrupted,
            "La fermeture du writer ne doit pas ramener un transfert interrompu à « En cours »"
        )
    }

    /// Un appel répété est idempotent sur l'état : rien ne doit pouvoir
    /// faire repasser une réception interrompue par un état actif.
    func testRepeatedInterruptionIsIdempotent() async throws {
        let manager = makeTransferManager()
        let (transferID, _) = try await makeAcceptedIncomingTransfer(on: manager)
        defer { cleanupPartialFiles(for: transferID) }

        for _ in 0..<3 {
            manager.interruptIncomingTransfer(transferID: transferID)
            XCTAssertEqual(
                state(of: transferID, in: manager), .interrupted,
                "Chaque interruption doit maintenir l'état `.interrupted`"
            )
        }
    }

    /// L'interruption n'est ni une annulation ni un échec : le transfert
    /// reste non terminal et visible dans la liste active, sinon la
    /// reprise n'aurait plus rien à reprendre.
    func testInterruptionIsNeitherCancellationNorFailure() async throws {
        let manager = makeTransferManager()
        let (transferID, _) = try await makeAcceptedIncomingTransfer(on: manager)
        defer { cleanupPartialFiles(for: transferID) }

        manager.interruptIncomingTransfer(transferID: transferID)

        let finalState = try XCTUnwrap(state(of: transferID, in: manager))
        XCTAssertNotEqual(finalState, .cancelled)
        XCTAssertNotEqual(finalState, .failed)
        XCTAssertNotEqual(finalState, .completed)
        XCTAssertFalse(
            finalState.isTerminal,
            "`.interrupted` est non terminal : le transfert doit rester reprisable"
        )
        XCTAssertEqual(
            manager.transfers.activeTransfers.map(\.id), [transferID],
            "Le transfert interrompu doit rester dans la liste active"
        )
    }

    /// Contraste : l'annulation volontaire reste terminale. L'interruption
    /// ne doit pas avoir hérité de sa sémantique en changeant d'appel
    /// d'état.
    func testCancellationRemainsTerminal() async throws {
        let manager = makeTransferManager()
        let (transferID, _) = try await makeAcceptedIncomingTransfer(on: manager)
        defer { cleanupPartialFiles(for: transferID) }

        manager.cancelIncomingTransfer(transferID: transferID)
        manager.markCancelled(transferID: transferID)

        XCTAssertEqual(state(of: transferID, in: manager), .cancelled)
        XCTAssertTrue(manager.isTerminal(transferID: transferID))
    }
}
