//
//  PairingDeviceCard.swift
//  AirBridge
//
//  Rich card for a single paired device. Surfaces the fingerprint and
//  trust state without inventing new identifiers.
//

import SwiftUI

/// Card representation of a paired device.
///
/// Surfaces the data already present in `PairingInfo` — peer name,
/// fingerprint, trust state, last seen — without inventing new
/// identifiers. Tap actions are routed through callbacks so the card
/// stays reusable.
struct PairingDeviceCard: View {

    let pairing: PairingInfo
    let kind: AirBridgeDesign.DeviceKind
    let onTrust: () -> Void
    let onBlock: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.sm) {
            header

            Divider()

            fingerprintRow

            Divider()

            actions
        }
        .padding(AirBridgeDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AirBridgeDesign.Radius.large)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AirBridgeDesign.Radius.large)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        // Hero-card entrance: the card lands instead of popping in.
        .transition(Transitions.cardAppear)
        .animation(
            AirBridgeDesign.SpringAnimation.standard,
            value: pairing.peerID
        )
    }

    private var header: some View {
        HStack(spacing: AirBridgeDesign.Spacing.md) {
            DeviceAvatarView(
                kind: kind,
                size: .medium,
                state: avatarState
            )
            VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
                Text(pairing.peerName)
                    .font(AirBridgeDesign.Typography.headline)
                Text(trustDescription)
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(trustColor)
            }
            Spacer()
        }
    }

    private var fingerprintRow: some View {
        VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
            Text("Empreinte")
                .font(AirBridgeDesign.Typography.caption)
                .foregroundStyle(.secondary)
            Text(pairing.peerFingerprint)
                .font(AirBridgeDesign.Typography.monoCaption)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var actions: some View {
        HStack(spacing: AirBridgeDesign.Spacing.sm) {
            if pairing.trustState != .trusted {
                Button {
                    onTrust()
                    // Positive terminal event from the user side:
                    // they explicitly cleared the device.
                    Haptics.success()
                } label: {
                    Label("Faire confiance", systemImage: "checkmark.shield.fill")
                        .frame(minHeight: AirBridgeDesign.minimumTapTarget)
                }
                .buttonStyle(.borderedProminent)
            }
            if pairing.trustState != .blocked {
                Button(role: .destructive) {
                    onBlock()
                    // Cautionary terminal event: the user actively
                    // revoked trust or removed a known device.
                    Haptics.warning()
                } label: {
                    Label("Bloquer", systemImage: "xmark.shield.fill")
                        .frame(minHeight: AirBridgeDesign.minimumTapTarget)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                onRemove()
                Haptics.warning()
            } label: {
                Label("Oublier", systemImage: "trash")
                    .frame(minHeight: AirBridgeDesign.minimumTapTarget)
            }
            .buttonStyle(.bordered)
        }
    }

    private var avatarState: DeviceAvatarView.State {
        switch pairing.trustState {
        case .trusted: .trusted
        case .blocked: .idle
        default: .idle
        }
    }

    private var trustDescription: String {
        switch pairing.trustState {
        case .trusted: "Appareil de confiance"
        case .pending: "En attente de confirmation"
        case .blocked: "Bloqué"
        case .unknown: "Non vérifié"
        }
    }

    private var trustColor: Color {
        switch pairing.trustState {
        case .trusted: .green
        case .pending: .orange
        case .blocked: .red
        case .unknown: .secondary
        }
    }
}