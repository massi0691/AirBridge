//
//  PendingApprovalCoordinatorTests.swift
//  AirBridgeTests
//

import Network
import XCTest

@testable import AirBridge

@MainActor
final class PendingApprovalCoordinatorTests: XCTestCase {

    // MARK: - Fenêtre de coalescence

    /// Fenêtre courte pour garder les tests rapides, et attente
    /// nettement plus longue pour éviter toute instabilité.
    private let window = Duration.milliseconds(50)
    private let waitForWindow = Duration.milliseconds(300)

    // MARK: - Fabriques

    private func makeConnection() -> NWConnection {
        NWConnection(
            host: "127.0.0.1",
            port: 9999,
            using: .tcp
        )
    }

    private func makeDevice(
        name: String = "Mac de test"
    ) -> Device {
        Device(
            id: UUID(),
            name: name,
            model: "Mac",
            systemVersion: "26.5"
        )
    }

    private func makeRequest(
        sender: Device,
        connection: NWConnection,
        fileName: String,
        fileSize: Int64
    ) -> PendingTransferRequest {
        PendingTransferRequest(
            sender: sender,
            request: TransferRequestPayload(
                fileName: fileName,
                fileSize: fileSize
            ),
            connection: connection
        )
    }

    // MARK: - Autorisation groupée

    func testThreeRequestsInWindowProduceASinglePresentableBatch() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        var readyCount = 0
        coordinator.onReadyChanged = { readyCount += 1 }

        let sender = makeDevice()
        let connection = makeConnection()

        for index in 1...3 {
            coordinator.append(
                makeRequest(
                    sender: sender,
                    connection: connection,
                    fileName: "fichier-\(index).bin",
                    fileSize: Int64(index) * 1_000
                )
            )
        }

        // Avant la fin de la fenêtre, rien n'est présentable.
        XCTAssertNil(coordinator.presentableBatch)
        XCTAssertEqual(coordinator.requests.count, 3)

        try await Task.sleep(for: waitForWindow)

        let batch = try XCTUnwrap(coordinator.presentableBatch)
        XCTAssertEqual(batch.fileCount, 3)
        XCTAssertEqual(batch.totalSize, 6_000)
        XCTAssertEqual(
            batch.fileNames,
            ["fichier-1.bin", "fichier-2.bin", "fichier-3.bin"]
        )

