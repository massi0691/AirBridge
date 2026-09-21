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
internal import UniformTypeIdentifiers

/// Filtres du tableau des transferts, pilotés depuis la sidebar.
enum MacTransferFilter: String, CaseIterable, Identifiable, Hashable {
    /// Transferts vivants non terminaux (envoi, réception, attente de
    /// confirmation comprise).
    case active

    /// Tous les transferts vivants connus du Core.
    case all

    /// Journal des transferts terminés (`transferHistoryStore`).
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "En cours"
        case .all: "Tous"
        case .history: "Historique"
        }
    }

    var symbolName: String {
        switch self {
        case .active: "arrow.triangle.2.circlepath"
        case .all: "tray.full"
        case .history: "clock.arrow.circlepath"
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
    /// unique) ; `effectiveFilter` retombe sur « En cours » si la
    /// sélection est momentanément vide.
    @State private var filter: MacTransferFilter? = .active

    private var effectiveFilter: MacTransferFilter {
        filter ?? .active
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
        .navigationSplitViewStyle(.sidebarAndDetail)
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
                Text("Utilisez le radar depuis votre iPhone pour lier un appareil.")
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
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

    private var workspaceDetail: some View {
        VStack(spacing: 0) {
            dropZone
                .padding(AirBridgeDesign.Spacing.md)
            Divider()
            transferTable
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
        }

        return models
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
            .map(Self.row(for:))
    }

    /// Nombre affiché dans le badge de la sidebar.
    private func badgeCount(for item: MacTransferFilter) -> Int {
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
