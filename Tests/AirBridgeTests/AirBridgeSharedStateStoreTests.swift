//
//  AirBridgeSharedStateStoreTests.swift
//  AirBridgeTests
//
//  Tests de l'état partagé app ↔ extensions (App Group) :
//   - aller-retour `AirBridgeSharedState` (dernier appareil connecté) ;
//   - publication session ouverte / fermée ;
//   - directive d'envoi ciblé : écriture, lecture, consommation
//     unique.
//
//  Le conteneur est redirigé vers un dossier temporaire via
//  `AirBridgeAppGroup.containerURLOverride` (aucun App Group réel
//  n'est requis en environnement de test).
//

import XCTest
@testable import AirBridge

final class AirBridgeSharedStateStoreTests: XCTestCase {

    private var tempContainer: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AirBridgeSharedStateTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempContainer,
            withIntermediateDirectories: true
        )
        AirBridgeAppGroup.containerURLOverride = tempContainer
    }

    override func tearDownWithError() throws {
        AirBridgeAppGroup.containerURLOverride = nil
        if let tempContainer {
            try? FileManager.default.removeItem(at: tempContainer)
        }
        tempContainer = nil
        try super.tearDownWithError()
    }

    // MARK: - AirBridgeSharedState

    func testReadReturnsNilWhenNothingPublished() {
        XCTAssertNil(
            AirBridgeSharedStateStore.read(),
            "Sans publication préalable, aucun état."
        )
    }

    func testWriteReadRoundTrip() {
        let peerID = UUID()
        let written = AirBridgeSharedStateStore.write(
            AirBridgeSharedState(
                lastPeer: AirBridgeSharedPeer(
                    id: peerID,
                    name: "iPhone de Massi",
                    model: "iPhone",
                    sessionOpen: false
                ),
                connectedPeerID: nil
            )
        )
        XCTAssertTrue(written, "L'écriture doit réussir dans le conteneur de test.")

        let read = AirBridgeSharedStateStore.read()
        XCTAssertEqual(read?.lastPeer?.id, peerID)
        XCTAssertEqual(read?.lastPeer?.name, "iPhone de Massi")
        XCTAssertEqual(read?.lastPeer?.sessionOpen, false)
        XCTAssertNil(read?.connectedPeerID)
    }

    func testPublishSessionOpenedMarksConnected() {
        let peerID = UUID()
        AirBridgeSharedStateStore.publishSessionOpened(
            peerID: peerID,
            name: "Mac du test",
            model: "Mac"
        )

        let read = AirBridgeSharedStateStore.read()
        XCTAssertEqual(read?.connectedPeerID, peerID)
        XCTAssertEqual(read?.lastPeer?.id, peerID)
        XCTAssertEqual(read?.lastPeer?.sessionOpen, true)
    }

    func testPublishSessionClosedKeepsLastPeer() {
        let peerID = UUID()
        AirBridgeSharedStateStore.publishSessionOpened(
            peerID: peerID,
            name: "iPhone",
            model: "iPhone"
        )
        AirBridgeSharedStateStore.publishSessionClosed(peerID: peerID)

        let read = AirBridgeSharedStateStore.read()
        XCTAssertEqual(
            read?.lastPeer?.id,
            peerID,
            "Le dernier appareil connecté reste proposé après déconnexion."
        )
        XCTAssertEqual(read?.lastPeer?.sessionOpen, false)
        XCTAssertNil(
            read?.connectedPeerID,
            "La session est bien marquée fermée."
        )
    }

    func testPublishSessionClosedIgnoresUnrelatedPeer() {
        let connectedID = UUID()
        AirBridgeSharedStateStore.publishSessionOpened(
            peerID: connectedID,
            name: "iPhone",
            model: "iPhone"
        )
        AirBridgeSharedStateStore.publishSessionClosed(peerID: UUID())

        let read = AirBridgeSharedStateStore.read()
        XCTAssertEqual(read?.connectedPeerID, connectedID)
        XCTAssertEqual(read?.lastPeer?.sessionOpen, true)
    }

    // MARK: - Directive d'envoi ciblé

    func testDirectiveWriteReadRoundTrip() {
        let batchID = UUID().uuidString
        let peerID = UUID()
        let directive = AirBridgeSendDirective(
            batchID: batchID,
            targetPeerID: peerID,
            targetPeerName: "iPhone de Massi",
            createdAt: Date(timeIntervalSince1970: 1_758_000_000)
        )

        XCTAssertTrue(AirBridgeSendDirectiveStore.write(directive))
        XCTAssertEqual(
            AirBridgeSendDirectiveStore.read(batchID: batchID),
            directive
        )
    }

    func testDirectiveConsumeIsOneShot() {
        let batchID = UUID().uuidString
        let directive = AirBridgeSendDirective(
            batchID: batchID,
            targetPeerID: UUID(),
            targetPeerName: "iPhone",
            createdAt: Date()
        )
        AirBridgeSendDirectiveStore.write(directive)

        XCTAssertEqual(
            AirBridgeSendDirectiveStore.consume(batchID: batchID),
            directive,
            "La première consommation rend la directive."
        )
        XCTAssertNil(
            AirBridgeSendDirectiveStore.consume(batchID: batchID),
            "La directive est consommée UNE seule fois — pas de double envoi."
        )
        XCTAssertNil(
            AirBridgeSendDirectiveStore.read(batchID: batchID)
        )
    }

    func testDirectiveReadForUnknownBatchIsNil() {
        XCTAssertNil(
            AirBridgeSendDirectiveStore.read(
                batchID: UUID().uuidString
            )
        )
    }

    func testDirectiveRemoveAllClearsFolder() {
        let first = UUID().uuidString
        let second = UUID().uuidString
        AirBridgeSendDirectiveStore.write(
            AirBridgeSendDirective(
                batchID: first,
                targetPeerID: UUID(),
                targetPeerName: "A",
                createdAt: Date()
            )
        )
        AirBridgeSendDirectiveStore.write(
            AirBridgeSendDirective(
                batchID: second,
                targetPeerID: UUID(),
                targetPeerName: "B",
                createdAt: Date()
            )
        )

        AirBridgeSendDirectiveStore.removeAll()

        XCTAssertNil(AirBridgeSendDirectiveStore.read(batchID: first))
        XCTAssertNil(AirBridgeSendDirectiveStore.read(batchID: second))
    }
}
