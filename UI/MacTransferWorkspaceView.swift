//
//  MacTransferWorkspaceView.swift
//  AirBridge
//
//  Espace de travail macOS : sidebar NavigationSplitView (résumé de
//  connexion + filtres), zone de dépôt avec Material, et tableau des
//  transferts (Fichier / Appareil / Progression / Débit / État /
//  Action).
//
//  Interface de présentation uniquement : aucun accès direct au moteur
//  de transfert en écriture — les actions passent par les mêmes API
//  publiques du Core que `MainView` (cancel / resume /
//  importAndRequestItems), et les états affichés sont ceux du Core.
//
//  Reduce Motion : les animations de la zone de dépôt sont désactivées
//  quand `accessibilityReduceMotion` est actif.
//

#if os(macOS)

import SwiftUI
import AppKit
internal import UniformTypeIdentifiers

/// Sections de la sidebar macOS, pilotées depuis `MacTransferWorkspaceView`.
///
/// Deux sections ne pilotent pas le tableau des transferts :
///   - `.devices` : découverte Bonjour, connexion et appairage. C'est la
///     seule surface capable d'OUVRIR une session depuis le Mac (le reste
///     de l'application — zone de dépôt, sélecteur de fichiers, partage —
///     refuse d'agir tant qu'aucune session n'est établie).
///   - `.settings` : réglages de l'application (dossier de réception,
///     notifications, appareils appairés). Sans cette entrée, `SettingsView`
///     n'était atteignable que depuis `MainView`, qui n'est plus montée sur
///     macOS depuis le passage à cet espace de travail.
enum MacTransferFilter: String, CaseIterable, Identifiable, Hashable {
    /// Découverte / connexion / appairage (radar).
    case devices

    /// Transferts vivants non terminaux (envoi, réception, attente de
    /// confirmation comprise).
    case active

    /// Tous les transferts vivants connus du Core.
    case all

    /// Journal des transferts terminés (`transferHistoryStore`).
    case history

