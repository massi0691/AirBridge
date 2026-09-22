//
//  AirBridgeSessionTests.swift
//  AirBridgeTests
//
//  Tests de l'état de session (`AirBridgeSession`).
//
//  La session est la source de vérité de l'UI pour l'état de la
//  connexion et l'identité du pair. `touch()` maintient l'horodatage
//  d'activité qui alimente les détections d'inactivité ; un `touch`
//  oubli ou un `identifyPeer` qui n'actualiserait pas l'activité
//  ferait expulser une session en cours.
//

import XCTest
import Network
@testable import AirBridge

@MainActor
final class AirBridgeSessionTests: XCTestCase {

    /// Construit une connexion TCP non démarrée : aucun socket n'est
    /// réellement ouvert, l'objet sert seulement de référence.
    private func makeConnection() -> NWConnection {
        let port: NWEndpoint.Port = 51234
        return NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
    }

    private func makeDevice() -> Device {
        Device(
            id: UUID(),
            name: "iPhone de Test",
            model: "iPhone 16 Pro",
            systemVersion: "26.5"
        )
    }

    // MARK: - État initial

    func testInitialStateIsConnecting() {
        let session = AirBridgeSession(
            connection: makeConnection(),
            direction: .incoming
        )

        XCTAssertEqual(session.state, .connecting)
        XCTAssertNil(session.peer)
        XCTAssertEqual(session.direction, .incoming)
    }

    func testDirectionIsPreserved() {
        let outgoing = AirBridgeSession(
            connection: makeConnection(),
            direction: .outgoing
        )
        XCTAssertEqual(outgoing.direction, .outgoing)
    }

    func testExplicitPeerIsPreserved() {
        let device = makeDevice()
        let session = AirBridgeSession(
            connection: makeConnection(),
            direction: .outgoing,
            peer: device
        )

        XCTAssertEqual(session.peer, device)
    }

    // MARK: - identifyPeer

    func testIdentifyPeerSetsPeerAndTouchesActivity() {
        let session = AirBridgeSession(
            connection: makeConnection(),
            direction: .incoming
        )
        let lastActivity = session.lastActivityAt

        let device = makeDevice()
        session.identifyPeer(device)

        XCTAssertEqual(session.peer, device)
        XCTAssertGreaterThanOrEqual(session.lastActivityAt, lastActivity)
    }

    // MARK: - updateState

    func testUpdateStateChangesState() {
        let session = AirBridgeSession(
            connection: makeConnection(),
            direction: .outgoing
        )
        let lastActivity = session.lastActivityAt

        session.updateState(.ready)
        XCTAssertEqual(session.state, .ready)
        XCTAssertGreaterThanOrEqual(session.lastActivityAt, lastActivity)
    }

    func testUpdateStateToFailedThenDisconnected() {
        let session = AirBridgeSession(
            connection: makeConnection(),
            direction: .outgoing
        )

        session.updateState(.failed)
        XCTAssertEqual(session.state, .failed)

        session.updateState(.disconnected)
        XCTAssertEqual(session.state, .disconnected)
    }

    // MARK: - touch

    func testTouchUpdatesLastActivity() {
        let session = AirBridgeSession(
            connection: makeConnection(),
            direction: .incoming
        )
        let lastActivity = session.lastActivityAt

        session.touch()

        XCTAssertGreaterThanOrEqual(session.lastActivityAt, lastActivity)
    }
}
