//
//  TransferProgressView.swift
//  AirBridge
//
//  Single transfer row / card. Renders a `TransferUIModel` with its
//  progress, status, and the matching Cancel / Retry action.
//

import SwiftUI

/// Progress card for a single transfer.
///
/// Shows the file icon + name, a linear progress bar, the live
/// percentage, instantaneous speed, ETA, and a status badge. A
/// trailing action button exposes Cancel (while the transfer is
/// active) or Retry (when the Core marks the transfer as
/// retryable).
///
/// The card is a pure view : it never reaches into the Core. The
/// ViewModel decides what to render, the card just displays.
struct TransferProgressView: View {

    /// Layout flavour for the card. The "Actifs" tab uses a row
    /// (compact, slides in from the leading edge) and the
    /// "Terminés" tab uses a hero card (full-bleed, lands from
    /// below).
    enum Layout {
        case activeRow
        case completedCard
    }

    let model: TransferUIModel
    let layout: Layout
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AirBridgeDesign.Spacing.md) {
            fileIcon
            VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
                header
                progressBar
                footer
            }
            Spacer(minLength: 0)
            trailingAction
        }
        .padding(AirBridgeDesign.Spacing.md)
        .background(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.large
            )
            .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.large
            )
            .stroke(
                Color.secondary.opacity(0.15),
                lineWidth: 1
            )
        )
        // Active rows slide in from the leading edge, completed
        // cards land from below. The Core never emits a
        // transition event ; the SwiftUI render cycle picks the
        // change up automatically and the right transition runs.
        .transition(
            layout == .activeRow
                ? Transitions.rowAppear
                : Transitions.cardAppear
        )
        .animation(
            AirBridgeDesign.SpringAnimation.standard,
            value: statusTag
        )
        // The Core doesn't expose a transfer-state event stream
        // (no `AsyncStream<TransferState>` on `TransferManager`).
        // We instead observe the `@Observable` projection directly
        // — this is reactive (driven by the Core's mutations), not
        // polling — so we still fire the right haptic at the
        // moment the state flips.
        .onChange(of: statusTag, initial: false) { (_, newTag) in
            fireHaptic(for: newTag)
        }
        .accessibilityElement(children: .contain)
    }

    /// `Equatable`-friendly projection of `model.status`, used as
    /// the observation key for `.animation(_:value:)` and
    /// `.onChange(of:)`. We can't observe `TransferUIStatus`
    /// directly because the enum doesn't conform to `Equatable` and
    /// we deliberately keep the ViewModel untouched. The tag wraps
    /// the bucket in a struct whose `Equatable` is auto-synthesised.
    private var statusTag: StatusTag {
        StatusTag(model.status)
    }

    /// Wrapper that conforms to `Equatable` and `Hashable` so it can
    /// drive `SwiftUI`'s value-based observation APIs.
    private struct StatusTag: Equatable, Hashable {
        static let waitingRaw = 0
        static let activeRaw = 1
        static let completedRaw = 2
        static let failedRaw = 3
        static let cancelledRaw = 4

        let raw: Int
        init(_ status: TransferUIStatus) {
            switch status {
            case .waiting:   self.raw = StatusTag.waitingRaw
            case .active:    self.raw = StatusTag.activeRaw
            case .completed: self.raw = StatusTag.completedRaw
            case .failed:    self.raw = StatusTag.failedRaw
            case .cancelled: self.raw = StatusTag.cancelledRaw
            }
        }
    }

    /// Dispatches the haptic for a status transition. Extracted so
    /// `.onChange(of:initial:)` can call it without the Swift type
    /// system confusing the closure signature with the legacy
    /// `() -> Void` overload.
    private func fireHaptic(for tag: StatusTag) {
        switch tag.raw {
        case StatusTag.completedRaw: Haptics.success()
        case StatusTag.cancelledRaw: Haptics.warning()
        case StatusTag.failedRaw:    Haptics.error()
        default:
            // `.waiting` (0) and `.active` (1) — intermediate
            // states, no haptic.
            break
        }
    }

    // MARK: - Subviews

    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium
            )
            .fill(model.status.tint.opacity(0.12))
            .frame(
                width: 44,
                height: 44
            )
            Image(systemName: model.direction == .incoming
                ? "arrow.down.doc.fill"
                : "arrow.up.doc.fill")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(model.status.tint)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AirBridgeDesign.Spacing.sm) {
            Text(model.fileName)
                .font(AirBridgeDesign.Typography.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            TransferStatusView(status: model.status)
        }
    }

    /// Bloc central de la card : trois lignes aérées pour rendre
    /// le pourcentage, le débit et le temps restant lisibles d'un
    /// coup d'œil sur iPhone. L'ancien layout 1-ligne regroupait
    /// `% • taille … speed • eta` en `.caption2`/`.caption`, ce
    /// qui devenait trop dense à distance de bras.
    ///
    /// Ligne 1 : pourcentage en grand + badge de débit tinté
    /// (visible uniquement pendant un transfert actif).
    /// Ligne 2 : barre de progression fine.
    /// Ligne 3 : taille transférée (toujours visible) + temps
    /// restant (uniquement pendant un transfert actif).
    private var progressBar: some View {
        VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
            // Ligne 1 : % grand + badge de débit tinté. Le badge
            // n'apparaît que pendant un transfert actif avec un
            // débit strictement positif : avant le premier chunk,
            // `model.speed` est à 0, on évite donc d'afficher un
            // "0.0 Mb/s" trompeur.
            HStack(alignment: .firstTextBaseline, spacing: AirBridgeDesign.Spacing.sm) {
                Text(percentString)
                    .font(AirBridgeDesign.Typography.headline)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(
                        AirBridgeDesign.AnimationCurve.quick,
                        value: model.progress
                    )
                if model.status == .active, model.speed > 0 {
                    speedBadge
                }
                Spacer(minLength: 0)
            }
            // Ligne 2 : barre de progression fine, tintée par
            // l'état. Le tint reflète l'état logique du transfert
            // (accent pendant l'envoi, success à la fin, etc.).
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(model.status.tint)
            // Ligne 3 : taille toujours visible à gauche, temps
            // restant à droite uniquement quand l'ETA est connue
            // (début de transfert, taille totale nulle, débit nul
            // → pas d'ETA exploitable, on n'invente rien).
            HStack(spacing: AirBridgeDesign.Spacing.sm) {
                Text(sizeString)
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if model.status == .active,
                   let eta = model.eta,
                   eta.isFinite,
                   eta > 0 {
                    Text("Restant \(etaString(eta))")
                        .font(AirBridgeDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Badge de débit affiché sur la ligne 1 du `progressBar`.
    /// Tinté par `model.status.tint` pour rester cohérent avec la
    /// barre et le `fileIcon`, capsule à faible opacité pour ne
    /// pas concurrencer le pourcentage visuellement.
    @ViewBuilder
    private var speedBadge: some View {
        let tint = model.status.tint
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 10, weight: .semibold))
            Text(speedString)
                .font(AirBridgeDesign.Typography.caption)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, AirBridgeDesign.Spacing.sm)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tint.opacity(0.12))
        )
        .accessibilityLabel("Débit \(speedString)")
    }

    private var footer: some View {
        HStack(spacing: AirBridgeDesign.Spacing.xs) {
            DeviceAvatarView(
                kind: AirBridgeDesign.DeviceKind.from(
                    model: model.peer.model
                ),
                size: .small,
                state: .idle
            )
            Text(peerLabel)
                .font(AirBridgeDesign.Typography.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch model.status {
        case .active, .waiting:
            Button(role: .destructive) {
                onCancel()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        .white,
                        AirBridgeDesign.Color.error
                    )
            }
            .buttonStyle(.plain)
            .frame(
                width: AirBridgeDesign.minimumTapTarget,
                height: AirBridgeDesign.minimumTapTarget
            )
            .accessibilityLabel("Annuler le transfert")

        case .failed:
            // Only interrupted transfers are retryable. The
            // ViewModel exposes `canRetry(_:)` for this, but the
            // card is a pure view that operates on the model
            // alone : the Core state is read from the embedded
            // `model.core` payload.
            if model.core.state == .interrupted {
                Button {
                    onRetry()
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            .white,
                            AirBridgeDesign.Color.accent
                        )
                }
                .buttonStyle(.plain)
                .frame(
                    width: AirBridgeDesign.minimumTapTarget,
                    height: AirBridgeDesign.minimumTapTarget
                )
                .accessibilityLabel("Réessayer le transfert")
            } else {
                EmptyView()
            }

        case .completed, .cancelled:
            // Terminal states : no action button. The row can
            // still be tapped to show details, but the
            // progress card stays visually quiet.
            EmptyView()
        }
    }

    // MARK: - Strings

    private var percentString: String {
        let percent = Int((model.progress * 100).rounded())
        return "\(percent) %"
    }

    private var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let transferred = formatter.string(
            fromByteCount: model.transferredBytes
        )
        let total = formatter.string(
            fromByteCount: model.totalBytes
        )
        return "\(transferred) / \(total)"
    }

    private var speedString: String {
        // `model.speed` is in bytes per second. Surface a value
        // in the most appropriate unit (KB/s, MB/s) so the user
        // does not have to do mental math.
        let bytesPerSecond = model.speed
        let megabits = bytesPerSecond * 8 / 1_000_000
        if megabits >= 1 {
            return String(
                format: "%.1f Mb/s",
                megabits
            )
        }
        let kilobytes = bytesPerSecond / 1_024
        return String(
            format: "%.0f Ko/s",
            kilobytes
        )
    }

    private func etaString(_ eta: TimeInterval) -> String {
        let totalSeconds = Int(eta.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(
                format: "%dh %02dm",
                hours,
                minutes
            )
        }
        if minutes > 0 {
            return String(
                format: "%dm %02ds",
                minutes,
                seconds
            )
        }
        return String(format: "%ds", seconds)
    }

    private var peerLabel: String {
        switch model.direction {
        case .incoming:
            return "De \(model.peer.name)"
        case .outgoing:
            return "Vers \(model.peer.name)"
        }
    }
}

