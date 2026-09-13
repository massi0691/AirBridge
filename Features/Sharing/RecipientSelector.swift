//
//  RecipientSelector.swift
//  AirBridge
//
//  Picker for the target device of a share.
//
//  Renders the recipients the ViewModel has already filtered (trusted
//  only, or all), with a toggle to flip between the two. Each row
//  shows the connection state so the user can see at a glance whether
//  picking a device actually targets an active session.
//

import SwiftUI

/// Picker for the target device of a share.
///
/// The selector is purely presentational : it reads its list of
/// candidates from the ViewModel and forwards the user's pick (and
/// the trusted-only toggle) back to it. It never opens a connection
/// or talks to the Core directly.
struct RecipientSelector: View {

    let recipients: [DiscoveredDevice]
    let connectedDeviceID: UUID?
    let showAll: Bool
    let trustedPeerIDs: Set<UUID>
    let onToggleShowAll: (Bool) -> Void
    let onSelect: (DiscoveredDevice) -> Void

    @State private var pickedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.sm) {
            HStack {
                Text("Destinataire")
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(
                    "Voir tous",
                    isOn: Binding(
                        get: { showAll },
                        set: { onToggleShowAll($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Afficher tous les appareils découverts")
            }
            .padding(.horizontal, AirBridgeDesign.Spacing.xs)

            if recipients.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AirBridgeDesign.Spacing.sm) {
                        ForEach(recipients) { device in
                            recipientChip(for: device)
                        }
                    }
                    .padding(.horizontal, AirBridgeDesign.Spacing.xs)
                }
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: AirBridgeDesign.Spacing.xs) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(emptyStateMessage)
                .font(AirBridgeDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AirBridgeDesign.Spacing.md)
    }

    private var emptyStateMessage: String {
        showAll
            ? "Aucun appareil à proximité."
            : "Aucun appareil de confiance à proximité."
    }

    private func recipientChip(
        for device: DiscoveredDevice
    ) -> some View {
        let isConnected = device.id == connectedDeviceID
        let isTrusted = trustedPeerIDs.contains(device.id)
        let isSelected = pickedID == device.id
        let kind = AirBridgeDesign.DeviceKind.from(
            model: device.device.model
        )

        return Button {
            pickedID = device.id
            // Discrete selection feedback: the user picked a chip
            // from the recipient strip.
            Haptics.selection()
            onSelect(device)
        } label: {
            VStack(spacing: AirBridgeDesign.Spacing.xs) {
                DeviceAvatarView(
                    kind: kind,
                    size: .medium,
                    state: avatarState(
                        isConnected: isConnected,
                        isSelected: isSelected,
                        isTrusted: isTrusted
                    )
                )

                Text(device.device.name)
                    .font(AirBridgeDesign.Typography.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 96)
                    .foregroundStyle(.primary)

                Text(stateLabel(
                    isConnected: isConnected,
                    isSelected: isSelected,
                    isTrusted: isTrusted
                ))
                    .font(AirBridgeDesign.Typography.caption2)
                    .foregroundStyle(stateColor(
                        isConnected: isConnected
                    ))
            }
            .padding(.vertical, AirBridgeDesign.Spacing.xs)
            .padding(.horizontal, AirBridgeDesign.Spacing.sm)
            .background(
                RoundedRectangle(
                    cornerRadius: AirBridgeDesign.Radius.medium
                )
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                "\(device.device.name), \(device.device.model)"
            )
        )
        .accessibilityValue(
            Text(stateLabel(
                isConnected: isConnected,
                isSelected: isSelected,
                isTrusted: isTrusted
            ))
        )
        .accessibilityAddTraits(
            isSelected ? .isSelected : []
        )
    }

    // MARK: - State helpers

    private func avatarState(
        isConnected: Bool,
        isSelected: Bool,
        isTrusted: Bool
    ) -> DeviceAvatarView.State {
        if isConnected { return .connected }
        if isSelected  { return .selected }
        if isTrusted   { return .trusted }
        return .idle
    }

    private func stateLabel(
        isConnected: Bool,
        isSelected: Bool,
        isTrusted: Bool
    ) -> String {
        if isConnected { return "Connecté" }
        if isSelected  { return "Sélectionné" }
        if isTrusted   { return "De confiance" }
        return "Disponible"
    }

    private func stateColor(
        isConnected: Bool
    ) -> Color {
        isConnected ? .green : .secondary
    }
}
