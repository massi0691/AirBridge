//
//  PairingConfirmationView.swift
//  AirBridge
//
//  Modal shown when the user connects to an untrusted peer. The view
//  only ever displays data the Core already produced — it never invents
//  a verification code, never generates a key, never modifies the
//  handshake.
//

import SwiftUI

/// Confirmation prompt for a new pairing.
///
/// Surfaces the peer's identity, the existing fingerprint (if a record
/// is present), and the two possible actions: trust or block. The view
/// does NOT compute or display a 6-digit code — that data must come
/// from the Core. If the Core doesn't have it, we simply don't show it.
struct PairingConfirmationView: View {

    @Bindable var core: AirBridgeCore
    @State private var viewModel: PairingViewModel?

    /// Stores the initial public key when the view appears.
    /// Used to detect if the key changed during the session.
    @State private var initialPublicKeyData: Data?

    /// Tracks whether we've detected a key change.
    @State private var hasKeyChanged: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                Color.clear
                    .onAppear {
                        viewModel = PairingViewModel(core: core)
                        // Capture initial public key for change detection
                        if let peer = core.connectionManager.connectedDevice,
                           let info = core.pairingStore.pairing(for: peer.id) {
                            initialPublicKeyData = info.peerPublicKeyData
                        }
                    }
            }
        }
        .interactiveDismissDisabled()
        // Modal-style surface: scale + fade, treated as a single
        // transition unit so the sheet feels focused, not flicked.
        .transition(Transitions.alertAppear)
        .animation(
            AirBridgeDesign.SpringAnimation.standard,
            value: viewModel != nil
        )
        .alert("Clé de sécurité changée", isPresented: $hasKeyChanged) {
            Button("Continuer quand même", role: .destructive) {
                // User accepts the new key - update trust
                viewModel?.recordCurrentPublicKey()
                viewModel?.trustCurrentPeer()
                Haptics.success()
                dismiss()
            }
            Button("Annuler", role: .cancel) {
                viewModel?.blockCurrentPeer()
                Haptics.warning()
                dismiss()
            }
        } message: {
            Text("Les identifiants de sécurité de \(viewModel?.currentPeerName ?? "cet appareil") ont changé. Voulez-vous continuer ?")
        }
    }

    @ViewBuilder
    private func content(viewModel: PairingViewModel) -> some View {
        let peer = core.connectionManager.connectedDevice
        if let peer {
            NavigationStack {
                VStack(spacing: AirBridgeDesign.Spacing.lg) {
                    header(for: peer)

                    if let fingerprint = viewModel.currentPeerFingerprint {
                        fingerprintSection(fingerprint: fingerprint)
                    } else {
                        explanationSection
                    }
                    actions(viewModel: viewModel)
                    Spacer(minLength: 0)
                }
                .padding(AirBridgeDesign.Spacing.lg)
                .frame(maxWidth: 480)
                .navigationTitle("Appairage")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
            .onAppear {
                // Capture initial public key for change detection
                if let peer = core.connectionManager.connectedDevice,
                   let info = core.pairingStore.pairing(for: peer.id) {
                    initialPublicKeyData = info.peerPublicKeyData
                }
                checkForKeyChange(viewModel: viewModel)
            }
            .onChange(of: viewModel.pairingStoreVersion) { _, _ in
                // PairingStore was modified (key change, trust state change, etc.)
                // Re-check if the public key has changed
                checkForKeyChange(viewModel: viewModel)
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        } else {
            ContentUnavailableView(
                "Aucun pair connecté",
                systemImage: "person.fill.questionmark",
                description: Text("Connecte-toi à un appareil pour l'appairer.")
            )
        }
    }

    /// Detects if the peer's public key has changed since the view appeared.
    private func checkForKeyChange(viewModel: PairingViewModel) {
        guard let peer = core.connectionManager.connectedDevice,
              let currentInfo = core.pairingStore.pairing(for: peer.id) else {
            return
        }

        // Compare with initial key
        if let initial = initialPublicKeyData,
           initial != currentInfo.peerPublicKeyData {
            hasKeyChanged = true
        }
    }

    private func header(for peer: Device) -> some View {
        VStack(spacing: AirBridgeDesign.Spacing.md) {
            DeviceAvatarView(
                kind: AirBridgeDesign.DeviceKind.from(model: peer.model),
                size: .large,
                state: .selected
            )
            VStack(spacing: AirBridgeDesign.Spacing.xs) {
                Text(peer.name)
                    .font(AirBridgeDesign.Typography.title3)
                Text(peer.model)
                    .font(AirBridgeDesign.Typography.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, AirBridgeDesign.Spacing.md)
    }

    private func fingerprintSection(fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.sm) {
            HStack {
                Text("Empreinte de l'appareil")
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasKeyChanged {
                    Label("Nouvelle clé", systemImage: "exclamationmark.triangle.fill")
                        .font(AirBridgeDesign.Typography.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(fingerprint)
                .font(AirBridgeDesign.Typography.monoBody)
                .textSelection(.enabled)
                .padding(AirBridgeDesign.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AirBridgeDesign.Radius.medium)
                        .fill(.regularMaterial)
                )
            if hasKeyChanged {
                Text("⚠️ Cette empreinte est différente de celle enregistrée. Vérifie avec l'autre appareil avant de continuer.")
                    .font(AirBridgeDesign.Typography.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("Vérifie cette empreinte sur l'autre appareil avant de faire confiance.")
                    .font(AirBridgeDesign.Typography.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var explanationSection: some View {
        VStack(spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Cet appareil n'est pas encore de confiance.")
                .font(AirBridgeDesign.Typography.callout)
                .multilineTextAlignment(.center)
            Text("Faire confiance permettera à cet appareil de se reconnecter automatiquement à l'avenir.")
                .font(AirBridgeDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.md)
    }

    private func actions(viewModel: PairingViewModel) -> some View {
        HStack(spacing: AirBridgeDesign.Spacing.md) {
            Button(role: .destructive) {
                if let peer = core.connectionManager.connectedDevice {
                    viewModel.block(peerID: peer.id)
                }
                // Cautionary terminal event: the user actively
                // refused to trust the connected peer.
                Haptics.warning()
                dismiss()
            } label: {
                Label("Bloquer", systemImage: "xmark.shield.fill")
                    .frame(maxWidth: .infinity, minHeight: AirBridgeDesign.minimumTapTarget)
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.trustCurrentPeer()
                // Positive terminal event: the user accepted the
                // peer; a small success notification mirrors that.
                Haptics.success()
                dismiss()
            } label: {
                Label("Faire confiance", systemImage: "checkmark.shield.fill")
                    .frame(maxWidth: .infinity, minHeight: AirBridgeDesign.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, AirBridgeDesign.Spacing.sm)
    }
}