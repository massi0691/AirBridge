//
//  TrustedAutoConnectTests.swift
//  AirBridgeTests
//
//  Tests unitaires de la connexion automatique des pairs de confiance
//  (`AirBridgeCore.handleDeviceDiscovered`, câblé sur
//  `BonjourService.onDeviceDiscovered`).
//
//  Comportements couverts :
//   - découverte d'un pair de confiance → connexion automatique ;
//   - découverte d'un pair jamais appairé → aucune connexion ;
//   - découverte d'un pair bloqué → aucune connexion ;
//   - déconnexion explicite → la redécouverte ne reconnecte pas ;
//   - reconnexion manuelle → lève la suspension et rétablit
//     l'automatique.
//
//  Les connexions visent un port local fermé : `connect()` pose la
//  session de façon synchrone (c'est ce que les assertions vérifient),
//  l'échec TCP éventuel n'arrive qu'après, de façon asynchrone.
//

import XCTest
import Network
@testable import AirBridge

@MainActor
final class TrustedAutoConnectTests: XCTestCase {

    // MARK: - Fixtures

    private func makeLocalDevice() -> Device {
        Device(
            id: UUID(),
            name: "iPhone de Test",
            model: "iPhone",
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

    /// Appareil découvert factice : endpoint sur un port local fermé.
    private func makeDiscovered(
        name: String = "Mac de Test"
    ) -> DiscoveredDevice {
        DiscoveredDevice(
            device: Device(
                id: UUID(),
                name: name,
                model: "Mac",
                systemVersion: "26.5"
            ),
            endpoint: .hostPort(
                host: "127.0.0.1",
                port: 1
            )
        )
    }

    /// Enregistre un pairage dans le store puis positionne l'état de
    /// confiance demandé. `SecureIdentity` est construit directement
    /// (struct à deux champs) : le test n'a pas besoin du Keychain.
    private func registerPeer(
        _ store: PairingStore,
        peerID: UUID,
        trust: TrustState
    ) {
        let identity = SecureIdentity(
            publicKeyData: Data([0x04, 0x01, 0x02, 0x03]),
            fingerprint: "TEST-LOCAL"
        )
        store.recordPairing(
            peerID: peerID,
            peerName: "Mac de Test",
            peerPublicKeyData: Data([0x04, 0x0A, 0x0B, 0x0C]),
            localIdentity: identity
        )
        if trust != .pending {
            store.setTrustState(trust, for: peerID)
        }
    }

    override func tearDown() {
        // `PairingStore` persiste dans `UserDefaults.standard` : nettoyer
        // pour ne pas polluer les autres tests (même convention que
        // `PairingStoreTests`).
        UserDefaults.standard.removeObject(forKey: "airbridge.pairings.v1")
        super.tearDown()
    }

    // MARK: - Connexion automatique

    func testDiscoveryAutoConnectsTrustedPeer() {
        let core = makeCore()
        let discovered = makeDiscovered()
        registerPeer(
            core.pairingStore,
            peerID: discovered.device.id,
            trust: .trusted
        )

        core.bonjourService.onDeviceDiscovered?(discovered)

        XCTAssertNotNil(
            core.connectionManager.session,
            "Un pair de confiance redécouvert doit déclencher une connexion automatique."
        )
        XCTAssertEqual(
            core.connectionManager.session?.direction,
            .outgoing,
            "La connexion automatique doit être sortante (rôle initiateur)."
        )
        XCTAssertEqual(
            core.connectionManager.lastConnectedPeer?.id,
            discovered.device.id,
            "Le pair redécouvert doit être mémorisé comme dernier pair connu."
        )
    }

    func testDiscoveryIgnoresUntrustedPeer() {
        let core = makeCore()
        let discovered = makeDiscovered()

        core.bonjourService.onDeviceDiscovered?(discovered)

        XCTAssertNil(
            core.connectionManager.session,
            "Un pair jamais appairé ne doit pas être connecté automatiquement."
        )
    }

    func testDiscoveryIgnoresBlockedPeer() {
        let core = makeCore()
        let discovered = makeDiscovered()
        registerPeer(
            core.pairingStore,
            peerID: discovered.device.id,
            trust: .blocked
        )

        core.bonjourService.onDeviceDiscovered?(discovered)

        XCTAssertNil(
            core.connectionManager.session,
            "Un pair bloqué ne doit jamais être connecté automatiquement."
        )
    }

    // MARK: - Déconnexion explicite

    func testExplicitDisconnectSuppressesAutoReconnect() {
        let core = makeCore()
        let discovered = makeDiscovered()
        registerPeer(
            core.pairingStore,
            peerID: discovered.device.id,
            trust: .trusted
        )

        // Connexion automatique établie.
        core.bonjourService.onDeviceDiscovered?(discovered)
        XCTAssertNotNil(core.connectionManager.session)

        // L'utilisateur se déconnecte explicitement.
        core.disconnectFromPeer()
        XCTAssertNil(core.connectionManager.session)

        // Une redécouverte immédiate ne doit PAS reconnecter : la
        // déconnexion volontaire reste respectée.
        core.bonjourService.onDeviceDiscovered?(discovered)
        XCTAssertNil(
            core.connectionManager.session,
            "Après une déconnexion explicite, la redécouverte ne doit pas reconnecter automatiquement."
        )
    }

    func testManualConnectClearsSuppression() {
        let core = makeCore()
        let discovered = makeDiscovered()
        registerPeer(
            core.pairingStore,
            peerID: discovered.device.id,
            trust: .trusted
        )

        // Connexion automatique puis déconnexion volontaire.
        core.bonjourService.onDeviceDiscovered?(discovered)
        core.disconnectFromPeer()
        XCTAssertNil(core.connectionManager.session)

        // Reconnexion manuelle : elle fonctionne malgré la suspension.
        core.connect(to: discovered)
        XCTAssertNotNil(
            core.connectionManager.session,
            "Une connexion manuelle doit fonctionner malgré la suspension."
        )

        // Fermeture de la session (sans déconnexion explicite cette
        // fois) : l'auto-connexion est rétablie.
        core.connectionManager.disconnect()
        core.bonjourService.onDeviceDiscovered?(discovered)
        XCTAssertNotNil(
            core.connectionManager.session,
            "Après une reconnexion manuelle, l'auto-connexion doit être rétablie."
        )
    }
}
