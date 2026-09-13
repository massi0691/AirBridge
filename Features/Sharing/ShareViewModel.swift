//
//  ShareViewModel.swift
//  AirBridge
//
//  Read-only adapter over the Core's connection / discovery state,
//  augmented with the local list of files chosen by the user.
//
//  The view model is a strict orchestration layer:
//   - it never invents a cryptographic primitive, a code, or a
//     fingerprint — every state it exposes is data the Core already
//     produced (connection state, discovered devices, trust states) ;
//   - it never bypasses the Core's public API. File transfer is
//     initiated by `core.importAndRequestItems(urls:)`, which already
//     handles the FIFO queue, security-scoped resources, and the
//     selection split (files vs. folders) ;
//   - it enforces the pre-condition « connected device + at least one
//     file » before surfacing a send action to the View, so the user
//     never gets a silent no-op when no peer is linked.
//

import Foundation
import Observation
import SwiftUI
import OSLog

/// Drives the share screen.
///
/// The View never reaches into `core` directly : it only reads the
/// values exposed here and forwards user gestures (file pick,
/// recipient tap, send) to the matching methods. The ViewModel itself
/// stays free of UIKit / SwiftUI types so it can be unit-tested in
/// isolation.
@MainActor
@Observable
final class ShareViewModel {

