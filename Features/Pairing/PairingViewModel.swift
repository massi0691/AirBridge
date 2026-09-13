//
//  PairingViewModel.swift
//  AirBridge
//
//  Read-only adapter over the pairing state and the pairing actions.
//  The view model never invents a code or a fingerprint — it surfaces
//  the existing `peerFingerprint` from `PairingInfo` verbatim.
//

import Foundation
import Observation

/// Drives the pairing confirmation screen and the pairing list.
///
/// The view model is a thin read-only adapter over `core.pairingStore` and
/// `core.connectionManager`; it never derives a new secret, never modifies
/// the handshake, and never caches state outside what the Core already
/// exposes.
@MainActor
@Observable
final class PairingViewModel {

    let core: AirBridgeCore

    /// Previous public key data for the current peer, used to detect key changes.
    /// Set when the view appears and updated when the peer is trusted.
    private var previousPublicKeyData: Data?

    init(core: AirBridgeCore) {
        self.core = core
        // Initialize with current peer's public key if available
        if let peer = core.connectionManager.connectedDevice,
           let currentInfo = core.pairingStore.pairing(for: peer.id) {
            self.previousPublicKeyData = currentInfo.peerPublicKeyData
        }
    }

    /// The name of the current peer (for display in alerts).
    var currentPeerName: String {
        core.connectionManager.connectedDevice?.name ?? "Appareil inconnu"
    }

    // MARK: - State

    /// All known pairings, sorted with the most recently seen first.
    var pairings: [PairingInfo] {
        Array(core.pairingStore.loadAll().values)
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Trust state for a given peer — `nil` if no record exists.
    func trustState(for peerID: UUID) -> TrustState {
        core.pairingStore.trustState(for: peerID)
    }

    /// True when the local device is currently linked to a remote peer.
    var isConnected: Bool {
        core.connectionManager.connectedDevice != nil
    }

    /// True when a session is active AND the connected peer is not yet
    /// trusted. This is the trigger to surface "needs pairing" UI.
    var currentPeerNeedsPairing: Bool {
        guard let peer = core.connectionManager.connectedDevice else {
            return false
        }
        return !core.pairingStore.isTrusted(peer.id)
            && !core.pairingStore.isBlocked(peer.id)
    }

    /// The fingerprint of the current peer, if a pairing record exists.
    /// This is the data the Core already produced — we never compute a
    /// new one.
    var currentPeerFingerprint: String? {
        guard let peer = core.connectionManager.connectedDevice else {
            return nil
        }
        return core.pairingStore.pairing(for: peer.id)?.peerFingerprint
    }

    /// The current peer's public key data, if available.
    /// This is tracked so views can observe changes in real-time.
    var currentPeerPublicKeyData: Data? {
        guard let peer = core.connectionManager.connectedDevice else {
            return nil
        }
        return core.pairingStore.pairing(for: peer.id)?.peerPublicKeyData
    }

    /// The current peer's trust state, if available.
    /// This is tracked so views can observe changes in real-time.
    var currentPeerTrustState: TrustState? {
        guard let peer = core.connectionManager.connectedDevice else {
            return nil
        }
        return core.pairingStore.trustState(for: peer.id)
    }

    /// Version counter of the pairing store.
    /// Changes when pairings are modified, allowing views to observe updates.
    var pairingStoreVersion: Int {
        core.pairingStore.version
    }

    // MARK: - Key Change Detection

    /// Returns true if the current peer's public key is different from the previously recorded one.
    /// This indicates a potential security change that requires user confirmation.
    var hasPublicKeyChanged: Bool {
        guard let peer = core.connectionManager.connectedDevice,
              let currentInfo = core.pairingStore.pairing(for: peer.id),
              let previousData = previousPublicKeyData else {
            return false
        }
        return currentInfo.peerPublicKeyData != previousData
    }

    /// Updates the stored public key data. Called after user confirms trust.
    func recordCurrentPublicKey() {
        guard let peer = core.connectionManager.connectedDevice,
              let currentInfo = core.pairingStore.pairing(for: peer.id) else {
            return
        }
        previousPublicKeyData = currentInfo.peerPublicKeyData
    }

    // MARK: - Actions

    /// Initiates a pairing handshake with the currently connected peer.
    /// The Core is the source of truth for the protocol; this just
    /// forwards the gesture.
    @discardableResult
    func requestPairing() -> Bool {
        core.requestPairingIfNeeded()
    }

    /// Marks the current peer as trusted.
    func trustCurrentPeer() {
        guard let peer = core.connectionManager.connectedDevice else {
            return
        }
        core.pairingStore.setTrustState(.trusted, for: peer.id)
    }

    /// Marks the current peer as blocked (used when user declines key change).
    func blockCurrentPeer() {
        guard let peer = core.connectionManager.connectedDevice else {
            return
        }
        core.pairingStore.setTrustState(.blocked, for: peer.id)
    }

    /// Marks a known peer as trusted (used from the pairing list).
    func trust(peerID: UUID) {
        core.pairingStore.setTrustState(.trusted, for: peerID)
    }

    /// Marks a known peer as blocked.
    func block(peerID: UUID) {
        core.pairingStore.setTrustState(.blocked, for: peerID)
    }

    /// Removes a known peer from the store.
    func remove(peerID: UUID) {
        core.pairingStore.removePairing(for: peerID)
    }
}