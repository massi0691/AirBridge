//
//  RadarFullScreenView.swift
//  AirBridge
//
//  Phase 1 — Radar immersif plein écran avec pairing automatique.
//  Transforme l'écran de découverte en expérience AirDrop-like :
//  fond élégant, appareils en bulles animées, sélection directe
//  pour pairing, feedback haptique et visuel.
//

import SwiftUI
import OSLog

/// Vue radar immersive plein écran remplaçant l'ancienne DiscoveryView.
///
/// Fonctionnalités :
/// - Fond sombre/gradient élégant
/// - Radar avec appareils en bulles arrondies
/// - Animations d'apparition/disparition (scale + opacity)
/// - Sélection tap → pairing automatique
/// - Modal de confirmation pairing
/// - Feedback haptique (détection, connexion, échec)
/// - État connecté avec indicateur visuel
struct RadarFullScreenView: View {

    @Bindable var core: AirBridgeCore
    @State private var viewModel: DiscoveryViewModel?
    @State private var pairingViewModel: PairingViewModel?
    @State private var selectedDeviceID: UUID?
    @State private var showPairingConfirmation = false
    @State private var showShareSheet = false
    @State private var isRadarActive = true
    @State private var connectionState: ConnectionState = .idle

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "ui.radar.fullscreen"
    )

    @Environment(\.scenePhase)
    private var scenePhase

    /// Conformance `Equatable` (synthétisée : enum sans valeur
    /// associée) — requise par les comparaisons
    /// `connectionState == .connecting` ; sans elle elles ne
    /// compilent pas.
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    // MARK: - Spacing (Phase 1 original values)

    /// Header padding - Phase 1 original
    private var headerPadding: CGFloat {
        AirBridgeDesign.Spacing.lg
    }

    /// Horizontal padding - Phase 1 original
    private var horizontalPadding: CGFloat {
        AirBridgeDesign.Spacing.md
    }

    /// Radar padding - Phase 1 original
    private var radarPadding: CGFloat {
        AirBridgeDesign.Spacing.lg
    }

    /// Header top padding - réduit pour minimiser la section haute
    private var headerTopPadding: CGFloat {
        #if os(iOS)
        20
        #else
        AirBridgeDesign.Spacing.sm
        #endif
    }

    /// Taille minimale du radar
    private let minRadarSize: CGFloat = 180
    /// Taille maximale du radar
    private let maxRadarSize: CGFloat = 500

    /// Calcule la taille adaptative du radar en fonction de l'espace disponible.
    /// - Parameter geometry: GeometryProxy du conteneur
    /// - Returns: Taille optimale du radar (carré)
    private func calculateRadarSize(for geometry: GeometryProxy) -> CGFloat {
        let availableWidth = geometry.size.width - (horizontalPadding * 2)
        let availableHeight = geometry.size.height - 160  // Header (~100) + Status (~60)

        // Prendre le minimum entre largeur et hauteur disponibles
        let maxPossibleSize = min(availableWidth, availableHeight)

        // Contraindre entre min et max
        return min(max(maxPossibleSize, minRadarSize), maxRadarSize)
    }

    var body: some View {
        Group {
            if let viewModel, let pairingViewModel {
                content(
                    viewModel: viewModel,
                    pairingViewModel: pairingViewModel
                )
            } else {
                Color.clear
                    .onAppear {
                        viewModel = DiscoveryViewModel(core: core)
                        pairingViewModel = PairingViewModel(core: core)
                    }
            }
        }
        .onAppear { isRadarActive = true }
        .onDisappear { isRadarActive = false }
        .onChange(of: scenePhase) { _, newPhase in
            isRadarActive = (newPhase == .active)
        }
        .onChange(of: core.connectionManager.connectedDevice) { oldDevice, newDevice in
            handleConnectionChange(oldDevice: oldDevice, newDevice: newDevice)
        }
    }

    @ViewBuilder
    private func content(
        viewModel: DiscoveryViewModel,
        pairingViewModel: PairingViewModel
    ) -> some View {
        GeometryReader { geometry in
            ZStack {
                // 1. Fond immersif en bas (ignore safe area)
                backgroundGradient
                    .ignoresSafeArea()

                // 2. Contenu en haut (respecte safe area)
                VStack(spacing: 0) {
                    // En-tête compact avec statut
                    headerSection(viewModel: viewModel)
                        .padding(.top, headerTopPadding)
                        .padding(.horizontal, horizontalPadding)

                    // Espace fixe réduit entre header et radar
                    Spacer()
                        .frame(height: 8)

                    // Radar central immersif - taille adaptative
                    radarSection(viewModel: viewModel)
                        .frame(
                            width: calculateRadarSize(for: geometry),
                            height: calculateRadarSize(for: geometry)
                        )
                        .padding(radarPadding)

                    // Espace restant : le radar reste centré verticalement
                    // entre l'en-tête et le pied de page.
                    Spacer()
                }
            }
            // Le radar est volontairement sombre (fond noir, textes clairs en
            // dur). La bulle `DeviceRadarItem`, elle, utilise `.primary`/
            // `.secondary` : sans lumières forcées, `.primary` serait noir en
            // mode clair système et la bulle deviendrait invisible. On force
            // donc le mode sombre sur le contenu du radar uniquement — les
            // sheets présentées au-dessus (`PairingConfirmationView`,
            // `ShareView`) gardent leur propre style système.
            .preferredColorScheme(.dark)
        }
        // Pied de page ancré au-dessus de la TabBar / de la home indicator
        // via l'inset de safe area : aucune hauteur fixe codée en dur
        // (l'ancien `bottomSafeArea = 60`). Le layout suit donc la vraie
        // surface disponible, en portrait comme en paysage.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomStatusSection(viewModel: viewModel)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, AirBridgeDesign.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showPairingConfirmation) {
            PairingConfirmationView(core: core)
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareView(core: core)
                .presentationBackground(.ultraThinMaterial)
        }
        // Observer la sélection d'appareil pour déclencher le pairing
        .onChange(of: selectedDeviceID) { _, newDeviceID in
            guard let deviceID = newDeviceID,
                  let device = viewModel.discoveredDevices.first(where: { $0.id == deviceID }) else {
                return
            }
            handleDeviceSelection(device: device, viewModel: viewModel)
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            // Fond sombre de base
            Color.black
                .ignoresSafeArea()

            // Gradient radial depuis le centre
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.15),
                    Color.accentColor.opacity(0.08),
                    Color.clear
                ],
                center: .center,
                startRadius: 50,
                endRadius: 400
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()

            // Particules subtiles (étoiles)
            particlesBackground
        }
    }

    private var particlesBackground: some View {
        // Solution contre le layout récursif : GeometryReader externe
        // Le Canvas n'a pas besoin de GeometryReader - il a accès à la taille
        Canvas { context, size in
            for i in 0..<30 {
                let hash = abs(i.hashValue)
                let x = CGFloat((hash & 0xFF)) / 255.0 * size.width
                let y = CGFloat(((hash >> 8) & 0xFF)) / 255.0 * size.height
                let opacity = Double(((hash >> 16) & 0xFF)) / 255.0 * 0.3 + 0.1

                context.opacity = opacity
                context.fill(
                    Circle().path(in: CGRect(x: x, y: y, width: 2, height: 2)),
                    with: .color(.white)
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private func headerSection(viewModel: DiscoveryViewModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
                Text("AirBridge")
                    .font(AirBridgeDesign.Typography.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                HStack(spacing: AirBridgeDesign.Spacing.xs) {
                    statusIndicator(viewModel: viewModel)
                    Text(statusText(viewModel: viewModel))
                        .font(AirBridgeDesign.Typography.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            // Badge nombre d'appareils
            if !viewModel.discoveredDevices.isEmpty {
                Text("\(viewModel.discoveredDevices.count)")
                    .font(AirBridgeDesign.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.3))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    )
            }
        }
    }

    private func statusIndicator(viewModel: DiscoveryViewModel) -> some View {
        Circle()
            .fill(statusColor(viewModel: viewModel))
            .frame(width: 8, height: 8)
            .shadow(color: statusColor(viewModel: viewModel), radius: 4)
    }

    private func statusColor(viewModel: DiscoveryViewModel) -> Color {
        if viewModel.isConnected {
            return .green
        } else if connectionState == .connecting {
            return .orange
        } else {
            return .secondary
        }
    }

    private func statusText(viewModel: DiscoveryViewModel) -> String {
        if let peer = viewModel.connectedDevice {
            return "Connecté à \(peer.name)"
        } else if connectionState == .connecting {
            return "Connexion en cours..."
        } else if viewModel.discoveredDevices.isEmpty {
            return "Recherche d'appareils..."
        } else {
            let count = viewModel.discoveredDevices.count
            return count == 1 ? "1 appareil trouvé" : "\(count) appareils trouvés"
        }
    }

    // MARK: - Radar

    private func radarSection(viewModel: DiscoveryViewModel) -> some View {
        ZStack {
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
                .animation(
                    AirBridgeDesign.SpringAnimation.standard,
                    value: radarAnimationKey(viewModel: viewModel)
                )
                .onAppear {
                    // Feedback haptique à la détection du premier appareil
                    if !viewModel.discoveredDevices.isEmpty {
                        Haptics.impact(.light)
                    }
                }
                .onChange(of: viewModel.discoveredDevices.count) { oldCount, newCount in
                    // Feedback haptique quand un nouvel appareil apparaît
                    if newCount > oldCount {
                        Haptics.impact(.light)
                    }
                }
                .overlay {
                    // Overlay de sélection pour pairing
                    radarSelectionOverlay(viewModel: viewModel)
                }
            }
        }
    }

    private var radarEmptyState: some View {
        VStack(spacing: AirBridgeDesign.Spacing.lg) {
            // Animation pulse sur l'icône
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .scaleEffect(isRadarActive ? 1.2 : 1.0)
                    .opacity(isRadarActive ? 0.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: false),
                        value: isRadarActive
                    )

                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
            }

            VStack(spacing: AirBridgeDesign.Spacing.sm) {
                Text("En attente d'appareils...")
                    .font(AirBridgeDesign.Typography.title3)
                    .foregroundStyle(.white)

                Text("Lance AirBridge sur un autre appareil\nconnecté au même réseau.")
                    .font(AirBridgeDesign.Typography.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func radarSelectionOverlay(viewModel: DiscoveryViewModel) -> some View {
        // Effet de rapprochement animé pour l'appareil sélectionné
        if let selectedID = selectedDeviceID,
           connectionState == .connecting {

            GeometryReader { proxy in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

                // Anneau de connexion pulsant autour de l'appareil sélectionné
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .position(center)
                    .scaleEffect(isRadarActive ? 1.3 : 1.0)
                    .opacity(isRadarActive ? 0.0 : 0.8)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: false),
                        value: isRadarActive
                    )
            }
        }
    }

    private func radarAnimationKey(viewModel: DiscoveryViewModel) -> String {
        let ids = viewModel.discoveredDevices
            .map(\.id)
            .map(\.uuidString)
            .joined(separator: ",")
        return "\(viewModel.discoveredDevices.count)|\(ids)"
    }

    // MARK: - Bottom Status

    private func bottomStatusSection(viewModel: DiscoveryViewModel) -> some View {
        HStack(spacing: AirBridgeDesign.Spacing.md) {
            if viewModel.isConnected {
                // Bouton Envoyer des fichiers
                Button {
                    showShareSheet = true
                    Haptics.impact(.light)
                } label: {
                    Label("Envoyer des fichiers", systemImage: "square.and.arrow.up")
                        .font(AirBridgeDesign.Typography.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, AirBridgeDesign.Spacing.md)
                        .padding(.vertical, AirBridgeDesign.Spacing.sm)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.3))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                // Bouton Déconnecter
                Button(role: .destructive) {
                    viewModel.disconnect()
                    Haptics.warning()
                } label: {
                    Label("Déconnecter", systemImage: "xmark.circle.fill")
                        .font(AirBridgeDesign.Typography.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, AirBridgeDesign.Spacing.md)
                        .padding(.vertical, AirBridgeDesign.Spacing.sm)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.3))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Device Selection & Pairing

    private func handleDeviceSelection(
        device: DiscoveredDevice,
        viewModel: DiscoveryViewModel
    ) {
        logger.info("Appareil sélectionné : \(device.device.name, privacy: .public)")

        // Désactiver les autres appareils pendant pairing
        guard connectionState != .connecting else {
            logger.debug("Connexion déjà en cours, sélection ignorée")
            return
        }

        // Si déjà connecté à cet appareil, ne rien faire
        if viewModel.connectedDevice?.id == device.id {
            logger.debug("Déjà connecté à cet appareil")
            return
        }

        // Si connecté à un autre appareil, déconnecter d'abord
        if viewModel.isConnected {
            viewModel.disconnect()
        }

        // Démarrer la connexion
        connectionState = .connecting
        selectedDeviceID = device.id
        Haptics.impact(.medium)

        viewModel.connect(to: device)

        logger.info("Connexion démarrée vers \(device.device.name, privacy: .public)")
    }

    private func handleConnectionChange(
        oldDevice: Device?,
        newDevice: Device?
    ) {
        if let newDevice, oldDevice == nil {
            // Connexion établie
            connectionState = .connected
            Haptics.success()
            logger.info("Connexion établie avec \(newDevice.name, privacy: .public)")

            // Vérifier si pairing nécessaire
            if let pairingVM = pairingViewModel, pairingVM.currentPeerNeedsPairing {
                // Pairing automatique
                showPairingConfirmation = true
                logger.info("Pairing requis, affichage de la confirmation")
            }

        } else if newDevice == nil, oldDevice != nil {
            // Déconnexion
            connectionState = .idle
            selectedDeviceID = nil
            showPairingConfirmation = false
            logger.info("Déconnexion de \(oldDevice!.name, privacy: .public)")

        } else if let oldDev = oldDevice, let newDev = newDevice, oldDev.id != newDev.id {
            // Changement d'appareil connecté
            connectionState = .connected
            selectedDeviceID = newDev.id
            logger.info("Appareil connecté changé : \(newDev.name, privacy: .public)")

            if let pairingVM = pairingViewModel, pairingVM.currentPeerNeedsPairing {
                showPairingConfirmation = true
            }
        }
    }

    // MARK: - Trust

    private func trustedPeerIDs(viewModel: DiscoveryViewModel) -> Set<UUID> {
        Set(
            core.pairingStore
                .loadAll()
                .filter { $0.value.trustState == .trusted }
                .keys
        )
    }
}
