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

/// Issue détaillée d'un envoi demandé depuis la vue d'envoi.
///
/// `send(to:)` garde sa signature `Bool` (contrat historique des
/// tests) ; ce module capture la distinction utile à la surface
/// hôte de la feuille :
///  - `.sentNow`  : le Core a importé les fichiers → la feuille peut
///    se fermer (`onSendResult(true)`) ;
///  - `.scheduled`: envoi programmé, partira à la session sécurisée →
///    la feuille reste ouverte, le bandeau reflète l'attente ;
///  - `.refused`  : rien n'a été pris en charge.
enum ShareSendOutcome: Equatable, Sendable {
    case sentNow
    case scheduled
    case refused
}

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

    /// Issue du dernier appel à `send(to:)` /
    /// `sendToLastConnectedDevice()` — lu par la vue pour décider si
    /// la feuille se ferme (`.sentNow`) ou affiche le bandeau
    /// d'attente (`.scheduled`).
    private(set) var lastSendOutcome: ShareSendOutcome = .refused

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

    /// Dernier appareil avec lequel une session a existé (même déjà
    /// fermée) — proposé en un clic depuis la feuille (« Envoyer à… »),
    /// en écho à l'action équivalente de l'extension Finder.
    var lastConnectedDevice: Device? {
        core.lastConnectedDevice
    }

    /// Nom du destinataire d'un envoi programmé vers un appareil non
    /// encore connecté. `nil` sinon — piloterait le bandeau
    /// « Connexion en cours — envoi automatique… » de la vue.
    var scheduledTargetedSendPeerName: String? {
        core.scheduledTargetedSendPeerName
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

    /// Pre-condition for the SEND BUTTON (« Envoyer » bar) : the files
    /// must be present and a peer must already be linked — that button
    /// targets the current session. Selecting a DISCOVERED chip in the
    /// recipient strip has no such requirement: `send(to:)` connects
    /// first (auto-connection) and queues the send for when the secure
    /// session is up.
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
    /// The `recipient` parameter decides the route:
    ///   - the currently connected peer → direct send through
    ///     `core.importAndRequestItems` (historical path) ;
    ///   - any other DISCOVERED peer → `core.scheduleTargetedSend` :
    ///     the Core opens a connection to that peer and queues the send
    ///     for when the secure session is up (fixes « impossible de
    ///     connecter un appareil depuis la feuille de partage »).
    ///
    /// Returns `true` if the Core took the request (sent now OR
    /// scheduled). A `false` means the selection was refused (no files,
    /// recipient neither connected nor discovered).
    @discardableResult
    func send(to recipient: DiscoveredDevice) -> Bool {
        guard !attachedURLs.isEmpty else {
            logger.warning("Envoi refusé : aucun fichier attaché")
            lastSendOutcome = .refused
            return false
        }

        // Destinataire ni connecté ni découvert → refus explicite.
        // Destinataire découvert mais non connecté → connexion + envoi
        // programmé (le bandeau de la vue reflète l'état programmé).
        if recipient.id != connectedDevice?.id {
            guard discoveredDevices.contains(
                where: { $0.id == recipient.id }
            ) else {
                logger.warning(
                    "Envoi refusé : appareil sélectionné ni connecté ni découvert"
                )
                lastSendOutcome = .refused
                return false
            }
            let scheduled = core.scheduleTargetedSend(
                urls: attachedURLs,
                to: recipient.device
            )
            if scheduled {
                attachedURLs.removeAll()
            }
            lastSendOutcome = scheduled ? .scheduled : .refused
            return scheduled
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
        lastSendOutcome = accepted ? .sentNow : .refused
        return accepted
    }

    /// Envoi en un clic vers le dernier appareil connecté — action
    /// proposée par la feuille de partage (en écho au bouton
    /// « Envoyer à <X> » de l'extension Finder), valable même si ce
    /// pair n'est plus découvert à l'instant : le Core attendra sa
    /// redécouverte (dans la limite de son délai).
    ///
    /// - Returns: `true` si l'envoi est parti ou programmé.
    @discardableResult
    func sendToLastConnectedDevice() -> Bool {
        guard let last = lastConnectedDevice else {
            lastSendOutcome = .refused
            return false
        }
        guard !attachedURLs.isEmpty else {
            logger.warning("Envoi refusé : aucun fichier attaché")
            lastSendOutcome = .refused
            return false
        }
        let accepted = core.scheduleTargetedSend(
            urls: attachedURLs,
            to: last
        )
        if accepted {
            attachedURLs.removeAll()
        }
        lastSendOutcome = accepted ? .scheduled : .refused
        return accepted
    }

    /// Annule l'envoi programmé (bandeau « envoi automatique »).
    func cancelScheduledSend() {
        core.cancelScheduledTargetedSend()
    }

    /// Relance complètement la découverte Bonjour (bouton « Rechercher »
    /// de la feuille quand aucun appareil n'apparaît, ou après un
    /// réveil macOS où la liste restait vide).
    func refreshDiscovery() {
        core.forceRestartDiscovery()
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
