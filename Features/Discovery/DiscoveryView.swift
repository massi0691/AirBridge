//
//  DiscoveryView.swift
//  AirBridge
//
//  Main discovery screen. Replaces the legacy DeviceListView with a
//  radar-centric, AirDrop-inspired experience. Pure adapter: it only
//  reads from the ViewModel and forwards user gestures.
//

import SwiftUI
import OSLog
internal import UniformTypeIdentifiers

struct DiscoveryView: View {

    @Bindable var core: AirBridgeCore
    @State private var viewModel: DiscoveryViewModel?
    @State private var selectedDeviceID: UUID?
    @State private var isFileImporterPresented = false
    @State private var isFolderImporterPresented = false
    @State private var isRadarActive = true

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "ui.discovery"
    )

    @Environment(\.scenePhase)
    private var scenePhase

#if os(iOS)
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
#endif

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                Color.clear
                    .onAppear {
                        viewModel = DiscoveryViewModel(core: core)
                    }
            }
        }
        .navigationTitle("Appareils")
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .onAppear { isRadarActive = true }
        .onDisappear { isRadarActive = false }
        .onChange(of: scenePhase) { _, newPhase in
            // Pause the radar sweep whenever the scene is not active.
            // The sweep is a pure decoration — it costs a continuous
            // rotation animation, and freezing it when the user can't
            // see it saves GPU and battery. The view itself stays
            // mounted; only the sweep stops.
            isRadarActive = (newPhase == .active)
        }
    }

    /// True when the local device is currently linked to a remote peer.
    /// Reads directly from the core so the action bar (which lives in a
    /// `safeAreaInset` outside the `content` builder) can still consult
    /// the connection state.
    private var isConnected: Bool {
        core.connectionManager.connectedDevice != nil
    }

    @ViewBuilder
    private func content(viewModel: DiscoveryViewModel) -> some View {
        VStack(spacing: AirBridgeDesign.Spacing.md) {
            radarSection(viewModel: viewModel)
                .frame(maxWidth: .infinity)
                .frame(height: 340)

            statusRow(viewModel: viewModel)

            devicesList(viewModel: viewModel)
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.md)
    }

    // MARK: - Radar

    private func radarSection(viewModel: DiscoveryViewModel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: AirBridgeDesign.Radius.large)
                .fill(.regularMaterial)

            if viewModel.discoveredDevices.isEmpty {
                radarEmptyState
            } else {
                RadarView(
                    localDevice: viewModel.localDevice,
                    devices: viewModel.discoveredDevices,
                    connectedDevice: viewModel.connectedDevice,
                    trustedPeerIDs: trustedPeerIDs(viewModel: viewModel),
                    selectedDeviceID: $selectedDeviceID,
                    isActive: isRadarActive
                )
                .padding(AirBridgeDesign.Spacing.lg)
                .animation(
                    AirBridgeDesign.SpringAnimation.standard,
                    value: radarAnimationKey(viewModel: viewModel)
                )
            }
        }
    }

    /// Identifiant composite utilisé pour piloter l'animation des
    /// bulles du radar : on combine le nombre d'appareils et la liste
    /// triée de leurs IDs. Tant que la liste ne change pas, aucune
    /// animation n'est déclenchée ; dès qu'un appareil apparaît,
    /// disparaît ou change d'ID, la transition définie dans
    /// `RadarView` est appliquée avec le spring standard.
    private func radarAnimationKey(viewModel: DiscoveryViewModel) -> String {
        let ids = viewModel.discoveredDevices
            .map(\.id)
            .map(\.uuidString)
            .joined(separator: ",")
        return "\(viewModel.discoveredDevices.count)|\(ids)"
    }

    private var radarEmptyState: some View {
        VStack(spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Recherche d'appareils…")
                .font(AirBridgeDesign.Typography.callout)
                .foregroundStyle(.secondary)
            Text("Lance AirBridge sur un autre appareil connecté au même réseau.")
                .font(AirBridgeDesign.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AirBridgeDesign.Spacing.lg)
        }
        .padding(AirBridgeDesign.Spacing.lg)
    }

    // MARK: - Status

    private func statusRow(viewModel: DiscoveryViewModel) -> some View {
        HStack(spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: statusIcon(viewModel: viewModel))
                .foregroundStyle(statusColor(viewModel: viewModel))
            Text(statusText(viewModel: viewModel))
                .font(AirBridgeDesign.Typography.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.xs)
    }

    private func statusIcon(viewModel: DiscoveryViewModel) -> String {
        viewModel.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
    }

    private func statusColor(viewModel: DiscoveryViewModel) -> Color {
        viewModel.isConnected ? .green : .secondary
    }

    private func statusText(viewModel: DiscoveryViewModel) -> String {
        if let peer = viewModel.connectedDevice {
            return "Connecté à \(peer.name)"
        }
        return viewModel.connectionStateDescription
    }

    // MARK: - Devices list (compact)

    private func devicesList(viewModel: DiscoveryViewModel) -> some View {
        VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
            if !viewModel.discoveredDevices.isEmpty {
                Text("À proximité")
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, AirBridgeDesign.Spacing.xs)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AirBridgeDesign.Spacing.sm) {
                        ForEach(viewModel.discoveredDevices) { device in
                            deviceChip(device: device, viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, AirBridgeDesign.Spacing.xs)
                }
            }
        }
    }

    private func deviceChip(
        device: DiscoveredDevice,
        viewModel: DiscoveryViewModel
    ) -> some View {
        let isSelected = selectedDeviceID == device.id
        let isConnected = viewModel.isConnected(device.device)
        let kind = AirBridgeDesign.DeviceKind.from(model: device.device.model)

        return Button {
            if isConnected {
                viewModel.disconnect()
            } else if isSelected {
                viewModel.connect(to: device)
            } else {
                selectedDeviceID = device.id
            }
        } label: {
            VStack(spacing: AirBridgeDesign.Spacing.xs) {
                DeviceAvatarView(
                    kind: kind,
                    size: .medium,
                    state: isConnected ? .connected : (isSelected ? .selected : .idle)
                )
                Text(device.device.name)
                    .font(AirBridgeDesign.Typography.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 88)
                    .foregroundStyle(.primary)
                Text(isConnected ? "Connecté" : (isSelected ? "Sélectionné" : "Disponible"))
                    .font(AirBridgeDesign.Typography.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, AirBridgeDesign.Spacing.xs)
            .padding(.horizontal, AirBridgeDesign.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AirBridgeDesign.Radius.medium)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Trust

    /// Reads the pairing store. The store is not @Observable, so we read
    /// once per render via the ViewModel — the Settings screen already
    /// follows the same pattern.
    private func trustedPeerIDs(viewModel: DiscoveryViewModel) -> Set<UUID> {
        Set(
            core.pairingStore
                .loadAll()
                .filter { $0.value.trustState == .trusted }
                .keys
        )
    }

    // MARK: - Action bar

    private var actionBar: some View {
        FloatingActionBar {
            Button {
                isFileImporterPresented = true
            } label: {
                Label(
                    actionLabelWidth == .compact ? "Fichier" : "Choisir un fichier",
                    systemImage: "doc.badge.plus"
                )
                .frame(minHeight: AirBridgeDesign.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConnected)
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true,
                onCompletion: handleSelection
            )

            Button {
                isFolderImporterPresented = true
            } label: {
                Label(
                    actionLabelWidth == .compact ? "Dossier" : "Choisir un dossier",
                    systemImage: "folder.badge.plus"
                )
                .frame(minHeight: AirBridgeDesign.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .disabled(!isConnected)
            .fileImporter(
                isPresented: $isFolderImporterPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true,
                onCompletion: handleSelection
            )

            if isConnected {
                Button(role: .destructive) {
                    core.connectionManager.disconnect()
                } label: {
                    Label(
                        actionLabelWidth == .compact ? "Déco" : "Déconnecter",
                        systemImage: "xmark.circle"
                    )
                    .frame(minHeight: AirBridgeDesign.minimumTapTarget)
                }
            }
        }
    }

#if os(iOS)
    private var actionLabelWidth: ActionLabelWidth {
        horizontalSizeClass == .compact ? .compact : .full
    }
#else
    private var actionLabelWidth: ActionLabelWidth { .full }
#endif

    private func handleSelection(
        _ result: Result<[URL], Error>
    ) {
        switch result {
        case .success(let urls):
            core.importAndRequestItems(urls: urls)
        case .failure(let error):
            logger.error("Sélection impossible : \(error.localizedDescription, privacy: .public)")
        }
    }
}
