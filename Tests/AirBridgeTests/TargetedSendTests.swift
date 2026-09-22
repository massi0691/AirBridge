//
//  TargetedSendTests.swift
//  AirBridgeTests
//
//  Tests de l'envoi ciblé programmé (`AirBridgeCore
//  .scheduleTargetedSend`) — le mécanisme derrière :
//   - « Envoyer à <dernier appareil> » de l'extension Finder
//     (directive App Group) ;
//   - sélection d'un destinataire NON connecté dans la feuille
//     de partage.
//
//  Sans session, l'envoi est mémorisé (et non perdu) ; il ne part
//  qu'à la session sécurisée avec le BON pair. L'annulation et la
//  suppression par envoi explicite sont également couvertes.
//

import XCTest
import Network
@testable import AirBridge

@MainActor
final class TargetedSendTests: XCTestCase {

    // MARK: - Fixtures (même schéma que TrustedAutoConnectTests)

    private func makeCore() -> AirBridgeCore {
        let bonjour = BonjourService(
            localDevice: Device(
                id: UUID(),
                name: "iPhone de Test",
                model: "iPhone",
                systemVersion: "26.5"
            )
        )
        let router = MessageRouter()
        let pairingStore = PairingStore()
        let connectionManager = ConnectionManager(
            localDevice: bonjour.localDevice,
            messageRouter: router,
            pairingStore: pairingStore
        )
        let historyStore = TransferHistoryStore()
        let transferManager = TransferManager(
            receivedFolderStore: ReceivedFolderStore(),
            localDevice: bonjour.localDevice,
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

    private func makePeer(name: String = "Mac du test") -> Device {
        Device(
            id: UUID(),
            name: name,
            model: "Mac",
            systemVersion: "26.5"
        )
    }

    private func makeTempFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("test".utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(
            forKey: "airbridge.pairings.v1"
        )
        super.tearDown()
    }

    // MARK: - Programmation

    func testScheduleStoresPeerNameAndReturnsTrue() throws {
        let core = makeCore()
        let peer = makePeer(name: "iPhone de Massi")
        let file = try makeTempFile(named: "a.txt")

        XCTAssertNil(core.scheduledTargetedSendPeerName)
        let accepted = core.scheduleTargetedSend(
            urls: [file],
            to: peer
        )
        XCTAssertTrue(
            accepted,
            "Sans session, l'intention est mémorisée (programmée)."
        )
        XCTAssertEqual(
            core.scheduledTargetedSendPeerName,
            "iPhone de Massi",
            "Le nom du destinataire est exposé pour le bandeau."
        )
    }

    func testScheduleRejectsEmptySelection() {
        let core = makeCore()
        let peer = makePeer()
        XCTAssertFalse(
            core.scheduleTargetedSend(urls: [], to: peer),
            "Aucun fichier → rien à programmer."
        )
        XCTAssertNil(core.scheduledTargetedSendPeerName)
    }

    func testCancelClearsScheduledSend() throws {
        let core = makeCore()
        let peer = makePeer()
        let file = try makeTempFile(named: "b.txt")

        XCTAssertTrue(core.scheduleTargetedSend(urls: [file], to: peer))
        core.cancelScheduledTargetedSend()
        XCTAssertNil(
            core.scheduledTargetedSendPeerName,
            "Annulation = bandeau effacé, envoi abandonné."
        )
    }

    func testSecondScheduleReplacesFirst() throws {
        let core = makeCore()
        let first = makePeer(name: "Premier")
        let second = makePeer(name: "Second")
        let file = try makeTempFile(named: "c.txt")

        XCTAssertTrue(core.scheduleTargetedSend(urls: [file], to: first))
        XCTAssertTrue(
            core.scheduleTargetedSend(urls: [file], to: second)
        )
        XCTAssertEqual(
            core.scheduledTargetedSendPeerName,
            "Second",
            "Un seul envoi ciblé à la fois : le dernier gagne."
        )
    }

    // MARK: - Interaction avec importAndRequestItems (no-op sans
    // session : le Core refuse mais doit laisser l'état cohérent)

    func testExplicitImportWithoutConnectionRefusesButKeepsSchedule() throws {
        let core = makeCore()
        let peer = makePeer()
        let file = try makeTempFile(named: "d.txt")

        XCTAssertTrue(core.scheduleTargetedSend(urls: [file], to: peer))

        // Import explicite sans session → refusé par le Core, mais le
        // bandeau d'attente reste affiché (programmation inchangée —
        // le cancel par chevauchement n'a pas lieu puisque l'import
        // n'a pas consommé la sélection).
        XCTAssertFalse(core.importAndRequestItems(urls: [file]))
        XCTAssertEqual(
            core.scheduledTargetedSendPeerName,
            peer.name
        )
    }

    // MARK: - Exposition UI du dernier appareil connecté

    func testLastConnectedDeviceStartsNil() {
        let core = makeCore()
        XCTAssertNil(
            core.lastConnectedDevice,
            "Aucune session n'a encore existé."
        )
    }
}
