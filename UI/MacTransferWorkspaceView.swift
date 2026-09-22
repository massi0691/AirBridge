//
//  MacTransferWorkspaceView.swift
//  AirBridge
//
//  Espace de travail macOS : sidebar NavigationSplitView (résumé de
//  connexion + filtres), zone de dépôt avec Material, et tableau des
//  transferts (Fichier / Appareil / Progression / Débit / État /
//  Action).
//
//  Correctif photo macOS :
//  - Fenêtre blanche au lancement : `Color.clear` sans frame + init
//    paresseux du Core + `TransferViewModel` nil + `RadarFullScreenView`
//    qui rendait `Color.clear` tant que ses VMs n'étaient pas prêtes.
//    → Écran de chargement explicite, création du VM dans `.task`,
//    `columnVisibility = .all`, largeurs de colonnes explicites.
//  - Sidebar écrasée / invisible : `NavigationSplitView` sans
//    `columnWidth` ni `visibility` → macOS pouvait replier la sidebar
//    à 0 pt au premier lancement. → `navigationSplitViewColumnWidth`
//    + `NavigationSplitViewVisibility.all` + bouton toggle dans la
//    toolbar.
//  - `List` avec `NavigationLink(value:)` sans `navigationDestination`
//    → sélection cassée, détail vide. → `List(selection:)` avec
//    `Label` + `.tag(item)` (pattern canonique macOS).
//  - `Table` sans frame → hauteur 0, overlay `ContentUnavailableView`
//    invisible. → `.frame(maxHeight: .infinity)` + `.tableStyle(.inset)`
//  - `RadarFullScreenView` avec `ignoresSafeArea()` dans un `VStack`
//    sans taille → fond qui débordait ou radar à 0 pt.
//    → wrapper avec `.frame(maxWidth: .infinity, maxHeight: .infinity)`
//    et fond adaptatif.

#if os(macOS)

import SwiftUI
import AppKit
internal import UniformTypeIdentifiers

// MARK: - Filtres sidebar

enum MacTransferFilter: String, CaseIterable, Identifiable, Hashable {
    case devices
    case active
    case all
    case history
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

// MARK: - Row

struct MacTransferRow: Identifiable {
    let id: UUID
    let fileName: String
    let sizeLabel: String
    let peerName: String
    let peerSymbolName: String
    let direction: TransferUIDirection
    let status: TransferUIStatus
    let progress: Double?
    let progressLabel: String
    let speedLabel: String?
    let core: Transfer
}

// MARK: - Workspace

struct MacTransferWorkspaceView: View {

    @Bindable var core: AirBridgeCore
    let pendingShareController: PendingShareController

    @State private var viewModel: TransferViewModel?
    @State private var filter: MacTransferFilter? = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var effectiveFilter: MacTransferFilter {
        filter ?? .devices
    }

    @State private var isDropTargeted = false
    @State private var isImporterPresented = false
    @State private var presentedRequest: TransferRequestPresentation?

    // MARK: - Sélection multiple (Historique)

    /// Identifiants des entrées d'historique sélectionnées dans le
    /// tableau (filtre « Historique » uniquement).
    @State private var historySelection: Set<UUID> = []
    /// Popup de confirmation « Voulez-vous supprimer tout
    /// l'historique ? ».
    @State private var isConfirmingClearHistory = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detailContainer
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Afficher / masquer la barre latérale")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if effectiveFilter == .devices {
                    Button {
                        restartDiscovery()
                    } label: {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                    }
                    .help("Relancer la recherche d'appareils")
                }

