//
//  TransferHistoryStoreTests.swift
//  AirBridgeTests
//
//  Tests directs du magasin d'historique des transferts.
//
//  L'historique est ce que l'utilisateur voit dans l'onglet Transferts
//  une fois un échange terminé, et ce que les filtres (sens, statut)
//  parcourent. Jusqu'ici il n'était testé qu'indirectement via les
//  ViewModels : ces tests figent le tri, le plafond de 100 entrées et
//  le filtrage indépendamment de l'UI.
//

import XCTest
@testable import AirBridge

@MainActor
final class TransferHistoryStoreTests: XCTestCase {

    private static let bookmarkKey = "airbridge.received-folder-bookmark"

    private func makeEntry(
        id: UUID = UUID(),
        fileName: String = "rapport.pdf",
        fileSize: Int64 = 1024,
        direction: TransferDirection = .sent,
        startDate: Date,
        status: TransferStatus = .completed,
        remoteDeviceName: String = "iPhone de Test",
        sha256: String? = nil
    ) -> TransferHistoryEntry {
        TransferHistoryEntry(
            id: id,
            fileName: fileName,
            fileSize: fileSize,
            direction: direction,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1),
            status: status,
            remoteDeviceName: remoteDeviceName,
            remoteDeviceType: "iPhone",
            fileType: "pdf",
            fileCount: 1,
            transferSpeed: 1.0,
            sha256: sha256
        )
    }

    /// Le magasin persiste dans le conteneur partagé : chaque test
    /// repart d'un état vide pour que les décomptes soient déterministes.
    private func makeStore() -> TransferHistoryStore {
        let store = TransferHistoryStore()
        store.clearAll()
        return store
    }

    // MARK: - Ajout et tri

    func testAddEntryStoresIt() {
        let store = makeStore()
        let entry = makeEntry(startDate: Date())

        store.addEntry(entry)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, entry.id)
    }

    func testEntriesAreSortedNewestFirst() {
        let store = makeStore()
        let old = makeEntry(fileName: "ancien.pdf", startDate: Date().addingTimeInterval(-3600))
        let recent = makeEntry(fileName: "recent.pdf", startDate: Date())
        let middle = makeEntry(fileName: "moyen.pdf", startDate: Date().addingTimeInterval(-60))

        store.addEntry(old)
        store.addEntry(recent)
        store.addEntry(middle)

        XCTAssertEqual(store.entries.map(\.fileName), ["recent.pdf", "moyen.pdf", "ancien.pdf"])
    }

    // MARK: - Plafond

    func testHistoryCapsAt100Entries() {
        let store = makeStore()
        let base = Date()

        for index in 0..<105 {
            store.addEntry(
                makeEntry(
                    fileName: "fichier-\(index).pdf",
                    startDate: base.addingTimeInterval(Double(index))
                )
            )
        }

        XCTAssertEqual(store.entries.count, 100)
        // Ce sont les plus récents qui survivent.
        XCTAssertEqual(store.entries.first?.fileName, "fichier-104.pdf")
    }

    // MARK: - Suppression

    func testRemoveEntry() {
        let store = makeStore()
        let target = makeEntry(fileName: "cible.pdf", startDate: Date())
        let other = makeEntry(fileName: "autre.pdf", startDate: Date().addingTimeInterval(-60))

        store.addEntry(target)
        store.addEntry(other)
        store.removeEntry(id: target.id)

        XCTAssertEqual(store.entries.map(\.fileName), ["autre.pdf"])
    }

    func testRemoveUnknownEntryIsNoop() {
        let store = makeStore()
        let entry = makeEntry(startDate: Date())
        store.addEntry(entry)

        store.removeEntry(id: UUID())

        XCTAssertEqual(store.entries.count, 1)
    }

    func testClearAllEmptiesHistory() {
        let store = makeStore()
        store.addEntry(makeEntry(startDate: Date()))
        store.addEntry(makeEntry(startDate: Date().addingTimeInterval(-60)))

        store.clearAll()

        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Filtres

    func testFilteredEntriesByDirection() {
        let store = makeStore()
        let sent = makeEntry(fileName: "envoye.pdf", direction: .sent, startDate: Date())
        let received = makeEntry(fileName: "recu.pdf", direction: .received, startDate: Date())

        store.addEntry(sent)
        store.addEntry(received)

        let sentOnly = store.filteredEntries(direction: .sent, status: nil)
        XCTAssertEqual(sentOnly.map(\.fileName), ["envoye.pdf"])

        let receivedOnly = store.filteredEntries(direction: .received, status: nil)
        XCTAssertEqual(receivedOnly.map(\.fileName), ["recu.pdf"])
    }

    func testFilteredEntriesByStatus() {
        let store = makeStore()
        let done = makeEntry(fileName: "ok.pdf", startDate: Date(), status: .completed)
        let failed = makeEntry(fileName: "ko.pdf", startDate: Date(), status: .failed)
        let cancelled = makeEntry(fileName: "stop.pdf", startDate: Date(), status: .cancelled)

        store.addEntry(done)
        store.addEntry(failed)
        store.addEntry(cancelled)

        let failedOnly = store.filteredEntries(direction: nil, status: .failed)
        XCTAssertEqual(failedOnly.map(\.fileName), ["ko.pdf"])
    }

    func testFilteredEntriesCombinesDirectionAndStatus() {
        let store = makeStore()
        let a = makeEntry(fileName: "a.pdf", direction: .sent, startDate: Date(), status: .completed)
        let b = makeEntry(fileName: "b.pdf", direction: .sent, startDate: Date(), status: .failed)
        let c = makeEntry(fileName: "c.pdf", direction: .received, startDate: Date(), status: .completed)

        store.addEntry(a)
        store.addEntry(b)
        store.addEntry(c)

        let result = store.filteredEntries(direction: .sent, status: .completed)
        XCTAssertEqual(result.map(\.fileName), ["a.pdf"])
    }

    func testFilteredEntriesWithoutFiltersReturnsAllSorted() {
        let store = makeStore()
        let old = makeEntry(fileName: "ancien.pdf", startDate: Date().addingTimeInterval(-3600))
        let recent = makeEntry(fileName: "recent.pdf", startDate: Date())

        store.addEntry(old)
        store.addEntry(recent)

        let all = store.filteredEntries(direction: nil, status: nil)
        XCTAssertEqual(all.map(\.fileName), ["recent.pdf", "ancien.pdf"])
        XCTAssertEqual(all.count, store.entries.count)
    }

    // MARK: - Persistance

    func testHistorySurvivesReload() {
        let first = TransferHistoryStore()
        first.clearAll()
        first.addEntry(makeEntry(fileName: "persistant.pdf", startDate: Date()))

        let reloaded = TransferHistoryStore()
        XCTAssertEqual(reloaded.entries.map(\.fileName), ["persistant.pdf"])
    }

    func testCorruptHistoryFallsBackToEmpty() throws {
        // Réparer le conteneur à la fin du test : on ne laisse pas de
        // fichier corrompu derrière soi.
        let first = TransferHistoryStore()
        first.clearAll()

        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        try Data("ce n'est pas du json".utf8).write(to: docs.appendingPathComponent("transfer_history.json"))

        let reloaded = TransferHistoryStore()
        XCTAssertTrue(reloaded.entries.isEmpty)

        reloaded.clearAll()
    }
}