private extension TransferUIStatus {

    /// Tint used by the file icon and the progress bar. The
    /// `TransferStatusView` has its own copy of the tint logic,
    /// intentionally duplicated to keep each view self-contained.
    var tint: Color {
        switch self {
        case .waiting: AirBridgeDesign.Color.info
        case .active: AirBridgeDesign.Color.accent
        case .completed: AirBridgeDesign.Color.success
        case .failed: AirBridgeDesign.Color.warning
        case .cancelled: AirBridgeDesign.Color.error
        }
    }
}

#if DEBUG
#Preview("Transfer progress") {
    let device = Device(
        id: UUID(),
        name: "Mac de Marie",
        model: "MacBook Pro",
        systemVersion: "15.0"
    )
    let model = TransferUIModel(
        id: UUID(),
        fileName: "Document.pdf",
        totalBytes: 12_582_912,
        transferredBytes: 6_291_456,
        progress: 0.5,
        speed: 1_572_864,
        eta: 4,
        status: .active,
        direction: .incoming,
        peer: device,
        startDate: nil,
        core: Transfer(
            id: UUID(),
            peer: device,
            fileName: "Document.pdf",
            fileSize: 12_582_912,
            direction: .incoming,
            state: .transferring,
            transferredBytes: 6_291_456
        )
    )
    TransferProgressView(
        model: model,
        layout: .activeRow,
        onCancel: { },
        onRetry: { }
    )
    .padding()
}
#endif