        // Une seule demande devient présentable pour les 3 fichiers.
        XCTAssertEqual(readyCount, 1)
    }

    func testSingleRequestStillProducesOneBatch() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        coordinator.append(
            makeRequest(
                sender: makeDevice(),
                connection: makeConnection(),
                fileName: "seul.pdf",
                fileSize: 4_096
            )
        )

        try await Task.sleep(for: waitForWindow)

        let batch = try XCTUnwrap(coordinator.presentableBatch)
        XCTAssertEqual(batch.fileCount, 1)
        XCTAssertEqual(batch.totalSize, 4_096)
    }

    func testDuplicateTransferIDIsIgnored() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        let sender = makeDevice()
        let connection = makeConnection()
        let payload = TransferRequestPayload(
            fileName: "doublon.bin",
            fileSize: 512
        )

        let request = PendingTransferRequest(
            sender: sender,
            request: payload,
            connection: connection
        )

        coordinator.append(request)
        coordinator.append(request)

        try await Task.sleep(for: waitForWindow)

        let batch = try XCTUnwrap(coordinator.presentableBatch)
        XCTAssertEqual(batch.fileCount, 1)
    }

    func testRequestFromAnotherSenderReplacesTheBatch() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        let firstSender = makeDevice(name: "Premier")
        let firstConnection = makeConnection()

        coordinator.append(
            makeRequest(
                sender: firstSender,
                connection: firstConnection,
                fileName: "premier.bin",
                fileSize: 100
            )
        )

        let secondSender = makeDevice(name: "Second")
        let secondConnection = makeConnection()

        coordinator.append(
            makeRequest(
                sender: secondSender,
                connection: secondConnection,
                fileName: "second.bin",
                fileSize: 200
            )
        )

        try await Task.sleep(for: waitForWindow)

        let batch = try XCTUnwrap(coordinator.presentableBatch)
        XCTAssertEqual(batch.fileCount, 1)
        XCTAssertEqual(batch.sender.id, secondSender.id)
        XCTAssertEqual(batch.fileNames, ["second.bin"])
    }

    /// Un fichier qui arrive après l'affichage rejoint le lot présenté
    /// au lieu de rouvrir une nouvelle demande d'autorisation.
    func testRequestArrivingAfterReadyJoinsTheDisplayedBatch() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        let sender = makeDevice()
        let connection = makeConnection()

        coordinator.append(
            makeRequest(
                sender: sender,
                connection: connection,
                fileName: "premier.bin",
                fileSize: 1_000
            )
        )

        try await Task.sleep(for: waitForWindow)

        let firstBatchID = try XCTUnwrap(
            coordinator.presentableBatch
        ).id

        coordinator.append(
            makeRequest(
                sender: sender,
                connection: connection,
                fileName: "tardif.bin",
                fileSize: 500
            )
        )

        let batch = try XCTUnwrap(coordinator.presentableBatch)
        XCTAssertEqual(batch.id, firstBatchID)
        XCTAssertEqual(batch.fileCount, 2)
        XCTAssertEqual(batch.totalSize, 1_500)
    }

    /// Remplacer le lot doit notifier immédiatement, sinon la copie
    /// publiée par le cœur reste sur l'ancien lot et la sheet affichée
    /// décrit des fichiers qui ne sont plus ceux qui seraient acceptés.
    func testReplacingTheBatchNotifiesImmediately() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        coordinator.append(
            makeRequest(
                sender: makeDevice(name: "Premier"),
                connection: makeConnection(),
                fileName: "premier.bin",
                fileSize: 100
            )
        )

        try await Task.sleep(for: waitForWindow)
        XCTAssertNotNil(coordinator.presentableBatch)

        var notified = false
        coordinator.onReadyChanged = { notified = true }

        coordinator.append(
            makeRequest(
                sender: makeDevice(name: "Second"),
                connection: makeConnection(),
                fileName: "second.bin",
                fileSize: 200
            )
        )

        XCTAssertTrue(
            notified,
            "Le remplacement du lot n'a pas été signalé"
        )
        XCTAssertNil(
            coordinator.presentableBatch,
            "Le nouveau lot ne doit pas être présentable avant la fin de sa fenêtre"
        )
    }

    func testClearRemovesTheBatchAndNotifies() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        coordinator.append(
            makeRequest(
                sender: makeDevice(),
                connection: makeConnection(),
                fileName: "a.bin",
                fileSize: 10
            )
        )

        try await Task.sleep(for: waitForWindow)
        XCTAssertNotNil(coordinator.presentableBatch)

        var notified = false
        coordinator.onReadyChanged = { notified = true }

        coordinator.clear()

        XCTAssertTrue(notified)
        XCTAssertNil(coordinator.presentableBatch)
        XCTAssertTrue(coordinator.requests.isEmpty)
    }

    /// Après un `clear`, la fenêtre annulée ne doit pas rendre
    /// présentable un lot qui n'existe plus.
    func testClearCancelsThePendingWindow() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        coordinator.append(
            makeRequest(
                sender: makeDevice(),
                connection: makeConnection(),
                fileName: "annule.bin",
                fileSize: 10
            )
        )

        coordinator.clear()

        try await Task.sleep(for: waitForWindow)

        XCTAssertNil(coordinator.presentableBatch)
        XCTAssertNil(coordinator.batch)
    }

    func testRemoveSomeTransferIDsKeepsTheRest() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        let sender = makeDevice()
        let connection = makeConnection()

        let requests = (1...3).map { index in
            makeRequest(
                sender: sender,
                connection: connection,
                fileName: "fichier-\(index).bin",
                fileSize: 100
            )
        }

        requests.forEach(coordinator.append)

        try await Task.sleep(for: waitForWindow)

        coordinator.remove(
            transferIDs: [requests[0].id]
        )

        let batch = try XCTUnwrap(coordinator.presentableBatch)
        XCTAssertEqual(batch.fileCount, 2)
        XCTAssertEqual(
            batch.fileNames,
            ["fichier-2.bin", "fichier-3.bin"]
        )
    }

    func testRemovingEveryTransferIDClearsTheBatch() async throws {
        let coordinator = PendingApprovalCoordinator(
            coalescingWindow: window
        )

        let sender = makeDevice()
        let connection = makeConnection()

        let requests = (1...2).map { index in
            makeRequest(
                sender: sender,
                connection: connection,
                fileName: "fichier-\(index).bin",
                fileSize: 100
            )
        }

        requests.forEach(coordinator.append)

        try await Task.sleep(for: waitForWindow)

        coordinator.remove(
            transferIDs: Set(requests.map(\.id))
        )

        XCTAssertNil(coordinator.presentableBatch)
        XCTAssertNil(coordinator.batch)
    }

    // MARK: - Lot

    func testBatchRejectsRequestFromAnotherConnection() {
        let sender = makeDevice()

        let batch = PendingTransferBatch(
            request: makeRequest(
                sender: sender,
                connection: makeConnection(),
                fileName: "a.bin",
                fileSize: 1
            )
        )

        let otherConnectionRequest = makeRequest(
            sender: sender,
            connection: makeConnection(),
            fileName: "b.bin",
            fileSize: 1
        )

        XCTAssertFalse(
            batch.accepts(otherConnectionRequest)
        )
    }

    func testEachBatchHasADistinctIdentifier() {
        let sender = makeDevice()
        let connection = makeConnection()

        let first = PendingTransferBatch(
            request: makeRequest(
                sender: sender,
                connection: connection,
                fileName: "a.bin",
                fileSize: 1
            )
        )

        let second = PendingTransferBatch(
            request: makeRequest(
                sender: sender,
                connection: connection,
                fileName: "b.bin",
                fileSize: 1
            )
        )

        XCTAssertNotEqual(first.id, second.id)
    }
}
