//
//  TransferHistoryMultiDeleteTests.swift
//  AirBridgeTests
//
//  Tests unitaires de la suppression groupée de l'historique exposée
//  par `TransferViewModel.removeFromHistory(entryIDs:)` (sélection
//  multiple de l'onglet « Terminés » / filtre « Historique » macOS).
//
//  Le store sous-jacent (`TransferHistoryStore`) persiste dans
//  `Documents/transfer_history.json` : chaque test nettoie les entrées
//  qu'il ajoute (et restaure l'éventuel contenu préexistant) pour ne
//  pas polluer l'hôte de test.
//

import XCTest
@testable import AirBridge

@MainActor
final class TransferHistoryMultiDeleteTests: XCTestCase {

    // MARK: - Fixtures

    private func makeCore() -> AirBridgeCore {
        let localDevice = Device(
            id: UUID(),
            name: "iPhone de Test",
            model: "iPhone",
            systemVersion: "26.5"
        )
        let bonjour = BonjourService(localDevice: localDevice)
        let router = MessageRouter()
        let pairingStore = PairingStore()
        let connectionManager = ConnectionManager(
            localDevice: localDevice,
            messageRouter: router,
            pairingStore: pairingStore
        )
        let historyStore = TransferHistoryStore()
        let transferManager = TransferManager(
            receivedFolderStore: ReceivedFolderStore(),
            localDevice: localDevice,
            historyStore: historyStore
        )
        return AirBridgeCore(
            bonjourService: bonjour,
            connectionManager: connectionManager,
            messageRouter: router,
            transferManager: transferManager,
            receivedFolderStore: ReceivedFolderStore(),
            transferHistoryStore: historyStore,
            pairingStore: pairingStore
        )
    }

    private func makeEntry(
        fileName: String
    ) -> TransferHistoryEntry {
        TransferHistoryEntry(
            id: UUID(),
            fileName: fileName,
            fileSize: 1024,
            direction: .sent,
            startDate: Date(),
            endDate: Date(),
            status: .completed,
            remoteDeviceName: "Mac de Test",
            remoteDeviceType: "Mac",
            fileType: "image",
            fileCount: 1,
            transferSpeed: 12.5,
            sha256: nil
        )
    }

    // MARK: - Suppression groupée

    func testRemoveFromHistoryRemovesOnlySelectedEntries() {
        let core = makeCore()
        let store = core.transferHistoryStore
        let baselineIDs = Set(store.entries.map(\.id))

        let keep = makeEntry(fileName: "keep.pdf")
        let deleteA = makeEntry(fileName: "a.jpg")
        let deleteB = makeEntry(fileName: "b.jpg")
        store.addEntry(keep)
        store.addEntry(deleteA)
        store.addEntry(deleteB)

        let viewModel = TransferViewModel(core: core)
        viewModel.removeFromHistory(entryIDs: [deleteA.id, deleteB.id])

        let remaining = Set(store.entries.map(\.id))
        XCTAssertFalse(
            remaining.contains(deleteA.id),
            "La première entrée sélectionnée doit être supprimée."
        )
        XCTAssertFalse(
            remaining.contains(deleteB.id),
            "La seconde entrée sélectionnée doit être supprimée."
        )
        XCTAssertTrue(
            remaining.contains(keep.id),
            "Une entrée non sélectionnée ne doit pas être supprimée."
        )
        XCTAssertEqual(
            remaining,
            baselineIDs.union([keep.id]),
            "Seules les entrées sélectionnées doivent manquer à l'appel."
        )

        // Nettoyage.
        viewModel.removeFromHistory(entryIDs: [keep.id])
    }

    func testRemoveFromHistoryWithUnknownIDsIsHarmless() {
        let core = makeCore()
        let store = core.transferHistoryStore
        let entry = makeEntry(fileName: "solo.jpg")
        store.addEntry(entry)
        let before = store.entries

        let viewModel = TransferViewModel(core: core)
        viewModel.removeFromHistory(entryIDs: [UUID()])

        XCTAssertEqual(
            store.entries,
            before,
            "Un identifiant inconnu ne doit supprimer aucune entrée."
        )

        // Nettoyage.
        viewModel.removeFromHistory(entryIDs: [entry.id])
    }

    func testClearHistoryEmptiesEverything() {
        let core = makeCore()
        let store = core.transferHistoryStore
        // Sauvegarde du contenu préexistant (le store écrit sur disque)
        // pour le restaurer après le test.
        let baseline = store.entries

        store.addEntry(makeEntry(fileName: "x.jpg"))
        store.addEntry(makeEntry(fileName: "y.jpg"))
        XCTAssertFalse(store.entries.isEmpty)

        let viewModel = TransferViewModel(core: core)
        viewModel.clearHistory()

        XCTAssertTrue(
            store.entries.isEmpty,
            "clearHistory doit vider entièrement le store."
        )

        // Restauration de l'état initial de l'hôte.
        for entry in baseline {
            store.addEntry(entry)
        }
    }
}
