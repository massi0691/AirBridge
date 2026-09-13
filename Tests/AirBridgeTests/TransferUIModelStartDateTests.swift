//
//  TransferUIModelStartDateTests.swift
//  AirBridgeTests
//
//  Tests unitaires du champ `startDate: Date?` ajouté à
//  `TransferUIModel` lors de la phase UX AirDrop-like. Ce champ
//  est utilisé par :
//
//   - la `historyRow` de `TransferView` pour afficher la date
//     relative ("Il y a 5 min", "Hier", "12 mars") à côté de la
//     taille du fichier ;
//   - la `FileActionSheet` pour afficher la date d'envoi/réception
//     dans l'en-tête.
//
//  La projection elle-même (`projection(for:)` et
//  `projection(historyEntry:liveTransfer:)`) est `private`, donc
//  on ne peut pas l'invoquer directement. On vérifie donc le
//  contrat indirectement :
//
//   - on vérifie que `Transfer` (struct Core, publique) porte
//     bien `createdAt` et `startedAt: Date?` ;
//   - on vérifie que `TransferHistoryEntry` (struct Core,
//     publique) porte bien `startDate: Date` ;
//   - on vérifie que l'union `startedAt ?? createdAt` donne le
//     bon résultat dans les deux cas.
//
//  Ce sont des tests de "contrat de surface" : ils protègent
//  contre une régression où l'un des champs serait renommé ou
//  supprimé côté Core, ce qui casserait silencieusement
//  l'affichage de la date.
//
//  Couvre la Phase UX AirDrop-like (affichage de la date de
//  démarrage dans l'historique).
//

import XCTest
@testable import AirBridge


