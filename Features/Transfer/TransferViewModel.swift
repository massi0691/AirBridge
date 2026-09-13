//
//  TransferViewModel.swift
//  AirBridge
//
//  Read-only adapter over the Core's transfer state, augmented with
//  the throttled UI projection (progress, speed, ETA) that the screen
//  needs.
//
//  The view model is a strict orchestration layer:
//   - it never invents a transfer state — every status, byte count
//     and direction is data the Core already produced ;
//   - it never bypasses the Core's public API. Cancellation goes
//     through `core.cancelTransfer(transferID:)` (outgoing) or
//     `core.cancelInterruptedTransfer(transferID:)`, and resumption
//     through `core.resumeTransfer(_:)` ;
//   - it throttles progress republishing to the View at 10 FPS
//     (every 100 ms) so a multi-megabyte pipeline that emits
//     updates every few milliseconds does not flood SwiftUI.
//

import Foundation
import Observation
import SwiftUI

/// Status surfaced to the transfer screen.
///
/// The Core's `Transfer.State` is a richer enum (`.requesting`,
/// `.waitingForApproval`, `.accepted`, …) but those intermediate
/// states are protocol-level plumbing that the user does not need to
/// distinguish. The screen groups them into five buckets the user
/// can act on: waiting, active, completed, failed, cancelled.
enum TransferUIStatus: Sendable {
    case waiting
    case active
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .waiting: "En attente"
        case .active: "En cours"
        case .completed: "Réussi"
        case .failed: "Échec"
        case .cancelled: "Annulé"
        }
    }
}

/// Direction surfaced to the transfer screen.
enum TransferUIDirection: Sendable {
    case incoming
    case outgoing
}

/// UI-friendly projection of a `Transfer`.
///
/// Decouples the View from the Core's exact field names. The screen
/// only ever reads this type, so renaming a Core field never ripples
/// to the View.
struct TransferUIModel: Identifiable, Sendable {

    let id: UUID
    let fileName: String
    let totalBytes: Int64
    let transferredBytes: Int64
    let progress: Double
    let speed: Double
    let eta: TimeInterval?
    let status: TransferUIStatus
    let direction: TransferUIDirection
    let peer: Device

    /// Date de démarrage du transfert (déclenché par l'utilisateur
    /// via `startedAt` côté Core, sinon `createdAt`).
    ///
    /// Optionnelle : certaines entrées purement historiques
    /// peuvent ne pas exposer de date de démarrage utilisable —
    /// la View se contente alors de l'ommettre plutôt que d'afficher
    /// une date arbitraire.
    let startDate: Date?

    /// Core transfer, kept for callers that need to forward an
    /// action (cancel, retry) back to the ViewModel. Toujours
    /// non-nil : pour les entrées purement historiques, on reconstruit
    /// un `Transfer` synthétique dans la projection (cf.
    /// `projection(historyEntry:liveTransfer:)`).
    let core: Transfer
}

/// Erreurs renvoyées par `deleteStoredFile(for:)`.
enum FileDeleteError: Error {
    case fileNotFound
    case permissionDenied
    case unknown(Error)
}

/// Drives the transfer screen.
///
/// The View never reaches into `core` directly : it only reads the
/// values exposed here and forwards user gestures (cancel, retry,
/// remove-from-history) to the matching methods. The ViewModel itself
/// stays free of UIKit / SwiftUI types in its public surface so it
/// can be unit-tested in isolation.
@MainActor
@Observable
final class TransferViewModel {

    let core: AirBridgeCore

    // MARK: - Read

    /// Outgoing transfers currently visible in the Core, in Core
    /// order (the Core keeps insertion order, which matches the
    /// FIFO queue's send order).
    var outgoing: [Transfer] {
        core.transferManager.transfers
            .filter { $0.direction == .outgoing }
    }

    /// Incoming transfers currently visible in the Core, in Core
    /// order.
    var incoming: [Transfer] {
        core.transferManager.transfers
            .filter { $0.direction == .incoming }
    }

    /// History entries that the user can browse after the transfer
    /// has reached a terminal state. The Core already records
    /// completions / failures / cancellations in
    /// `transferHistoryStore`; we surface them sorted with the most
    /// recent first.
    var history: [TransferHistoryEntry] {
        core.transferHistoryStore.entries
            .sorted { $0.startDate > $1.startDate }
    }