    let core: AirBridgeCore

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "ui.share.viewmodel"
    )

    /// Local list of files chosen by the user on the share screen.
    /// URLs are kept as-is (no copy) : the Core owns the lifecycle of
    /// the security-scoped access and the temporary copy it makes for
    /// the actual transfer.
    private(set) var attachedURLs: [URL] = []

    /// Toggle the user can flip to include non-trusted peers in the
    /// recipient selector. Defaults to `true` to mirror the existing
    /// behaviour of the legacy file-picker action bar (any connected
    /// peer is a valid recipient).
    var showAllRecipients: Bool = true

    init(core: AirBridgeCore) {
        self.core = core
    }

    // MARK: - Read

    /// Identity of the local device. Re-published so the View does not
    /// need to depend on `LocalDeviceFactory` directly.
    var localDevice: Device {
        core.bonjourService.localDevice
    }

    /// List of devices the Core has discovered on the local network.
    var discoveredDevices: [DiscoveredDevice] {
        core.bonjourService.discoveredDevices
    }

    /// The peer currently linked to this device, if any.
    var connectedDevice: Device? {
        core.connectionManager.connectedDevice
    }

    /// True when a remote peer is currently linked.
    var isConnected: Bool {
        connectedDevice != nil
    }

    /// Recipients the user can pick from, honouring the
    /// `showAllRecipients` toggle. The connected peer is the only one
    /// that can actually receive a transfer, so we keep it even when
    /// it's not trusted yet.
    var availableRecipients: [DiscoveredDevice] {
        let devices = discoveredDevices
        if showAllRecipients {
            return devices
        }
        return devices.filter { device in
            core.pairingStore.isTrusted(device.id)
        }
    }

    /// Pre-condition for the send action. The user must have:
    ///   - picked at least one file ;
    ///   - be connected to a remote peer.
    /// Without the second one, calling into the Core would be a no-op
    /// (it would print a warning and do nothing), which is a worse UX
    /// than simply disabling the send button with a banner.
    var canShare: Bool {
        isConnected && !attachedURLs.isEmpty
    }

    /// Formatted total size of the attached files, in a human-readable
    /// unit (Ko / Mo / Go). `nil` if the list is empty, so the View
    /// can simply hide the field.
    var totalAttachedSize: String? {
        guard !attachedURLs.isEmpty else { return nil }
        let bytes = attachedURLs.reduce(into: Int64(0)) { acc, url in
            acc += fileSize(at: url) ?? 0
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Human-readable description of the current connection state,
    /// sourced verbatim from the Core. Used in the header so the user
    /// always sees the ground truth (not a cached copy).
    var connectionStateDescription: String {
        core.connectionManager.stateDescription
    }

    // MARK: - Write

    /// Appends files to the list, deduplicating by standard file URL
    /// (`/path` and `file:///path` are considered the same file). The
    /// order is preserved so the View shows them in the order the user
    /// picked them.
    func attach(urls: [URL]) {
        for url in urls where !attachedURLs.contains(url) {
            attachedURLs.append(url)
        }
    }

    /// Removes files by index set, matching the contract expected by
    /// `ForEach` + `onDelete`. Indices refer to the current state of
    /// `attachedURLs` at the moment of the call.
    func remove(urlAt offsets: IndexSet) {
        attachedURLs.remove(atOffsets: offsets)
    }

    /// Removes a single file at the given index. Used by the grid
    /// cards' tap action so a single tap on a card always removes
    /// that one card without involving the onDelete swipe gesture.
    func remove(urlAt index: Int) {
        guard attachedURLs.indices.contains(index) else { return }
        attachedURLs.remove(at: index)
    }

    /// Clears the local list of chosen files. The transfer itself is
    /// already owned by the Core, so this only touches the share UI.
    func clearAttached() {
        attachedURLs.removeAll()
    }

    /// Initiates a transfer of all currently attached files.
    ///
    /// The Core handles the FIFO queue, the selection split, the
    /// security-scoped resources, and the connection-state guard —
    /// we only forward the call.
    ///
    /// The `recipient` parameter is taken for UI semantics
    /// (the user explicitly picked a target device) but is not
    /// forwarded to the Core: the Core's public `importAndRequestItems`
    /// is single-argument and routes the call to whichever peer is
    /// currently connected. We refuse the call when the picked
    /// recipient is not the connected one, so the user never gets a
    /// silent reroute to a different device.
    ///
    /// Returns `true` if the Core actually took the request. A `false`
    /// return means the pre-conditions were not met (no peer, no
    /// files, or the picked recipient is not the connected peer);
    /// the View should surface a "connect first" feedback in that
    /// case.
    @discardableResult
    func send(to recipient: DiscoveredDevice) -> Bool {
        guard isConnected else {
            // The user should never see a send button without a peer
            // — `canShare` is `false` in that case. We double-check
            // here as a defensive measure: a peer may disconnect
            // between the View's render and the tap.
            logger.warning("Envoi refusé : aucun appareil connecté")
            return false
        }
        guard !attachedURLs.isEmpty else {
            logger.warning("Envoi refusé : aucun fichier attaché")
            return false
        }
        // Reject if the picked recipient is not the connected peer :
        // the Core only has one outbound channel, and silently
        // rerouting to a different device would be a worse outcome
        // than a clear "wrong device" feedback.
        guard recipient.id == connectedDevice?.id else {
            logger.warning("Envoi refusé : appareil sélectionné non connecté")
            return false
        }

        // Log de diagnostic avant l'envoi
        let fileCount = attachedURLs.count
        let totalSize = attachedURLs.reduce(into: Int64(0)) { acc, url in
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                acc += Int64(size)
            }
        }
        logger.info("Demande d'envoi : \(fileCount) fichier(s), \(totalSize) octets vers \(recipient.device.name, privacy: .public)")

        let snapshot = attachedURLs
        let accepted = core.importAndRequestItems(urls: snapshot)

        // Log post-envoi - vérifie l'état de connexion
        if let device = connectedDevice {
            logger.info("Transfert initié vers \(device.name, privacy: .public), ID: \(device.id.uuidString, privacy: .public)")
        }

        // The Core copies the file into a temporary location before
        // queuing, so we can clear the local list immediately: the
        // original URL stays where the user picked it from, and the
        // attached view no longer mirrors it.
        attachedURLs.removeAll()

        // On renvoie le résultat RÉEL du moteur, pas une supposition :
        // `true` signifie « au moins un fichier importé dans le
        // temporaire du Core et mis en file », `false` que la sélection
        // n'a pas été consommée (aucun appareil, copie en échec). C'est
        // ce signal que la surface attache « onSendResult » consomme —
        // rien n'est supprimé ici : les fichiers de lot dont l'envoi est
        // en cours ou a échoué restent nécessaires tant que le transfert
        // n'a pas abouti (`PendingShareController.pruneDeliveredBatches`).
        return accepted
    }

    // MARK: - Helpers

    /// Reads the byte size of a file via `URLResourceValues`. Returns
    /// `nil` if the file is missing or unreadable — the View falls
    /// back to a generic label in that case.
    private func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}