final class TransferUIModelStartDateTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDevice() -> Device {
        Device(
            id: UUID(),
            name: "iPhone de Test",
            model: "iPhone",
            systemVersion: "26.5"
        )
    }

    private func makeTransfer(
        state: Transfer.State,
        fileSize: Int64 = 1_024_000,
        transferredBytes: Int64 = 0,
        startedAt: Date? = nil,
        createdAt: Date = Date()
    ) -> Transfer {
        Transfer(
            id: UUID(),
            peer: makeDevice(),
            fileName: "rapport.pdf",
            fileSize: fileSize,
            direction: .outgoing,
            state: state,
            transferredBytes: transferredBytes,
            createdAt: createdAt,
            startedAt: startedAt
        )
    }

    private func makeHistoryEntry(
        startDate: Date = Date(),
        endDate: Date = Date(),
        status: TransferStatus = .completed
    ) -> TransferHistoryEntry {
        TransferHistoryEntry(
            id: UUID(),
            fileName: "archive.zip",
            fileSize: 5_000_000,
            direction: .sent,
            startDate: startDate,
            endDate: endDate,
            status: status,
            remoteDeviceName: "iPhone de Test",
            remoteDeviceType: "iPhone",
            fileType: "public.data",
            fileCount: 1,
            transferSpeed: 1_500_000,
            sha256: nil
        )
    }

    // MARK: - Transfer: surface de startDate

    /// Le contrat de surface de `Transfer` doit exposer
    /// `createdAt: Date` ET `startedAt: Date?`. Sans ce dernier, la
    /// projection du ViewModel ne peut pas dériver le `startDate`
    /// affiché.
    func testTransferExposesCreatedAt() {
        let now = Date()
        let transfer = makeTransfer(
            state: .transferring,
            createdAt: now
        )
        XCTAssertEqual(
            transfer.createdAt,
            now,
            "Transfer.createdAt doit exposer la date de création."
        )
    }

    /// `Transfer.startedAt` doit être `nil` tant que le transfert
    /// n'a pas été "démarré" côté Core (i.e. accepté par le
    /// récepteur). C'est cet état `nil` qui pousse la projection à
    /// retomber sur `createdAt`.
    func testTransferStartedAtDefaultsToNil() {
        let transfer = makeTransfer(
            state: .requesting,
            startedAt: nil
        )
        XCTAssertNil(
            transfer.startedAt,
            "Transfer.startedAt doit être nil tant que le transfert n'a pas démarré."
        )
    }

    /// Une fois accepté, `Transfer.startedAt` doit être la date
    /// d'acceptation — différente de `createdAt` dans le cas
    /// général (latence d'approbation, mise en file d'attente).
    func testTransferStartedAtCanDifferFromCreatedAt() {
        let created = Date(timeIntervalSince1970: 1_000)
        let started = Date(timeIntervalSince1970: 1_500)
        let transfer = makeTransfer(
            state: .transferring,
            startedAt: started,
            createdAt: created
        )
        XCTAssertEqual(transfer.createdAt, created)
        XCTAssertEqual(transfer.startedAt, started)
        XCTAssertNotEqual(
            transfer.startedAt,
            transfer.createdAt,
            "startedAt et createdAt doivent pouvoir diverger (latence d'acceptation)."
        )
    }

    // MARK: - Logique de fallback (équivalent de la projection)

    /// Le ViewModel fait `startedAt ?? createdAt` pour produire le
    /// `startDate` du `TransferUIModel`. On vérifie directement
    /// cette logique pour s'assurer qu'elle donne le bon résultat
    /// dans les deux cas (sans avoir besoin d'instancier le
    /// ViewModel, qui réclame un `AirBridgeCore` complet).
    func testStartDateFallbackUsesCreatedAtWhenStartedAtIsNil() {
        let created = Date(timeIntervalSince1970: 2_000)
        let transfer = makeTransfer(
            state: .requesting,
            startedAt: nil,
            createdAt: created
        )
        let startDate = transfer.startedAt ?? transfer.createdAt
        XCTAssertEqual(
            startDate,
            created,
            "Quand startedAt == nil, le ViewModel retombe sur createdAt."
        )
    }

    func testStartDatePrefersStartedAtWhenAvailable() {
        let created = Date(timeIntervalSince1970: 2_000)
        let started = Date(timeIntervalSince1970: 2_500)
        let transfer = makeTransfer(
            state: .transferring,
            startedAt: started,
            createdAt: created
        )
        let startDate = transfer.startedAt ?? transfer.createdAt
        XCTAssertEqual(
            startDate,
            started,
            "Quand startedAt est défini, il prime sur createdAt."
        )
    }

    // MARK: - TransferHistoryEntry: startDate obligatoire

    /// `TransferHistoryEntry.startDate` est non optionnel : c'est la
    /// date que la projection utilise pour les entrées purement
    /// historiques (pas de `Transfer` vivant en Core).
    func testHistoryEntryExposesStartDate() {
        let start = Date(timeIntervalSince1970: 3_000)
        let entry = makeHistoryEntry(startDate: start)
        XCTAssertEqual(
            entry.startDate,
            start,
            "TransferHistoryEntry.startDate doit exposer la date de démarrage."
        )
    }

    /// `TransferHistoryEntry` doit être conforme `Hashable` /
    /// `Equatable` (utilisé par le `sorted` dans
    /// `TransferViewModel.history`). C'est un test de surface qui
    /// protège contre un retrait accidentel de la conformance.
    func testHistoryEntryIsEquatable() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 3_000)
        let end = Date(timeIntervalSince1970: 3_500)
        let a = TransferHistoryEntry(
            id: id,
            fileName: "f.pdf",
            fileSize: 100,
            direction: .sent,
            startDate: start,
            endDate: end,
            status: .completed,
            remoteDeviceName: "Device",
            remoteDeviceType: "iPhone",
            fileType: "public.data",
            fileCount: 1,
            transferSpeed: 0,
            sha256: nil
        )
        let b = TransferHistoryEntry(
            id: id,
            fileName: "f.pdf",
            fileSize: 100,
            direction: .sent,
            startDate: start,
            endDate: end,
            status: .completed,
            remoteDeviceName: "Device",
            remoteDeviceType: "iPhone",
            fileType: "public.data",
            fileCount: 1,
            transferSpeed: 0,
            sha256: nil
        )
        XCTAssertEqual(
            a,
            b,
            "TransferHistoryEntry doit être Equatable."
        )
    }

    // MARK: - Intégration : ordre d'affichage

    /// Le tri de l'historique se fait par `startDate` décroissant.
    /// On vérifie que le contrat de tri utilisé par le ViewModel
    /// (`$0.startDate > $1.startDate`) donne bien l'ordre attendu
    /// avec deux entrées.
    func testHistorySortingByStartDateDescending() {
        let older = makeHistoryEntry(
            startDate: Date(timeIntervalSince1970: 1_000)
        )
        let newer = makeHistoryEntry(
            startDate: Date(timeIntervalSince1970: 2_000)
        )
        let entries = [older, newer]
        let sorted = entries.sorted { $0.startDate > $1.startDate }
        XCTAssertEqual(
            sorted.first?.id,
            newer.id,
            "Le plus récent doit apparaître en premier."
        )
        XCTAssertEqual(
            sorted.last?.id,
            older.id,
            "Le plus ancien doit apparaître en dernier."
        )
    }
}
