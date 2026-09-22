//
//  DiscoveryViewModel.swift
//  AirBridge
//
//  Read-only adapter over the Core's discovery + connection state.
//  Holds no business logic — only re-publishes the existing surface so
//  the View can be tested in isolation.
//

import Foundation
import Observation

/// ViewModel for the discovery screen.
///
/// The radar animation and the device list are driven by this adapter:
/// the View never reaches into `core` directly, so the dependency is
/// one-way and easily mockable.
@MainActor
@Observable
final class DiscoveryViewModel {

    let core: AirBridgeCore

    init(core: AirBridgeCore) {
        self.core = core
    }

    // MARK: - Read

    var localDevice: Device {
        core.bonjourService.localDevice
    }

    var discoveredDevices: [DiscoveredDevice] {
        core.bonjourService.discoveredDevices
    }

    var connectedDevice: Device? {
        core.connectionManager.connectedDevice
    }

    var connectionStateDescription: String {
        core.connectionManager.stateDescription
    }

    /// True when the local device is currently linked to a remote peer.
    var isConnected: Bool {
        connectedDevice != nil
    }

    func isConnected(_ device: Device) -> Bool {
        connectedDevice?.id == device.id
    }

    // MARK: - Write

    /// Connexion manuelle : passe par le Core, qui lève au passage la
    /// suspension de connexion automatique vers ce pair (une reconnexion
    /// manuelle après une déconnexion volontaire rétablit l'automatique).
    func connect(to device: DiscoveredDevice) {
        core.connect(to: device)
    }

    /// Déconnexion manuelle : passe par le Core, qui suspend la connexion
    /// automatique vers ce pair — sinon le prochain événement Bonjour
    /// reconnecterait immédiatement l'appareil que l'utilisateur vient de
    /// déconnecter.
    func disconnect() {
        core.disconnectFromPeer()
    }
}