                if effectiveFilter == .history {
                    // Suppression groupée des entrées cochées dans le
                    // tableau (sélection native macOS : clic ⌘ / ⇧).
                    Button(role: .destructive) {
                        deleteSelectedHistory()
                    } label: {
                        Label(
                            selectedHistoryCount == 0
                                ? "Supprimer la sélection"
                                : "Supprimer (\(selectedHistoryCount))",
                            systemImage: "trash"
                        )
                    }
                    .disabled(selectedHistoryCount == 0)
                    .help("Supprimer les entrées sélectionnées de l’historique")

                    Button(role: .destructive) {
                        isConfirmingClearHistory = true
                    } label: {
                        Label("Vider l’historique", systemImage: "trash.slash")
                    }
                    .disabled(viewModel?.history.isEmpty ?? true)
                    .help("Supprimer tout l’historique")
                }
            }
        }
        .alert(
            "Voulez-vous supprimer tout l’historique ?",
            isPresented: $isConfirmingClearHistory
        ) {
            Button("Supprimer", role: .destructive) {
                viewModel?.clearHistory()
                historySelection.removeAll()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Cette action est irréversible.")
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(item: $presentedRequest) { _ in
            TransferRequestSheet(core: core)
        }
        .sheet(item: pendingShareBinding) { item in
            PendingShareSheetView(
                core: core,
                item: item,
                controller: pendingShareController
            )
        }
        .onChange(of: core.pendingTransferBatch?.id, initial: true) { _, newValue in
            synchronizeRequestSheet(batchID: newValue)
        }
        .onChange(of: effectiveFilter) { _, _ in
            // Changer de filtre vide la sélection d'historique : elle ne
            // concerne que le tableau « Historique ».
            historySelection.removeAll()
        }
        .task {
            if viewModel == nil {
                viewModel = TransferViewModel(core: core)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            connectionSummary
                .padding(12)

            Divider()

            List(MacTransferFilter.allCases, id: \.self, selection: $filter) { item in
                Label {
                    HStack {
                        Text(item.title)
                        Spacer()
                        let count = badgeCount(for: item)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: item.symbolName)
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("AirBridge")
        .background(.ultraThinMaterial)
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device = core.connectionManager.connectedDevice {
                HStack(spacing: 8) {
                    Image(systemName: AirBridgeDesign.DeviceKind.from(model: device.model).symbolName)
                        .font(.title3)
                        .foregroundStyle(AirBridgeDesign.Color.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(device.model)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                Label {
                    Text(core.connectionManager.isSecureSessionReady ? "Session sécurisée" : "Session non sécurisée")
                        .font(.caption)
                } icon: {
                    Image(systemName: core.connectionManager.isSecureSessionReady ? "lock.shield.fill" : "lock.open")
                        .foregroundStyle(core.connectionManager.isSecureSessionReady ? AirBridgeDesign.Color.success : AirBridgeDesign.Color.warning)
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label("Aucun appareil connecté", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline)
                    .lineLimit(2)

                Text("Ouvrez « Appareils » pour rechercher un appareil sur le même réseau.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    filter = .devices
                } label: {
                    Label("Rechercher un appareil", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    // MARK: - Detail container

    @ViewBuilder
    private var detailContainer: some View {
        Group {
            switch effectiveFilter {
            case .devices:
                devicesDetail
            case .active, .all, .history:
                transfersDetail
            case .settings:
                settingsDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Devices detail

    private var devicesDetail: some View {
        VStack(spacing: 0) {
            if let issue = core.bonjourService.localNetworkIssue {
                discoveryIssueBanner(issue)
                Divider()
            }

            // Le radar original utilisait `Color.clear` tant que ses VMs
            // n'étaient pas prêtes, ce qui donnait une zone vide blanche
            // sur la capture. On l'enveloppe dans un conteneur avec taille
            // explicite et fond adaptatif, et on lui donne tout l'espace.
            ZStack {
                // Fond adaptatif qui suit le thème système
                AirBridgeDesign.Color.Radar.base
                    .ignoresSafeArea()

                RadarFullScreenView(core: core)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .navigationTitle("Appareils")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transfers detail

    private var transfersDetail: some View {
        VStack(spacing: 0) {
            dropZone
                .padding(16)

            Divider()

            transferTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(effectiveFilter.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Settings detail

    private var settingsDetail: some View {
        SettingsView(
            receivedFolderStore: core.receivedFolderStore,
            notificationManager: core.notificationManager,
            pairingStore: core.pairingStore,
            core: core
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Réglages")
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Banner

    private func discoveryIssueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AirBridgeDesign.Color.warning)
                .font(.title3)

            VStack(alignment: .leading, spacing: 6) {
                Text("Recherche d'appareils limitée")
                    .font(.headline)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Ouvrir Réglages Système") {
                        openLocalNetworkSettings()
                    }
                    Button("Relancer la recherche") {
                        restartDiscovery()
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            Button {
                // Dismiss visuel : on ne peut pas vraiment effacer l'erreur
                // réseau, mais on relance la découverte pour retenter.
                restartDiscovery()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func restartDiscovery() {
        core.bonjourService.stopDiscovery()
        core.bonjourService.startDiscovery()
    }

    private func openLocalNetworkSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AirBridgeDesign.Color.accent.opacity(isDropTargeted ? 0.18 : 0.10))
                    .frame(width: 56, height: 56)

                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "square.and.arrow.down")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(AirBridgeDesign.Color.accent)
            }

            Text("Glissez-déposez des fichiers ici")
                .font(.headline)

            if isConnected {
                Text("ou déposez depuis le Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Connectez un appareil pour envoyer", systemImage: "lock.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                isImporterPresented = true
            } label: {
                Label("Choisir des fichiers…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!isConnected)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2.5 : 1.2, dash: [8, 5])
                )
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDropTargeted)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data, .folder],
            allowsMultipleSelection: true,
            onCompletion: handleImporterCompletion
        )
    }

    // MARK: - Table

    private var transferTable: some View {
        // Sélection native du tableau (clic ⌘ / ⇧) — active uniquement sur
        // le filtre « Historique » ; sur les autres filtres le binding est
        // inerte pour ne pas laisser croire à une sélection actionnable.
        Table(rows, selection: tableSelectionBinding) {
            TableColumn("Fichier") { row in
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.sizeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(row.fileName)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Appareil") { row in
                HStack(spacing: 6) {
                    Image(systemName: row.peerSymbolName)
                        .foregroundStyle(.secondary)
                    Text("\(Self.directionPrefix(row.direction)) \(row.peerName)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .width(min: 120, ideal: 160)

            TableColumn("Progression") { row in
                HStack(spacing: 8) {
                    if let progress = row.progress {
                        ProgressView(value: progress)
                            .frame(width: 80)
                        Text(row.progressLabel)
                            .font(.caption)
                            .foregroundStyle(row.status == .awaitingConfirmation ? AirBridgeDesign.Color.info : .secondary)
                            .lineLimit(1)
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Débit") { row in
                Text(row.speedLabel ?? "—")
                    .font(AirBridgeDesign.Typography.monoCaption)
                    .foregroundStyle(row.speedLabel == nil ? .tertiary : .secondary)
            }
            .width(min: 80, ideal: 90)

            TableColumn("État") { row in
                TransferStatusView(status: row.status)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Action") { row in
                action(for: row)
            }
            .width(min: 60, ideal: 70)
        }
        .tableStyle(.inset)
        .onDeleteCommand {
            // Touche Suppr : équivalent clavier du bouton « Supprimer la
            // sélection » (uniquement en mode Historique).
            if effectiveFilter == .history {
                deleteSelectedHistory()
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(
                        effectiveFilter == .active ? "Aucun transfert en cours" : (effectiveFilter == .history ? "Aucun historique" : "Aucun transfert"),
                        systemImage: effectiveFilter == .history ? "clock.arrow.circlepath" : "tray"
                    )
                } description: {
                    Text("Les transferts apparaissent ici. Déposez un fichier ou choisissez-en pour commencer.")
                } actions: {
                    if isConnected {
                        Button("Choisir des fichiers…") {
                            isImporterPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if effectiveFilter != .devices {
                        Button("Aller à Appareils") {
                            filter = .devices
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func action(for row: MacTransferRow) -> some View {
        let canCancel = viewModel?.canCancel(row.core) ?? false
        let canRetry = viewModel?.canRetry(row.core) ?? false

        if canCancel {
            Button {
                viewModel?.cancel(transfer: row.core)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, AirBridgeDesign.Color.error)
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
                    .foregroundStyle(.white, AirBridgeDesign.Color.accent)
            }
            .buttonStyle(.plain)
            .help("Reprendre le transfert")
            .accessibilityLabel("Reprendre le transfert")
        }
    }

    // MARK: - Data

    private var rows: [MacTransferRow] {
        guard let viewModel else { return [] }
        let models: [TransferUIModel]
        switch effectiveFilter {
        case .active:
            models = (viewModel.outgoingUI + viewModel.incomingUI).filter { !$0.core.state.isTerminal }
        case .all:
            models = viewModel.outgoingUI + viewModel.incomingUI
        case .history:
            models = viewModel.historyUI()
        case .devices, .settings:
            models = []
        }
        return models
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
            .map(Self.row(for:))
    }

    // MARK: - Sélection multiple (Historique)

    /// Binding de sélection du tableau : actif uniquement sur le filtre
    /// « Historique ». Sur les autres filtres, la lecture renvoie un
    /// ensemble vide et l'écriture est ignorée — la sélection native du
    /// tableau reste disponible visuellement mais sans effet.
    private var tableSelectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { effectiveFilter == .history ? historySelection : [] },
            set: { newValue in
                if effectiveFilter == .history {
                    historySelection = newValue
                }
            }
        )
    }

    /// Nombre d'entrées sélectionnées ET encore présentes dans
    /// l'historique (un id périmé — entrée supprimée ailleurs — ne doit
    /// ni compter dans le libellé du bouton, ni bloquer son état).
    private var selectedHistoryCount: Int {
        guard let viewModel else { return 0 }
        let currentIDs = Set(viewModel.historyUI().map(\.id))
        return historySelection.intersection(currentIDs).count
    }

    /// Supprime les entrées sélectionnées de l'historique.
    private func deleteSelectedHistory() {
        guard let viewModel, effectiveFilter == .history else { return }
        let currentIDs = Set(viewModel.historyUI().map(\.id))
        let idsToDelete = historySelection.intersection(currentIDs)
        historySelection.removeAll()
        guard !idsToDelete.isEmpty else { return }
        viewModel.removeFromHistory(entryIDs: idsToDelete)
        Haptics.warning()
    }

    private func badgeCount(for item: MacTransferFilter) -> Int {
        switch item {
        case .devices:
            return core.bonjourService.discoveredDevices.count
        case .settings:
            return 0
        case .active, .all, .history:
            return transferBadgeCount(for: item)
        }
    }

    private func transferBadgeCount(for item: MacTransferFilter) -> Int {
        guard let viewModel else { return 0 }
        switch item {
        case .active:
            return viewModel.activeOutgoingCount + viewModel.activeIncomingCount
        case .all:
            return viewModel.outgoingUI.count + viewModel.incomingUI.count
        case .history:
            return viewModel.history.count
        case .devices, .settings:
            return 0
        }
    }

    private static func directionPrefix(_ direction: TransferUIDirection) -> String {
        switch direction {
        case .incoming: "De"
        case .outgoing: "Vers"
        }
    }

    private static func row(for model: TransferUIModel) -> MacTransferRow {
        let percent = Int((model.progress * 100).rounded())
        let progressLabel: String
        switch model.status {
        case .awaitingConfirmation:
            progressLabel = "100 % — Validation…"
        case .completed:
            progressLabel = "100 %"
        case .failed, .cancelled, .waiting, .active:
            progressLabel = "\(percent) %"
        }

        let speedLabel: String? = (model.status == .active) ? Self.speedLabel(for: model.speed) : nil

        return MacTransferRow(
            id: model.id,
            fileName: model.fileName,
            sizeLabel: Self.sizeLabel(model.totalBytes),
            peerName: model.peer.name,
            peerSymbolName: AirBridgeDesign.DeviceKind.from(model: model.peer.model).symbolName,
            direction: model.direction,
            status: model.status,
            progress: model.progress,
            progressLabel: progressLabel,
            speedLabel: speedLabel,
            core: model.core
        )
    }

    private static func speedLabel(for bytesPerSecond: Double) -> String {
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

    private var isConnected: Bool {
        core.connectionManager.connectedDevice != nil
    }

    @MainActor
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard isConnected else {
            Haptics.warning()
            return false
        }
        Task { @MainActor in
            let urls = await ShareDropHandler.loadFileURLs(from: providers)
            guard !urls.isEmpty else { return }
            core.importAndRequestItems(urls: urls)
            Haptics.impact(.medium)
        }
        return true
    }

    private func handleImporterCompletion(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        guard isConnected, !urls.isEmpty else { return }
        core.importAndRequestItems(urls: urls)
    }

    private struct TransferRequestPresentation: Identifiable, Equatable {
        let id: UUID
    }

    private func synchronizeRequestSheet(batchID: UUID?) {
        guard let batchID else {
            presentedRequest = nil
            return
        }
        guard presentedRequest?.id != batchID else { return }
        presentedRequest = TransferRequestPresentation(id: batchID)
    }

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