    /// Live and history lists merged, used by tab "Tous".
    ///
    /// The "allTransfers" promise from the spec is implemented as a
    /// lazy merge so the screen can swap tabs without losing
    /// scroll position : both lists come from the same backing
    /// store, so the result is a single observation point.
    var allTransfers: [Transfer] {
        core.transferManager.transfers
    }

    // MARK: - Throttled UI projection

    /// Republish budget for live updates. The Core can publish
    /// transfer state at > 100 Hz during an active transfer; the
    /// projection cache below coalesces those into ~10 Hz republishes
    /// so the View doesn't have to diff the row at 60 Hz.
    private static let republishInterval: TimeInterval = 0.1

    /// Cache of the last projection we published to the View, keyed
    /// by transfer id. Used by `outgoingUI` / `incomingUI` to avoid
    /// re-creating the full projection array on every read.
    private var projectionCache: [UUID: (model: TransferUIModel, version: UInt64)] = [:]

    /// Monotonic counter bumped on every Core mutation we observe.
    /// The ViewModel doesn't have a direct change-feed, so we rely on
    /// the Core's observable to drive refreshes — but we still want
    /// to know if a value has actually changed since the last
    /// publish. The counter is bumped lazily inside the projections.
    private var publishVersion: UInt64 = 0

    /// Throttled republisher. The Core's per-chunk state changes can
    /// fire 100+ times per second during a transfer. We submit the
    /// version on every change but only republish the Observable
    /// token at 10 Hz, so the View re-renders are coalesced.
    private let republisher: UIThrottle<UInt64>

    /// Background task that drains the throttle and writes the
    /// republish back to `publishVersion`. Started in `init`; the
    /// task runs for the lifetime of the ViewModel and exits
    /// naturally when the throttle's stream finishes.
    private var drainTask: Task<Void, Never>?

