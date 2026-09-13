//
//  PairingViewModelTests.swift
//  AirBridgeTests
//
//  Tests unitaires du `PairingViewModel`. Vu le couplage avec le
//  `PairingStore` (UserDefaults) et le `ConnectionManager`, les
//  tests se concentrent sur les invariants qui ne dépendent pas
//  d'un état réseau réel.
//
//  Couvre la Phase 5 (présentation du pairage).
//

import XCTest
import Network
@testable import AirBridge

@MainActor
final class PairingViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeLocalDevice() -> Device {
        Device(
            id: UUID(),
            name: "Mac de Test",
            model: "Mac",
            systemVersion: "26.5"
        )
    }

    private func makeCore() -> AirBridgeCore {
        let bonjour = BonjourService(localDevice: makeLocalDevice())
        let router = MessageRouter()
        let pairingStore = PairingStore()
        let connectionManager = ConnectionManager(
            localDevice: bonjour.localDevice,
            messageRouter: router,
            pairingStore: pairingStore
        )
        let transferManager = TransferManager(
            receivedFolderStore: ReceivedFolderStore(),
            localDevice: bonjour.localDevice,
            historyStore: TransferHistoryStore()
        )
        return AirBridgeCore(
            bonjourService: bonjour,
            connectionManager: connectionManager,
            messageRouter: router,
            transferManager: transferManager,
            receivedFolderStore: ReceivedFolderStore(),
            transferHistoryStore: TransferHistoryStore(),
            pairingStore: pairingStore
        )
    }

    // MARK: - isConnected

    func testIsConnectedMatchesCore() {
        let core = makeCore()
        let vm = PairingViewModel(core: core)

        XCTAssertFalse(
            vm.isConnected,
            "Sans pair connecté, isConnected doit être false."
        )
        XCTAssertNil(
            core.connectionManager.connectedDevice,
            "Le Core doit confirmer l'absence de pair connecté."
        )
    }

    // MARK: - currentPeerFingerprint

    func testCurrentPeerFingerprintNilWhenNotConnected() {
        let core = makeCore()
        let vm = PairingViewModel(core: core)

        XCTAssertNil(
            vm.currentPeerFingerprint,
            "Sans pair connecté, l'empreinte doit être nil."
        )
    }

    // MARK: - currentPeerNeedsPairing

    func testCurrentPeerNeedsPairingIsFalseWhenNotConnected() {
        let core = makeCore()
        let vm = PairingViewModel(core: core)

        XCTAssertFalse(
            vm.currentPeerNeedsPairing,
            "Sans pair connecté, le drapeau 'needs pairing' doit être false."
        )
    }

    // MARK: - trustState

    func testTrustStateForUnknownPeerIsUnknown() {
        let core = makeCore()
        let vm = PairingViewModel(core: core)

        let unknownPeerID = UUID()
        XCTAssertEqual(
            vm.trustState(for: unknownPeerID),
            .unknown,
            "Un pair jamais vu doit avoir un état .unknown."
        )
    }

    // MARK: - Documentation

    /// `requestPairing()`, `trustCurrentPeer()`, `block(peerID:)` et
    /// `remove(peerID:)` ne sont pas testés : ils délèguent tous
    /// directement au `PairingStore` (couvert par
    /// `PairingStoreTests`) et / ou au `ConnectionManager` (couvert
    /// par `SessionIdSharingTests`). Le ViewModel n'ajoute aucune
    /// logique de transformation sur ces chemins.
    ///
    /// `pairings` n'est pas testé non plus : il appelle
    /// `pairingStore.loadAll()` et trie. Le tri est trivial et le
    /// `loadAll` est couvert par `PairingStoreTests`.
    func test_documentationOnly_untestedZones() {
        XCTAssertTrue(true)
    }
}