    /// Réglages de l'application.
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: "Appareils"
        case .active: "En cours"
        case .all: "Tous"
        case .history: "Historique"
        case .settings: "Réglages"
        }
    }

    var symbolName: String {
        switch self {
        case .devices: "antenna.radiowaves.left.and.right"
        case .active: "arrow.triangle.2.circlepath"
        case .all: "tray.full"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// Ligne du tableau : projection `TransferUIModel` (vivante ou
/// historique) mise en forme pour les colonnes. Les actions gardent
/// une référence au transfert Core porté par le modèle.
struct MacTransferRow: Identifiable {
    let id: UUID
    let fileName: String
    let sizeLabel: String
    let peerName: String
    let peerSymbolName: String
    let direction: TransferUIDirection
    let status: TransferUIStatus

    /// `nil` pour les entrées purement historiques (pas de barre).
    let progress: Double?

    /// Texte de progression : « 47 % », ou
    /// « 100 % — Validation du récepteur… » pendant la fenêtre de
    /// confirmation — volontairement distinct de « Réussi ».
    let progressLabel: String

    /// Débit formaté, `nil` hors envoi actif.
    let speedLabel: String?

    /// Transfert Core porteur (synthétique pour l'historique).
    let core: Transfer
}

/// Espace de travail macOS principal.
struct MacTransferWorkspaceView: View {

    @Bindable var core: AirBridgeCore

    /// Contrôleur du lot stationné par une extension de partage
    /// (Finder Service / Share Extension). Injection explicite depuis
    /// `AirBridgeApp`, même contrat que `MainView`.
    let pendingShareController: PendingShareController

    @State private var viewModel: TransferViewModel?

    /// Sélection de la sidebar. Optionnelle comme la sélection de
    /// `MainView` (initialiseur `List(_:selection:)` à sélection
    /// unique) ; `effectiveFilter` retombe sur « Appareils » si la
    /// sélection est momentanément vide.
    ///
    /// L'ouverture se fait sur « Appareils » (comme l'onglet par défaut
    /// de l'UI iPhone) : c'est le point d'entrée qui permet de lier un
    /// appareil, sans quoi l'utilisateur ne voit qu'un tableau vide et
    /// une zone de dépôt désactivée.
    @State private var filter: MacTransferFilter? = .devices

    private var effectiveFilter: MacTransferFilter {
        filter ?? .devices
    }

    @State private var isDropTargeted = false
    @State private var isImporterPresented = false

    @State private var presentedRequest: TransferRequestPresentation?

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            workspaceDetail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 520)
        .sheet(item: $presentedRequest) { _ in
            TransferRequestSheet(core: core)
        }
        .sheet(item: pendingShareBinding) { item in
            // Lot stationné par une extension : présentation de la
            // surface d'envoi EXISTANTE, sans envoi automatique.
            PendingShareSheetView(
                core: core,
                item: item,
                controller: pendingShareController
            )
        }
        .onChange(
            of: core.pendingTransferBatch?.id,
            initial: true
        ) { _, newValue in
            synchronizeRequestSheet(batchID: newValue)
        }
        .onAppear {
            // Créé ici (et non dans `init`) : `TransferViewModel`
            // démarre une tâche de fond liée à sa durée de vie.
            if viewModel == nil {
                viewModel = TransferViewModel(core: core)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            connectionSummary
                .padding(AirBridgeDesign.Spacing.md)
            Divider()
            // Même pattern que `MainView` : NavigationLink(value:)
            // pilote la sélection de la sidebar.
            List(
                MacTransferFilter.allCases,
                selection: $filter
            ) { item in
                NavigationLink(value: item) {
                    Label(
                        item.title,
                        systemImage: item.symbolName
                    )
                    .badge(badgeCount(for: item))
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("AirBridge")
    }

    /// Résumé de connexion : appareil lié et état de la session
    /// sécurisée, ou invitation à se connecter.
    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
            if let device = core.connectionManager.connectedDevice {
                Label {
                    Text(device.name)
                        .font(AirBridgeDesign.Typography.headline)
                } icon: {
                    Image(
                        systemName: AirBridgeDesign.DeviceKind
                            .from(model: device.model)
                            .symbolName
                    )
                    .foregroundStyle(AirBridgeDesign.Color.accent)
                }
                Text(device.model)
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)

                Label {
                    Text(
                        core.connectionManager.isSecureSessionReady
                            ? "Session sécurisée"
                            : "Session non sécurisée"
                    )
                    .font(AirBridgeDesign.Typography.caption)
                } icon: {
                    Image(
                        systemName: core.connectionManager
                            .isSecureSessionReady
                            ? "lock.shield.fill"
                            : "lock.open"
                    )
                    .foregroundStyle(
                        core.connectionManager.isSecureSessionReady
                            ? AirBridgeDesign.Color.success
                            : AirBridgeDesign.Color.warning
                    )
                }
            } else {
                Label(
                    "Aucun appareil connecté",
                    systemImage: "antenna.radiowaves.left.and.right.slash"
                )
                .font(AirBridgeDesign.Typography.headline)
                Text(
                    "Ouvrez « Appareils » pour rechercher un appareil "
                    + "sur le même réseau."
                )
                .font(AirBridgeDesign.Typography.caption)
                .foregroundStyle(.secondary)

                Button("Rechercher un appareil") {
                    filter = MacTransferFilter.devices
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AirBridgeDesign.Spacing.md)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium,
                style: .continuous
            )
        )
    }

    // MARK: - Détail

    /// Colonne de détail : elle suit la section sélectionnée dans la
    /// sidebar. « Appareils » et « Réglages » sont des sections
    /// autonomes ; les trois filtres de transfert partagent la même
    /// surface (zone de dépôt + tableau).
    @ViewBuilder
    private var workspaceDetail: some View {
        switch effectiveFilter {

        case .devices:
            devicesDetail

        case .active, .all, .history:
            transfersDetail

        case .settings:
            settingsDetail
        }
    }

    /// Détail « Appareils » : bandeau d'état de la recherche Bonjour
    /// (uniquement quand la recherche ne peut pas aboutir) au-dessus du
    /// radar de découverte existant.
    ///
    /// Le radar est la surface déjà utilisée par l'UI iPhone
    /// (`MainView.content(for: .devices)`) : il centralise découverte,
    /// sélection d'un appareil → connexion, appairage et déconnexion.
    /// Sa réutilisation évite toute divergence entre les deux
    /// plateformes et n'introduit aucun nouveau chemin réseau.
    private var devicesDetail: some View {
        VStack(spacing: 0) {
            if let issue = core.bonjourService.localNetworkIssue {
                discoveryIssueBanner(issue)
                Divider()
            }
            RadarFullScreenView(core: core)
        }
    }

    /// Détail des sections de transfert : zone de dépôt + tableau.
    private var transfersDetail: some View {
        VStack(spacing: 0) {
            dropZone
                .padding(AirBridgeDesign.Spacing.md)
            Divider()
            transferTable
        }
    }

    /// Détail « Réglages » : réglages de l'application (dossier de
    /// réception, notifications, appareils appairés avec
    /// confiance / blocage / oubli).
    private var settingsDetail: some View {
        SettingsView(
            receivedFolderStore: core.receivedFolderStore,
            notificationManager: core.notificationManager,
            pairingStore: core.pairingStore
        )
    }

    /// Bandeau affiché quand la recherche Bonjour ne peut pas aboutir
    /// (autorisation « Réseau local » refusée sur macOS 15+, réseau
    /// indisponible, publication impossible…). Sans lui, l'utilisateur
    /// ne voyait qu'un radar vide, sans cause ni action possible.
    private func discoveryIssueBanner(
        _ message: String
    ) -> some View {
        HStack(alignment: .top, spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AirBridgeDesign.Color.warning)

            VStack(alignment: .leading, spacing: AirBridgeDesign.Spacing.xs) {
                Text("Recherche d'appareils limitée")
                    .font(AirBridgeDesign.Typography.headline)

                Text(message)
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: AirBridgeDesign.Spacing.sm) {
                    Button("Ouvrir Réglages Système") {
                        openLocalNetworkSettings()
                    }

                    Button("Relancer la recherche") {
                        restartDiscovery()
                    }
                }
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
        .padding(AirBridgeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    /// Relance la recherche Bonjour : un `NWBrowser` en échec
    /// (`NoAuth`, réseau perdu) ne se relance pas tout seul — il faut
    /// en créer un neuf. Utile aussi après l'octroi de l'autorisation
    /// « Réseau local », qui exige un nouveau navigateur pour produire
    /// des résultats.
    private func restartDiscovery() {
        core.bonjourService.stopDiscovery()
        core.bonjourService.startDiscovery()
    }

    /// Ouvre le panneau « Réseau local » des Réglages Système. Le
    /// deep-link n'est pas garanti selon les versions : on retombe sur
    /// la racine de « Confidentialité et sécurité » si besoin.
    private func openLocalNetworkSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for candidate in candidates {
            if let url = URL(string: candidate),
               NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Zone de dépôt : Material régulier, bordure pointillée, bouton
    /// de sélection de fichiers. Refuse le dépôt sans appareil lié,
    /// comme le drop global de `MainView`.
    private var dropZone: some View {
        VStack(spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AirBridgeDesign.Color.accent)

            Text("Glissez-déposez des fichiers ici")
                .font(AirBridgeDesign.Typography.headline)

            if isConnected {
                Text("ou")
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Connectez un appareil pour envoyer")
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Choisir des fichiers…") {
                isImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConnected)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AirBridgeDesign.Spacing.xl)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.large,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.large,
                style: .continuous
            )
            .strokeBorder(
                isDropTargeted
                    ? Color.accentColor
                    : Color.secondary.opacity(0.35),
                style: StrokeStyle(
                    lineWidth: isDropTargeted ? 2.5 : 1.5,
                    dash: [8, 5]
                )
            )
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: $isDropTargeted,
            perform: handleDrop
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: isDropTargeted
        )
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data, .folder],
            allowsMultipleSelection: true,
            onCompletion: handleImporterCompletion
        )
    }

    private var transferTable: some View {
        Table(rows) {
            TableColumn("Fichier") { row in
                HStack(spacing: AirBridgeDesign.Spacing.sm) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.fileName)
                            .lineLimit(1)
                        Text(row.sizeLabel)
                            .font(AirBridgeDesign.Typography.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(row.fileName)
            }

            TableColumn("Appareil") { row in
                HStack(spacing: AirBridgeDesign.Spacing.xs) {
                    Image(systemName: row.peerSymbolName)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(Self.directionPrefix(row.direction)) \(row.peerName)"
                    )
                    .lineLimit(1)
                }
            }

            TableColumn("Progression") { row in
                HStack(spacing: AirBridgeDesign.Spacing.sm) {
                    if let progress = row.progress {
                        ProgressView(value: progress)
                            .frame(width: 72)
                        Text(row.progressLabel)
                            .font(AirBridgeDesign.Typography.caption)
                            .foregroundStyle(
                                row.status == .awaitingConfirmation
                                    ? AirBridgeDesign.Color.info
                                    : Color.secondary
                            )
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            TableColumn("Débit") { row in
                Text(row.speedLabel ?? "—")
                    .font(AirBridgeDesign.Typography.monoCaption)
                    .foregroundStyle(
                        row.speedLabel == nil ? .tertiary : .secondary
                    )
            }

            TableColumn("État") { row in
                TransferStatusView(status: row.status)
            }

            TableColumn("Action") { row in
                action(for: row)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Aucun transfert",
                    systemImage: "tray",
                    description: Text(
                        "Les transferts apparaissent ici. Déposez un "
                        + "fichier ou choisissez-en pour commencer."
                    )
                )
            }
        }
    }

    /// Bouton d'action contextuel : annulation (transfert non
    /// terminal — l'attente de confirmation comprise), reprise
    /// (interrompu), rien sinon.
    @ViewBuilder
    private func action(for row: MacTransferRow) -> some View {
        let canCancel = viewModel?.canCancel(row.core) ?? false
        let canRetry = viewModel?.canRetry(row.core) ?? false

        if canCancel {
            Button {
                viewModel?.cancel(transfer: row.core)
            } label: {
                Image(systemName: "stop.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        .white,
                        AirBridgeDesign.Color.error
                    )
            }
            .buttonStyle(.plain)
            .help("Annuler le transfert")
            .accessibilityLabel("Annuler le transfert")
        } else if canRetry {
            Button {
                viewModel?.retry(transfer: row.core)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        .white,
                        AirBridgeDesign.Color.accent
                    )
            }
            .buttonStyle(.plain)
            .help("Reprendre le transfert")
            .accessibilityLabel("Reprendre le transfert")
        }
    }

    // MARK: - Données du tableau

    private var rows: [MacTransferRow] {
        guard let viewModel else { return [] }

        let models: [TransferUIModel]
        switch effectiveFilter {
        case .active:
            models = (viewModel.outgoingUI + viewModel.incomingUI)
                .filter { !$0.core.state.isTerminal }
        case .all:
            models = viewModel.outgoingUI + viewModel.incomingUI
        case .history:
            models = viewModel.historyUI()
        case .devices, .settings:
            // Sections autonomes : aucun transfert à projeter.
            models = []
        }

        return models
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
            .map(Self.row(for:))
    }

    /// Nombre affiché dans le badge de la sidebar.
    private func badgeCount(for item: MacTransferFilter) -> Int {
        switch item {
        case .devices:
            // Nombre d'appareils actuellement visibles sur le réseau.
            return core.bonjourService.discoveredDevices.count
        case .settings:
            return 0
        case .active, .all, .history:
            return transferBadgeCount(for: item)
        }
    }

    /// Badge des sections de transfert : elles dépendent du view model,
    /// créé à l'apparition de la vue.
    private func transferBadgeCount(for item: MacTransferFilter) -> Int {
        guard let viewModel else { return 0 }
        switch item {
        case .active:
            return viewModel.activeOutgoingCount
                + viewModel.activeIncomingCount
        case .all:
            return viewModel.outgoingUI.count
                + viewModel.incomingUI.count
        case .history:
            return viewModel.history.count
        case .devices, .settings:
            return 0
        }
    }

    /// Préfixe directionnel du pair, aligné sur `TransferProgressView`
    /// (« De X » pour une réception, « Vers X » pour un envoi).
    private static func directionPrefix(
        _ direction: TransferUIDirection
    ) -> String {
        switch direction {
        case .incoming: "De"
        case .outgoing: "Vers"
        }
    }

    /// Construit une ligne de tableau depuis la projection UI.
    private static func row(
        for model: TransferUIModel
    ) -> MacTransferRow {
        let percent = Int((model.progress * 100).rounded())

        // Pendant la fenêtre de confirmation : « 100 % — Validation du
        // récepteur… », jamais « Réussi » avant le transferSucceeded.
        let progressLabel: String
        switch model.status {
        case .awaitingConfirmation:
            progressLabel = "100 % — Validation du récepteur…"
        case .completed:
            progressLabel = "100 %"
        case .failed, .cancelled, .waiting, .active:
            progressLabel = "\(percent) %"
        }

        // Débit affiché uniquement pendant un envoi actif : une fois
        // les données parties, le débit calculé décroîtrait avec le
        // temps écoulé sans que plus aucun octet ne circule.
        let speedLabel: String?
        if model.status == .active {
            speedLabel = Self.speedLabel(for: model.speed)
        } else {
            speedLabel = nil
        }

        return MacTransferRow(
            id: model.id,
            fileName: model.fileName,
            sizeLabel: Self.sizeLabel(model.totalBytes),
            peerName: model.peer.name,
            peerSymbolName: AirBridgeDesign.DeviceKind
                .from(model: model.peer.model)
                .symbolName,
            direction: model.direction,
            status: model.status,
            progress: model.progress,
            progressLabel: progressLabel,
            speedLabel: speedLabel,
            core: model.core
        )
    }

    /// Formatage du débit, aligné sur `TransferProgressView` :
    /// Mb/s au-delà de 1 Mb/s, Ko/s sinon.
    private static func speedLabel(
        for bytesPerSecond: Double
    ) -> String {
        let megabits = bytesPerSecond * 8 / 1_000_000
        if megabits >= 1 {
            return String(format: "%.1f Mb/s", megabits)
        }
        return String(format: "%.0f Ko/s", bytesPerSecond / 1_024)
    }

    private static func sizeLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Connexion

    private var isConnected: Bool {
        core.connectionManager.connectedDevice != nil
    }

    // MARK: - Dépôt et sélection de fichiers

    /// Même contrat que le drop global de `MainView` : refus explicite
    /// sans appareil lié (haptique de warning), sinon conversion des
    /// providers via `ShareDropHandler` et routage vers le Core —
    /// FIFO, security-scoped resources et demande de transfert au
    /// pair connecté inclus.
    @MainActor
    private func handleDrop(
        providers: [NSItemProvider]
    ) -> Bool {
        guard isConnected else {
            Haptics.warning()
            return false
        }

        Task { @MainActor in
            let urls = await ShareDropHandler.loadFileURLs(
                from: providers
            )
            guard !urls.isEmpty else { return }
            core.importAndRequestItems(urls: urls)
            Haptics.impact(.medium)
        }
        return true
    }

    private func handleImporterCompletion(
        _ result: Result<[URL], Error>
    ) {
        guard case .success(let urls) = result else { return }
        guard isConnected, !urls.isEmpty else { return }
        core.importAndRequestItems(urls: urls)
    }

    // MARK: - Feuille de demande de transfert

    /// Identifiant du lot présenté, pour piloter la feuille par
    /// valeur (même contrat que `MainView`).
    private struct TransferRequestPresentation: Identifiable,
        Equatable
    {
        let id: UUID
    }

    /// La présentation suit le modèle : un lot apparaît, la feuille
    /// s'ouvre ; le lot disparaît, la feuille se referme.
    private func synchronizeRequestSheet(
        batchID: UUID?
    ) {
        guard let batchID else {
            presentedRequest = nil
            return
        }
        guard presentedRequest?.id != batchID else { return }
        presentedRequest = TransferRequestPresentation(
            id: batchID
        )
    }

    /// Binding pilotant la feuille de lot partagé depuis le
    /// contrôleur — fermeture routée vers `dismissed()`, aucune
    /// suppression de fichiers.
    private var pendingShareBinding: Binding<PendingShareItem?> {
        Binding(
            get: { pendingShareController.item },
            set: { newValue in
                if newValue == nil {
                    pendingShareController.dismissed()
                }
            }
        )
    }
}

#endif