    init(core: AirBridgeCore) {
        self.core = core
        self.republisher = UIThrottle<UInt64>(
            interval: Self.republishInterval
        )
        // Drain the throttle into `publishVersion`. The task captures
        // `self` weakly so when the ViewModel goes away, the loop
        // exits on the next yield. We don't keep a strong reference
        // here on purpose — the stream is a one-way signal, the
        // ViewModel is the only thing that should outlive the loop.
        self.drainTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.republisher.stream {
                self.applyRepublish()
            }
        }
    }

    /// Writes the republish token, waking the `@Observable` tracking
    /// and forcing the View to re-read on the next render pass.
    private func applyRepublish() {
        publishVersion &+= 1
    }

    // MARK: - Computed projections

    /// Outgoing transfers as the View wants to render them. The
    /// cache is keyed by transfer id ; entries that the Core still
    /// reports as in-flight (`.transferring`) are re-projected on
    /// every read so progress stays accurate, then the cache is
    /// refreshed under the throttle so we don't pay the cost twice.
    var outgoingUI: [TransferUIModel] {
        let list = outgoing
        return list.map { transfer in
            if shouldRecompute(transfer) || projectionCache[transfer.id] == nil {
                let model = projection(for: transfer)
                projectionCache[transfer.id] = (model, publishVersion)
                return model
            }
            return projectionCache[transfer.id]!.model
        }
    }

    /// Incoming transfers as the View wants to render them. Same
    /// caching strategy as `outgoingUI`.
    var incomingUI: [TransferUIModel] {
        let list = incoming
        return list.map { transfer in
            if shouldRecompute(transfer) || projectionCache[transfer.id] == nil {
                let model = projection(for: transfer)
                projectionCache[transfer.id] = (model, publishVersion)
                return model
            }
            return projectionCache[transfer.id]!.model
        }
    }

    /// Live progress, speed and ETA need to refresh on every read
    /// during an active transfer. Terminal values (`.completed`,
    /// `.cancelled`, `.failed`, `.rejected`, `.interrupted`) only
    /// change once, so we can serve them from the cache indefinitely.
    private func shouldRecompute(_ transfer: Transfer) -> Bool {
        switch transfer.state {
        case .transferring:
            republisher.submit(publishVersion)
            return true
        case .completed, .cancelled, .rejected, .failed, .interrupted:
            // Also recompute if the cached version predates the
            // current state — handles the "transferred to terminal
            // since last read" case.
            if let cached = projectionCache[transfer.id] {
                let stateChanged = Self.status(for: transfer.state) != cached.model.status
                if stateChanged {
                    // Terminal transition: force a republish so
                    // the user sees the final state without waiting
                    // for the next 100 ms tick.
                    republisher.flush()
                }
                return stateChanged
                    || transfer.transferredBytes != cached.model.transferredBytes
            }
            // First time we see this transfer at a terminal state:
            // publish immediately.
            republisher.flush()
            return true
        case .requesting, .waitingForApproval, .accepted:
            republisher.submit(publishVersion)
            return true
        }
    }

    /// History entries the user can act on (clear, share, etc.).
    func historyUI() -> [TransferUIModel] {
        // The history is a Core-side ledger (transferHistoryStore);
        // we map each entry to a UI model so the View uses the same
        // projection everywhere. The `core` transfer is filled in
        // when the Core still has the live `Transfer` in memory ;
        // older entries (the Core caps history at 100 and may have
        // pruned the live array) fall back to a synthetic one built
        // from the history entry.
        history.map { entry in
            let live = core.transferManager.transfers
                .first { $0.id == entry.id }
            return projection(historyEntry: entry, liveTransfer: live)
        }
    }

    // MARK: - Counts (used by the tab labels)

    /// Number of non-terminal outgoing transfers : informs the
    /// "Actifs" badge.
    var activeOutgoingCount: Int {
        outgoing.filter { !$0.state.isTerminal }.count
    }

    /// Number of non-terminal incoming transfers.
    var activeIncomingCount: Int {
        incoming.filter { !$0.state.isTerminal }.count
    }

    /// Total number of in-flight transfers (both directions).
    var activeCount: Int {
        activeOutgoingCount + activeIncomingCount
    }

    /// Total number of entries in the history.
    var completedCount: Int {
        history.count
    }

    // MARK: - Write

    /// Cancels a transfer through the Core's public API.
    ///
    /// The Core dispatches by direction internally:
    ///   - outgoing active: stops the pipeline, sends a
    ///     `transferCancelled` to the peer, marks `.cancelled`.
    ///   - outgoing waiting: removed from the FIFO queue, no peer
    ///     notification needed.
    ///   - interrupted: terminal cleanup of the resume metadata.
    /// The View never needs to know which path was taken.
    func cancel(transfer: Transfer) {
        // `cancelInterruptedTransfer` is the only path that handles
        // `.interrupted` cleanly. For everything else, the generic
        // `cancelTransfer` is correct.
        if transfer.state == .interrupted {
            core.cancelInterruptedTransfer(transferID: transfer.id)
        } else {
            core.cancelTransfer(transferID: transfer.id)
        }
    }

    /// Retries a failed or cancelled transfer.
    ///
    /// The Core exposes two re-arm paths:
    ///   - `resumeTransfer(_:)` for `.interrupted` transfers (the
    ///     typical outcome of a network drop on either side).
    ///   - For terminal failures, the user must rebuild a new
    ///     selection from the share screen — we surface a hint via
    ///     the `canRetry` flag so the View can hide the button.
    func retry(transfer: Transfer) {
        switch transfer.state {
        case .interrupted:
            core.resumeTransfer(transfer.id)
        default:
            // The Core does not expose a "resend this file" path
            // for terminal states (the source may already be gone,
            // the protocol forbids replays of completed files,
            // etc.). The View should hide the Retry button for
            // those states — this is a defensive no-op.
            break
        }
    }

    /// True if the View should surface a Retry button for this
    /// transfer. Today only `.interrupted` is retryable.
    func canRetry(_ transfer: Transfer) -> Bool {
        transfer.state == .interrupted
    }

    /// True if the View should surface a Cancel button for this
    /// transfer. Anything not yet terminal can be cancelled.
    func canCancel(_ transfer: Transfer) -> Bool {
        !transfer.state.isTerminal
    }

    /// Removes a transfer entry from the local history list only.
    ///
    /// The Core's history store is the system of record; this
    /// method just asks it to drop the entry. The live `Transfer`
    /// array is left alone (the entry is already terminal there).
    func removeFromHistory(transfer: Transfer) {
        core.transferHistoryStore.removeEntry(id: transfer.id)
    }

    /// Removes a history entry by ID. Convenience for swipe-to-
    /// delete callbacks that operate on the entry directly.
    func removeFromHistory(entryID: UUID) {
        core.transferHistoryStore.removeEntry(id: entryID)
    }

    /// Clears the whole history.
    func clearHistory() {
        core.transferHistoryStore.clearAll()
    }

    // MARK: - Storage (delete physical file)

    /// Supprime le fichier physique associé à une entrée d'historique.
    ///
    /// S'appuie sur `localURL(for:)` pour résoudre l'URL sur disque
    /// (cf. commentaire de cette méthode). On **refuse** de toucher
    /// aux fichiers `.partial` — ils peuvent appartenir à un
    /// transfert en cours de reprise et leur suppression casserait le
    /// mécanisme de reprise. Les autres erreurs sont mappées à un
    /// `FileDeleteError` minimal pour que la View puisse afficher un
    /// message sans dépendre de `NSError`.
    func deleteStoredFile(for entryID: UUID) -> Result<Void, FileDeleteError> {
        guard let url = localURL(for: entryID) else {
            return .failure(.fileNotFound)
        }
        return Self.deleteFile(at: url)
    }

    /// Supprime un fichier sur disque en suivant les règles métier
    /// d'AirBridge :
    ///   - refuse de supprimer un fichier `.partial` (reprise en
    ///     cours, à protéger) ;
    ///   - renvoie `.fileNotFound` si le fichier n'existe pas ;
    ///   - mappe les erreurs `NSFileWriteNoPermissionError` /
    ///     `NSFileReadNoPermissionError` sur `.permissionDenied` ;
    ///   - renvoie tout autre `NSError` sous `.unknown`.
    ///
    /// Exposé en `internal static` pour pouvoir être testé sans
    /// monter un `AirBridgeCore` complet (le ViewModel réel appelle
    /// cette fonction après avoir résolu l'URL via `localURL(for:)`).
    static func deleteFile(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Result<Void, FileDeleteError> {
        // `.partial` = reprise de transfert en cours. On n'y touche
        // pas — l'appelant doit d'abord annuler ou terminer le
        // transfert actif avant de pouvoir nettoyer le fichier
        // temporaire.
        if url.pathExtension == "partial" {
            return .failure(.permissionDenied)
        }
        if !fileManager.fileExists(atPath: url.path) {
            return .failure(.fileNotFound)
        }
        do {
            try fileManager.removeItem(at: url)
            return .success(())
        } catch let nsError as NSError {
            if nsError.code == NSFileWriteNoPermissionError
                || nsError.code == NSFileReadNoPermissionError {
                return .failure(.permissionDenied)
            }
            return .failure(.unknown(nsError))
        }
    }

    /// UI model pour une entrée d'historique identifiée par id.
    ///
    /// Utilisé par la `FileActionSheet` qui ne reçoit qu'un id dans
    /// son payload de présentation et résout le reste au moment de
    /// l'ouverture (cohérence avec `localURL(for:)` et le pattern
    /// déjà utilisé par `HistoryPreviewPresentation`).
    func uiModel(for entryID: UUID) -> TransferUIModel? {
        historyUI().first { $0.id == entryID }
    }

    // MARK: - Helpers (preview / dossier)

    /// Résout l'URL locale d'une entrée d'historique à partir de son id.
    ///
    /// Le ledger `TransferHistoryEntry` ne persiste pas le chemin du
    /// fichier (volontairement, pour éviter de coupler l'historique au
    /// système de fichiers). On ne peut donc proposer une preview que
    /// si le `Transfer` correspondant est encore vivant dans le Core
    /// (`core.transferManager.transfers`). Si c'est le cas, on renvoie :
    ///   - `localFileURL` pour un transfert reçu (le fichier écrit sur
    ///     disque par le receveur) ;
    ///   - `sourceFileURL` pour un transfert envoyé (le fichier source
    ///     que l'émetteur a partagé).
    ///
    /// Renvoie `nil` pour toute entrée purement historique (redémarrage
    /// de l'app, fichier déjà nettoyé) — l'appelant n'a alors qu'à
    /// proposer "Afficher dans le dossier" sans preview.
    func localURL(for entryID: UUID) -> URL? {
        guard let transfer = core.transferManager.transfers
            .first(where: { $0.id == entryID })
        else {
            return nil
        }
        return transfer.localFileURL ?? transfer.sourceFileURL
    }

    /// URL du dossier de réception. La distinction plateforme reflète
    /// le modèle de stockage de chaque OS :
    ///   - macOS : l'utilisateur choisit un dossier arbitraire via
    ///     `ReceivedFolderStore` (sandbox + bookmark de sécurité).
    ///   - iOS : le sandbox de l'app isole tout dans `Documents/`, qui
    ///     est l'unique emplacement où l'app peut écrire un fichier
    ///     reçu sans configuration supplémentaire. L'utilisateur peut
    ///     ensuite l'exposer via la sheet système "Partager / Enregistrer".
    ///
    /// Renvoie `nil` tant que l'utilisateur n'a pas sélectionné de
    /// dossier sur macOS — la View désactive alors l'action "Dossier".
    var receivedDirectoryURL: URL? {
#if os(macOS)
        return core.receivedFolderStore.selectedDirectory
#else
        return URL.documentsDirectory
#endif
    }

    // MARK: - Helpers

    /// Maps a live `Transfer` to its UI projection.
    ///
    /// The projection derives:
    ///   - `progress` from the Core's own `Transfer.progress` so the
    ///     two stay perfectly aligned ;
    ///   - `status` from the Core's terminal flags, collapsing
    ///     intermediate states (`.requesting`, `.accepted`, …) into
    ///     `.waiting` ;
    ///   - `speed` and `eta` from the Core's own `startedAt` /
    ///     `transferredBytes`. We avoid emitting these as observable
    ///     fields of the ViewModel : the View reads them per render
    ///     and they refresh on the natural Core change cycle.
    private func projection(
        for transfer: Transfer
    ) -> TransferUIModel {
        TransferUIModel(
            id: transfer.id,
            fileName: transfer.fileName,
            totalBytes: transfer.fileSize,
            transferredBytes: transfer.transferredBytes,
            progress: transfer.progress,
            speed: Self.speed(for: transfer),
            eta: Self.eta(for: transfer),
            status: Self.status(for: transfer.state),
            direction: transfer.direction == .incoming
                ? .incoming
                : .outgoing,
            peer: transfer.peer,
            startDate: transfer.startedAt ?? transfer.createdAt,
            core: transfer
        )
    }

    /// Maps a `TransferHistoryEntry` (Core-side ledger) to its UI
    /// projection. The live `Transfer` is provided when still in
    /// memory, so the speed / ETA values stay accurate even for
    /// entries that the Core just added.
    private func projection(
        historyEntry: TransferHistoryEntry,
        liveTransfer: Transfer?
    ) -> TransferUIModel {
        // Prefer the live transfer's data when available — the
        // history entry is a snapshot from the moment the transfer
        // became terminal, and the live record may have richer info
        // (e.g. updated direction or peer). Falls back to the
        // history entry's metadata otherwise.
        let peer: Device
        let direction: TransferUIDirection
        let status: TransferUIStatus
        let transferredBytes: Int64
        let totalBytes: Int64
        let fileName: String

        if let live = liveTransfer {
            peer = live.peer
            direction = live.direction == .incoming
                ? .incoming
                : .outgoing
            status = Self.status(for: live.state)
            transferredBytes = live.transferredBytes
            totalBytes = live.fileSize
            fileName = live.fileName
        } else {
            // The peer for a history-only entry is reconstructed
            // from the entry's device name ; no ID is available
            // because the Core only persists a name snapshot.
            peer = Device(
                id: historyEntry.id,
                name: historyEntry.remoteDeviceName,
                model: historyEntry.remoteDeviceType,
                systemVersion: ""
            )
            direction = historyEntry.direction == .sent
                ? .outgoing
                : .incoming
            status = Self.status(for: historyEntry.status)
            transferredBytes = historyEntry.fileSize
            totalBytes = historyEntry.fileSize
            fileName = historyEntry.fileName
        }

        // Progress for a completed entry is 100 %, for a failed /
        // cancelled entry the live data wins (it may have a partial
        // progress to show).
        let progress: Double
        if status == .completed {
            progress = 1.0
        } else if let live = liveTransfer {
            progress = live.progress
        } else {
            progress = 0
        }

        return TransferUIModel(
            id: historyEntry.id,
            fileName: fileName,
            totalBytes: totalBytes,
            transferredBytes: transferredBytes,
            progress: progress,
            speed: historyEntry.transferSpeed,
            eta: nil,
            status: status,
            direction: direction,
            peer: peer,
            startDate: historyEntry.startDate,
            core: liveTransfer
                ?? Transfer(
                    id: historyEntry.id,
                    peer: peer,
                    fileName: fileName,
                    fileSize: totalBytes,
                    direction: direction == .incoming
                        ? .incoming
                        : .outgoing,
                    state: status.toCoreState(),
                    transferredBytes: transferredBytes
                )
        )
    }

    // MARK: - Status / speed / ETA helpers

    /// Maps a Core `Transfer.State` to the coarse UI bucket.
    ///
    /// Exposed as `internal` (not `private`) so the unit tests can
    /// exercise the mapping without spinning up a real Core. The
    /// behaviour is identical to the previous `private` version — the
    /// visibility change is the only modification.
    static func status(
        for state: Transfer.State
    ) -> TransferUIStatus {
        switch state {
        case .completed:
            return .completed
        case .cancelled, .rejected:
            return .cancelled
        case .failed:
            return .failed
        case .interrupted:
            // Interrupted is shown as "Failed" to the user — the
            // distinction matters at the Core level (interrupted is
            // recoverable) but at the UI level both look like
            // "your transfer didn't go through, here's what to do
            // next". The Retry button is what differs.
            return .failed
        case .requesting,
             .waitingForApproval,
             .accepted,
             .transferring:
            return state == .transferring
                ? .active
                : .waiting
        }
    }

    /// Maps a Core `TransferStatus` (history-only) to the UI bucket.
    ///
    /// Same visibility rationale as the `Transfer.State` overload
    /// above.
    static func status(
        for status: TransferStatus
    ) -> TransferUIStatus {
        switch status {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    /// Average transfer speed, in bytes per second.
    ///
    /// We use the Core's own `startedAt` as the reference so the
    /// displayed value matches what the Core recorded in the
    /// history (the recorded value is `fileSize / duration`).
    ///
    /// The `referenceDate` parameter is exposed so unit tests can
    /// inject a deterministic clock without monkey-patching
    /// `Date()`. Production callers keep the default value, which
    /// behaves identically to the previous implementation.
    static func speed(
        for transfer: Transfer,
        referenceDate: Date = Date()
    ) -> Double {
        guard let startedAt = transfer.startedAt else { return 0 }
        let elapsed = referenceDate.timeIntervalSince(startedAt)
        guard elapsed > 0 else { return 0 }
        return Double(transfer.transferredBytes) / elapsed
    }

    /// Estimated time remaining, in seconds. `nil` when not enough
    /// data is available (no progress yet, or transfer just
    /// started).
    ///
    /// `referenceDate` follows the same injection rationale as
    /// `speed(for:referenceDate:)`.
    static func eta(
        for transfer: Transfer,
        referenceDate: Date = Date()
    ) -> TimeInterval? {
        guard transfer.fileSize > 0,
              transfer.transferredBytes > 0 else { return nil }
        let bytesPerSecond = speed(for: transfer, referenceDate: referenceDate)
        guard bytesPerSecond > 0 else { return nil }
        let remaining = Double(
            transfer.fileSize - transfer.transferredBytes
        )
        return remaining / bytesPerSecond
    }
}

// MARK: - TransferUIStatus helpers

private extension TransferUIStatus {

    /// Reverse mapping from the UI bucket back to a Core state.
    /// Used when building a synthetic `Transfer` for a history-only
    /// entry (no live record available).
    func toCoreState() -> Transfer.State {
        switch self {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .waiting: return .waitingForApproval
        case .active: return .transferring
        }
    }
}
