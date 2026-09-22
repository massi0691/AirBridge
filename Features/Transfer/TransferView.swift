//
//  TransferView.swift
//  AirBridge
//
//  Main transfer screen. Tabs "Actifs" / "Terminés" with the
//  matching empty states.
//

import SwiftUI

/// Tab shown on the transfer screen.
///
/// "Actifs" mixes outgoing and incoming in-flight transfers in a
/// single list (the user expects to see "everything that's moving
/// right now"), while "Terminés" exposes the Core's history
/// ledger. The split mirrors the "Live / Archive" mental model of
/// the legacy transfer list.
/// Conformance `Equatable` (synthétisée : enum sans valeur
/// associée) — requise par `selectedTab == .completed` ; sans elle
/// la comparaison ne compile pas.
enum TransferTab: String, CaseIterable, Identifiable, Equatable {
    case active = "Actifs"
    case completed = "Terminés"

    var id: String { rawValue }
}

/// Main transfer screen.
///
/// Cross-platform iOS + macOS. iOS-specific affordances (large
/// title) are guarded by `#if os(iOS)` through the
/// `navigationTitle` modifier (which adapts on macOS).
struct TransferView: View {

    @Bindable var core: AirBridgeCore

    @State private var viewModel: TransferViewModel?
    @State private var selectedTab: TransferTab = .active
    @State private var pendingCancellation: PendingCancellation?
    @State private var isConfirmingClear = false

    // MARK: - Sélection multiple (onglet « Terminés »)

    /// Mode sélection : les lignes de l'historique affichent une case à
    /// cocher et le tap bascule la sélection au lieu d'ouvrir la feuille
    /// d'actions.
    @State private var isSelectingHistory = false
    /// Identifiants des entrées cochées.
    @State private var selectedHistoryIDs: Set<UUID> = []

    // MARK: - Présentation feuille de preview

    /// Identifiant de l'entrée dont on veut afficher la preview.
    ///
    /// On suit le pattern `TransferRequestPresentation` (cf.
    /// `MainView.swift`) : un struct `Identifiable` minimal, présenté
    /// via `.sheet(item:)`, qui ne porte que l'id — la feuille lit
    /// l'URL via le ViewModel à l'ouverture. Cela évite d'avoir à
    /// dupliquer l'URL dans le payload et garantit que la feuille
    /// reflète l'état courant du Core (utile si la liste se met à
    /// jour pendant que la feuille est ouverte).
    @State private var previewPresentation: HistoryPreviewPresentation?
    /// Identifiant de l'entrée dont on veut afficher la feuille
    /// d'actions (Aperçu / Partager / Supprimer). Suit le même
    /// pattern que `previewPresentation` : la feuille lit le modèle
    /// via le ViewModel à l'ouverture pour éviter de dupliquer l'URL.
    @State private var fileActionPresentation: FileActionPresentation?
#if os(iOS)
    /// Identifiant de l'entrée dont on veut ouvrir le dossier de
    /// réception sur iOS (sheet présentation dossier). Pas de sheet
    /// sur macOS — on utilise `NSWorkspace.shared.activateFileViewerSelecting`
    /// directement.
    @State private var folderPresentation: HistoryFolderPresentation?
#endif

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                Color.clear
                    .onAppear {
                        viewModel = TransferViewModel(core: core)
                    }
            }
        }
        .navigationTitle("Transferts")
        .toolbar {
            if selectedTab == .completed {
#if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    historySelectionToggleButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    clearHistoryButton
                }
#else
                ToolbarItem(placement: .primaryAction) {
                    historySelectionToggleButton
                }
                ToolbarItem(placement: .primaryAction) {
                    clearHistoryButton
                }
#endif
            }
        }
        .onChange(of: selectedTab) { _, _ in
            // Quitter l'onglet « Terminés » referme le mode sélection :
            // une sélection invisible ne doit pas survivre à un aller-retour.
            isSelectingHistory = false
            selectedHistoryIDs.removeAll()
        }
        .alert(
            "Annuler ce transfert ?",
            isPresented: cancellationBinding,
            presenting: pendingCancellation
        ) { pending in
            Button("Annuler le transfert", role: .destructive) {
                pending.action()
                pendingCancellation = nil
            }
            Button("Garder", role: .cancel) {
                pendingCancellation = nil
            }
        } message: { _ in
            Text("Le fichier en cours d’envoi ne sera pas terminé.")
        }
        .alert(
            "Voulez-vous supprimer tout l’historique ?",
            isPresented: $isConfirmingClear
        ) {
            Button("Supprimer", role: .destructive) {
                viewModel?.clearHistory()
                selectedHistoryIDs.removeAll()
                isSelectingHistory = false
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Les \(viewModel?.history.count ?? 0) entrée(s) seront définitivement retirées de la liste. Cette action est irréversible.")
        }
        .sheet(
            item: $previewPresentation,
            onDismiss: {
                // La feuille a été fermée (utilisateur ou système) :
                // on libère l'identifiant pour qu'un nouveau tap
                // puisse ré-ouvrir la preview sur la même entrée.
                previewPresentation = nil
            }
        ) { presentation in
            // Le ViewModel peut renvoyer `nil` si l'entrée n'est plus
            // joignable entre le tap et l'ouverture (transfert nettoyé
            // en arrière-plan). On court-circuite alors avec un écran
            // "indisponible" plutôt qu'un crash.
            if let viewModel,
               let url = viewModel.localURL(for: presentation.entryID) {
                HistoryPreviewView(
                    url: url,
                    onDismiss: {
                        previewPresentation = nil
                    }
                )
            } else {
                HistoryUnavailableView(
                    onDismiss: { previewPresentation = nil }
                )
            }
        }
        // Feuille d'actions sur un fichier transféré : Aperçu,
        // Partager, Afficher dans le Finder (macOS), Supprimer.
        // On route les actions de preview / delete vers les
        // helpers existants (`previewPresentation`, `removeFromHistory`,
        // `deleteStoredFile`) pour ne pas dupliquer la logique.
        .sheet(
            item: $fileActionPresentation,
            onDismiss: {
                fileActionPresentation = nil
            }
        ) { presentation in
            if let viewModel,
               let model = viewModel.uiModel(for: presentation.entryID) {
                FileActionSheet(
                    model: model,
                    localURL: viewModel.localURL(for: presentation.entryID),
                    onPreview: {
                        fileActionPresentation = nil
                        if viewModel.localURL(for: presentation.entryID) != nil {
                            previewPresentation = HistoryPreviewPresentation(
                                entryID: presentation.entryID,
                                fileName: presentation.fileName
                            )
                            Haptics.selection()
                        } else {
                            Haptics.warning()
                        }
                    },
                    onShare: {
                        // No-op : ShareLink gère l'ouverture
                        // directement. Le haptic est géré par
                        // `FileActionSheet` au moment du tap.
                    },
                    onShowInFinder: {
                        fileActionPresentation = nil
                        showInFinder(entryID: presentation.entryID)
                    },
                    onShowFolder: {
                        fileActionPresentation = nil
                        openReceivedFolder(entryID: presentation.entryID)
                    },
                    onDeleteFromStorage: {
                        let result = viewModel.deleteStoredFile(
                            for: presentation.entryID
                        )
                        switch result {
                        case .success:
                            Haptics.success()
                        case .failure:
                            Haptics.error()
                        }
                    },
                    onDeleteFromList: {
                        viewModel.removeFromHistory(
                            entryID: presentation.entryID
                        )
                        Haptics.warning()
                    },
                    onDeleteBoth: {
                        let result = viewModel.deleteStoredFile(
                            for: presentation.entryID
                        )
                        viewModel.removeFromHistory(
                            entryID: presentation.entryID
                        )
                        switch result {
                        case .success:
                            Haptics.success()
                        case .failure:
                            Haptics.error()
                        }
                    },
                    onCancel: {
                        fileActionPresentation = nil
                    }
                )
                .presentationDetents([.medium, .large])
            } else {
                HistoryUnavailableView(
                    onDismiss: { fileActionPresentation = nil }
                )
            }
        }
#if os(iOS)
        .sheet(
            item: $folderPresentation,
            onDismiss: {
                folderPresentation = nil
            }
        ) { _ in
            // iOS : pas d'API publique stable pour "révéler dans
            // Finder" depuis une app sandboxée. On présente à la
            // place une feuille qui affiche le contenu du dossier de
            // réception (`Documents/`) via un `QLPreviewController`
            // dédié à l'URL du dossier. QuickLook sait ouvrir un
            // dossier comme un container et lister son contenu ;
            // l'utilisateur peut alors naviguer ou partager.
            if let viewModel,
               let directory = viewModel.receivedDirectoryURL {
                HistoryPreviewView(
                    url: directory,
                    onDismiss: {
                        folderPresentation = nil
                    }
                )
            } else {
                HistoryUnavailableView(
                    onDismiss: { folderPresentation = nil }
                )
            }
        }
#endif
    }

    // MARK: - Toolbar (onglet « Terminés »)

    /// Bascule le mode sélection multiple de l'historique.
    private var historySelectionToggleButton: some View {
        Button {
            toggleHistorySelectionMode()
        } label: {
            Image(
                systemName: isSelectingHistory
                    ? "xmark.circle"
                    : "checkmark.circle"
            )
        }
        .accessibilityLabel(
            isSelectingHistory
                ? "Quitter la sélection"
                : "Sélectionner plusieurs entrées"
        )
        .disabled(viewModel?.history.isEmpty ?? true)
    }

    /// Ouvre la popup « Voulez-vous supprimer tout l'historique ? ».
    private var clearHistoryButton: some View {
        Button(role: .destructive) {
            isConfirmingClear = true
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Vider l’historique")
        .disabled(viewModel?.history.isEmpty ?? true)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(viewModel: TransferViewModel) -> some View {
        VStack(spacing: 0) {
            tabPicker(viewModel: viewModel)
            Divider()
            tabContent(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func tabPicker(viewModel: TransferViewModel) -> some View {
        Picker(
            "Section",
            selection: $selectedTab
        ) {
            ForEach(TransferTab.allCases) { tab in
                Text(label(for: tab, viewModel: viewModel))
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, AirBridgeDesign.Spacing.md)
        .padding(.vertical, AirBridgeDesign.Spacing.sm)
    }

    @ViewBuilder
    private func tabContent(viewModel: TransferViewModel) -> some View {
        switch selectedTab {
        case .active:
            activeTab(viewModel: viewModel)
        case .completed:
            completedTab(viewModel: viewModel)
        }
    }

    // MARK: - Actifs

    @ViewBuilder
    private func activeTab(viewModel: TransferViewModel) -> some View {
        let outgoing = viewModel.outgoingUI
        let incoming = viewModel.incomingUI
        if outgoing.isEmpty && incoming.isEmpty {
            emptyState(
                title: "Aucun transfert en cours",
                message: "Les fichiers que tu envoies ou reçois apparaîtront ici.",
                symbol: "tray"
            )
        } else {
            ScrollView {
                LazyVStack(
                    spacing: AirBridgeDesign.Spacing.md
                ) {
                    if !outgoing.isEmpty {
                        sectionHeader(
                            title: "Envoi",
                            count: outgoing.count
                        )
                        ForEach(outgoing) { model in
                            TransferProgressView(
                                model: model,
                                layout: .activeRow,
                                onCancel: {
                                    requestCancel(
                                        model: model,
                                        viewModel: viewModel
                                    )
                                },
                                onRetry: {
                                    retry(model: model)
                                }
                            )
                        }
                    }
                    if !incoming.isEmpty {
                        sectionHeader(
                            title: "Réception",
                            count: incoming.count
                        )
                        ForEach(incoming) { model in
                            TransferProgressView(
                                model: model,
                                layout: .activeRow,
                                onCancel: {
                                    requestCancel(
                                        model: model,
                                        viewModel: viewModel
                                    )
                                },
                                onRetry: {
                                    retry(model: model)
                                }
                            )
                        }
                    }
                }
                .padding(AirBridgeDesign.Spacing.md)
            }
        }
    }

    // MARK: - Terminés

    @ViewBuilder
    private func completedTab(viewModel: TransferViewModel) -> some View {
        let entries = viewModel.historyUI()
        if entries.isEmpty {
            emptyState(
                title: "Aucun transfert terminé",
                message: "L’historique apparaîtra ici une fois le premier transfert fini.",
                symbol: "clock.arrow.circlepath"
            )
        } else {
            VStack(spacing: 0) {
                // En-tête de sélection : « Tout sélectionner » + compteur.
                if isSelectingHistory {
                    historySelectionHeader(entries: entries)
                }
                ScrollView {
                    LazyVStack(
                        spacing: AirBridgeDesign.Spacing.sm
                    ) {
                        ForEach(entries) { model in
                            historyRow(
                                model: model,
                                onRemove: {
                                    viewModel.removeFromHistory(
                                        entryID: model.id
                                    )
                                    // L'entrée supprimée individuellement
                                    // ne doit pas rester dans la sélection.
                                    selectedHistoryIDs.remove(model.id)
                                }
                            )
                        }
                    }
                    .padding(AirBridgeDesign.Spacing.md)
                }
                // Barre d'action : suppression groupée des entrées cochées.
                if isSelectingHistory {
                    historySelectionActionBar
                }
            }
        }
    }

    // MARK: - Sélection multiple (historique)

    /// En-tête affiché au-dessus de la liste en mode sélection :
    /// « Tout sélectionner / Tout désélectionner » + compteur.
    @ViewBuilder
    private func historySelectionHeader(
        entries: [TransferUIModel]
    ) -> some View {
        HStack {
            Button {
                toggleSelectAll(entries: entries)
            } label: {
                Text(
                    allHistorySelected(entries: entries)
                        ? "Tout désélectionner"
                        : "Tout sélectionner"
                )
                .font(AirBridgeDesign.Typography.subheadline)
            }
            Spacer()
            Text("\(selectedHistoryIDs.count) sélectionné(s)")
                .font(AirBridgeDesign.Typography.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.lg)
        .padding(.vertical, AirBridgeDesign.Spacing.xs)
        .background(.bar)
    }

    /// Barre d'action en bas de l'écran en mode sélection.
    private var historySelectionActionBar: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                deleteSelectedHistory()
            } label: {
                Label(
                    selectedHistoryIDs.isEmpty
                        ? "Supprimer"
                        : "Supprimer (\(selectedHistoryIDs.count))",
                    systemImage: "trash"
                )
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedHistoryIDs.isEmpty)
            Spacer()
        }
        .padding(AirBridgeDesign.Spacing.md)
        .background(.bar)
    }

    private func toggleHistorySelectionMode() {
        isSelectingHistory.toggle()
        if !isSelectingHistory {
            selectedHistoryIDs.removeAll()
        }
        Haptics.selection()
    }

    private func toggleSelectAll(entries: [TransferUIModel]) {
        if allHistorySelected(entries: entries) {
            selectedHistoryIDs.removeAll()
        } else {
            selectedHistoryIDs = Set(entries.map(\.id))
        }
        Haptics.selection()
    }

    private func allHistorySelected(entries: [TransferUIModel]) -> Bool {
        !entries.isEmpty
            && Set(entries.map(\.id)) == selectedHistoryIDs
    }

    private func toggleSelection(for entryID: UUID) {
        if selectedHistoryIDs.contains(entryID) {
            selectedHistoryIDs.remove(entryID)
        } else {
            selectedHistoryIDs.insert(entryID)
        }
        Haptics.selection()
    }

    /// Supprime les entrées cochées et quitte le mode sélection.
    private func deleteSelectedHistory() {
        guard let viewModel, !selectedHistoryIDs.isEmpty else { return }
        viewModel.removeFromHistory(entryIDs: selectedHistoryIDs)
        selectedHistoryIDs.removeAll()
        isSelectingHistory = false
        Haptics.warning()
    }

    // MARK: - Subviews

    private func sectionHeader(
        title: String,
        count: Int
    ) -> some View {
        HStack {
            Text(title)
                .font(AirBridgeDesign.Typography.subheadline)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(AirBridgeDesign.Typography.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AirBridgeDesign.Spacing.xs)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                )
            Spacer()
        }
    }

    private func historyRow(
        model: TransferUIModel,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AirBridgeDesign.Spacing.md) {
            // Case à cocher du mode sélection multiple.
            if isSelectingHistory {
                Image(
                    systemName: selectedHistoryIDs.contains(model.id)
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(
                    selectedHistoryIDs.contains(model.id)
                        ? AirBridgeDesign.Color.accent
                        : .secondary
                )
                .accessibilityHidden(true)
            }
            ZStack {
                RoundedRectangle(
                    cornerRadius: AirBridgeDesign.Radius.medium
                )
                .fill(model.status.tint.opacity(0.12))
                .frame(
                    width: 56,
                    height: 56
                )
                Image(systemName: model.direction == .incoming
                    ? "arrow.down.doc.fill"
                    : "arrow.up.doc.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(model.status.tint)
            }
            VStack(
                alignment: .leading,
                spacing: AirBridgeDesign.Spacing.xs
            ) {
                Text(model.fileName)
                    .font(AirBridgeDesign.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(
                    spacing: AirBridgeDesign.Spacing.xs
                ) {
                    Text(
                        model.direction == .incoming
                            ? "Reçu de"
                            : "Envoyé à"
                    )
                    .font(AirBridgeDesign.Typography.caption2)
                    .foregroundStyle(.secondary)
                    Text(model.peer.name)
                        .font(AirBridgeDesign.Typography.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                historyRowMetadata(model: model)
            }
            Spacer(minLength: AirBridgeDesign.Spacing.sm)
            TransferStatusView(status: model.status)
                .padding(.leading, AirBridgeDesign.Spacing.xs)
        }
        .padding(
            .vertical,
            AirBridgeDesign.Spacing.sm
        )
        .padding(
            .horizontal,
            AirBridgeDesign.Spacing.lg
        )
        .background(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium
            )
            .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium
            )
            .stroke(
                Color.secondary.opacity(0.12),
                lineWidth: 1
            )
        )
        // History entries land like cards — the slide is shorter
        // than the active-row entrance to keep the list scannable.
        .transition(Transitions.cardAppear)
        .animation(
            AirBridgeDesign.SpringAnimation.standard,
            value: model.id
        )
        // Tap → ouvre la feuille d'actions (Aperçu / Partager /
        // Supprimer). On regarde d'abord si le fichier est encore
        // accessible dans le Core ; si non, on remonte quand même la
        // feuille d'actions — les actions seront désactivées à
        // l'intérieur, mais l'utilisateur peut toujours "Supprimer
        // de la liste" pour nettoyer l'historique.
        .contentShape(Rectangle())
        .onTapGesture {
            // En mode sélection, le tap bascule la case à cocher au lieu
            // d'ouvrir la feuille d'actions.
            if isSelectingHistory {
                toggleSelection(for: model.id)
            } else {
                handleTap(
                    entryID: model.id,
                    fileName: model.fileName
                )
            }
        }
#if os(iOS)
        // Swipe iOS : "Dossier" + "Supprimer". `allowsFullSwipe:
        // false` évite un swipe accidentel destructif : la
        // suppression passe par un tap explicite sur le bouton
        // rouge, pas par un balayage complet.
        .swipeActions(
            edge: .trailing,
            allowsFullSwipe: false
        ) {
            Button(role: .destructive) {
                onRemove()
                Haptics.warning()
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
            .tint(.red)

            Button {
                openReceivedFolder(
                    entryID: model.id
                )
            } label: {
                Label("Dossier", systemImage: "folder")
            }
            .tint(.blue)
        }
#endif
        // Context menu (cross-platform) : on garde "Supprimer" (déjà
        // présent) et on AJOUTE "Aperçu" qui rejoue la même action que
        // le tap. Sur macOS, "Afficher dans le Finder" complète
        // l'expérience — c'est l'équivalent fonctionnel de "Dossier"
        // sur iOS, mais en plus expressif (sélectionne le fichier au
        // lieu d'ouvrir le dossier). Si le fichier n'est pas
        // accessible, l'entrée "Aperçu" reste affichée (cohérence
        // visuelle) mais ouvre une sheet d'indisponibilité, plutôt
        // que d'être masquée dynamiquement.
        .contextMenu {
            Button {
                handleTap(
                    entryID: model.id,
                    fileName: model.fileName
                )
            } label: {
                Label("Aperçu", systemImage: "eye")
            }
#if os(macOS)
            Button {
                openInFinderOrActivate(
                    entryID: model.id
                )
            } label: {
                Label(
                    "Afficher dans le Finder",
                    systemImage: "folder"
                )
            }
#endif
            Button(role: .destructive) {
                onRemove()
                Haptics.warning()
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }

    /// Ligne secondaire de la carte : taille formatée + date
    /// relative (`Il y a 5 min`, `Hier`, `12 mars`).
    ///
    /// On rebuild la `RelativeDateTimeFormatter` à chaque render
    /// pour rester simple — elle est stateless et peu coûteuse.
    /// Si la date est nil (entrée purement reconstruite), on n'affiche
    /// que la taille.
    @ViewBuilder
    private func historyRowMetadata(model: TransferUIModel) -> some View {
        let sizeText = ByteCountFormatter.string(
            fromByteCount: model.totalBytes,
            countStyle: .file
        )
        if let startDate = model.startDate {
            historyRowMetadataWithDate(
                sizeText: sizeText,
                startDate: startDate
            )
        } else {
            Text(sizeText)
                .font(AirBridgeDesign.Typography.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Variante avec date : on isole l'appel au formatter dans sa
    /// propre fonction `@ViewBuilder` pour que les instructions
    /// impératives (`formatter.unitsStyle = ...`,
    /// `formatter.localizedString(...)`) ne perturbent pas le
    /// builder du caller.
    @ViewBuilder
    private func historyRowMetadataWithDate(
        sizeText: String,
        startDate: Date
    ) -> some View {
        let relativeText = Self.relativeText(for: startDate)
        HStack(spacing: AirBridgeDesign.Spacing.xs) {
            Text(sizeText)
                .font(AirBridgeDesign.Typography.caption2)
                .foregroundStyle(.secondary)
            Text("·")
                .font(AirBridgeDesign.Typography.caption2)
                .foregroundStyle(.secondary)
            Text(relativeText)
                .font(AirBridgeDesign.Typography.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(sizeText), \(relativeText)"))
    }

    /// Calcule le texte relatif (`Il y a 5 min`, `Hier`, `12 mars`)
    /// en une seule expression pour rester compatible avec
    /// `@ViewBuilder` (les `let X = ...` suivis d'affectations
    /// impératives ne passent pas dans un builder).
    private static func relativeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: date,
            relativeTo: Date()
        )
    }

    // MARK: - Gestes (preview / dossier / ouvrir)

    /// Tap sur une entrée terminée : ouvre la feuille d'actions
    /// (Aperçu / Partager / Supprimer). Avant on ouvrait directement
    /// la preview, mais le pattern AirDrop-like veut une étape de
    /// choix explicite — c'est aussi l'occasion de proposer Partager
    /// et la suppression depuis le même point d'entrée.
    private func handleTap(
        entryID: UUID,
        fileName: String
    ) {
        guard viewModel != nil else { return }
        fileActionPresentation = FileActionPresentation(
            entryID: entryID,
            fileName: fileName
        )
        Haptics.selection()
    }

    /// Révèle le fichier (ou à défaut le dossier de réception) dans
    /// une fenêtre Finder sur macOS. Sur iOS, le bouton
    /// correspondant n'est pas affiché dans la feuille d'actions —
    /// l'action "Dossier" du swipe reste l'équivalent.
    private func showInFinder(entryID: UUID) {
        guard let viewModel else { return }
#if os(macOS)
        if let url = viewModel.localURL(for: entryID) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let directory = viewModel.receivedDirectoryURL {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            Haptics.warning()
        }
#endif
    }

    /// Ouvre le dossier de réception. Sur macOS, on délègue à
    /// `NSWorkspace.activateFileViewerSelecting` (sélectionne le
    /// dossier dans une nouvelle fenêtre Finder). Sur iOS, on passe
    /// par une sheet QuickLook qui liste le contenu du dossier
    /// `Documents/`.
    private func openReceivedFolder(entryID: UUID) {
        guard let viewModel else { return }
        guard let directory = viewModel.receivedDirectoryURL else {
            Haptics.warning()
            return
        }
#if os(macOS)
        // `activateFileViewerSelecting` ouvre une fenêtre Finder
        // avec le dossier mis en surbrillance. C'est l'équivalent
        // fonctionnel de "Afficher dans le Finder" sur un dossier.
        NSWorkspace.shared.activateFileViewerSelecting(
            [directory]
        )
#else
        // iOS : pas de Finder. On présente le dossier dans une
        // sheet QuickLook (l'utilisateur peut alors naviguer dans
        // `Documents/`, partager un fichier, etc.).
        folderPresentation = HistoryFolderPresentation(
            entryID: entryID
        )
#endif
    }

#if os(macOS)
    /// macOS : révèle le fichier individuel dans le Finder. Si le
    /// fichier n'est plus accessible, on tombe sur le dossier de
    /// réception (l'utilisateur pourra alors y naviguer
    /// manuellement).
    private func openInFinderOrActivate(entryID: UUID) {
        guard let viewModel else { return }
        if let url = viewModel.localURL(for: entryID) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let directory = viewModel.receivedDirectoryURL {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            Haptics.warning()
        }
    }
#endif

    private func emptyState(
        title: String,
        message: String,
        symbol: String
    ) -> some View {
        VStack(spacing: AirBridgeDesign.Spacing.md) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(AirBridgeDesign.Typography.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(AirBridgeDesign.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(
                    .horizontal,
                    AirBridgeDesign.Spacing.lg
                )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func label(
        for tab: TransferTab,
        viewModel: TransferViewModel
    ) -> String {
        switch tab {
        case .active:
            let count = viewModel.activeCount
            return count > 0
                ? "Actifs (\(count))"
                : "Actifs"
        case .completed:
            let count = viewModel.completedCount
            return count > 0
                ? "Terminés (\(count))"
                : "Terminés"
        }
    }

    private func requestCancel(
        model: TransferUIModel,
        viewModel: TransferViewModel
    ) {
        // Capture a snapshot to dispatch the actual cancel once
        // the user confirms in the alert. The binding-driven
        // alert closes on its own.
        let transfer = model.core
        pendingCancellation = PendingCancellation(
            modelID: model.id,
            action: {
                viewModel.cancel(transfer: transfer)
                // The actual transfer-state transition fires its
                // own haptic through `TransferProgressView`'s
                // `onChange`. The user gesture itself (tapping the
                // stop button) gets a discrete warning so the tap
                // is never silent — the user has just taken a
                // destructive action.
                Haptics.warning()
            }
        )
    }

    private func retry(model: TransferUIModel) {
        viewModel?.retry(transfer: model.core)
        // User-driven retry : a medium impact acknowledges the
        // tap. The Core's eventual `.transferring` flip (if any)
        // fires its own feedback through `TransferProgressView`.
        Haptics.impact(.medium)
    }

    /// Bridging the alert's `isPresented` binding to the optional
    /// payload : the alert shows when a cancellation is pending.
    private var cancellationBinding: Binding<Bool> {
        Binding(
            get: { pendingCancellation != nil },
            set: { newValue in
                if !newValue {
                    pendingCancellation = nil
                }
            }
        )
    }
}

// MARK: - Pending cancellation payload

/// Identifies a pending cancel action by the model's id, so the
/// alert can present itself without a non-optional binding to a
/// Core transfer (which would force a re-render every time the
/// Core mutates the transfer).
private struct PendingCancellation: Identifiable {
    let modelID: UUID
    let action: () -> Void
    var id: UUID { modelID }
}

// MARK: - Presentation payloads (preview / folder)

/// Payload présenté par `.sheet(item:)` pour la preview QuickLook.
///
/// Suit exactement le pattern `TransferRequestPresentation` vu dans
/// `MainView.swift` : un struct minimal `Identifiable` qui ne porte
/// que l'id, le ViewModel fait le reste (résolution d'URL). Le nom
/// du fichier est inclus uniquement pour l'éventuel écran
/// "indisponible" (l'utilisateur voit alors quoi il essayait
/// d'ouvrir).
private struct HistoryPreviewPresentation: Identifiable, Equatable {
    let entryID: UUID
    let fileName: String
    var id: UUID { entryID }
}

/// Payload présenté par `.sheet(item:)` pour la feuille d'actions
/// (Aperçu / Partager / Supprimer). Suit le pattern minimal déjà
/// utilisé pour la preview : juste un id + le nom de fichier
/// (uniquement utilisé comme texte de fallback sur l'écran
/// d'indisponibilité).
private struct FileActionPresentation: Identifiable, Equatable {
    let entryID: UUID
    let fileName: String
    var id: UUID { entryID }
}

#if os(iOS)
/// Payload présenté par `.sheet(item:)` pour la feuille "Dossier"
/// sur iOS. macOS n'a pas besoin de struct équivalent : on délègue
/// directement à `NSWorkspace.activateFileViewerSelecting`.
private struct HistoryFolderPresentation: Identifiable, Equatable {
    let entryID: UUID
    var id: UUID { entryID }
}
#endif

// MARK: - Écran d'indisponibilité

/// Feuille présentée quand un transfert terminé n'a plus de fichier
/// local accessible (redémarrage de l'app, fichier nettoyé par une
/// autre session, etc.). On évite ainsi un crash ou une feuille
/// blanche : l'utilisateur a un message clair et un bouton pour
/// refermer.
private struct HistoryUnavailableView: View {

    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: AirBridgeDesign.Spacing.md) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Fichier non disponible")
                    .font(AirBridgeDesign.Typography.headline)
                    .multilineTextAlignment(.center)
                Text(
                    "Le fichier d’origine n’est plus accessible localement. " +
                    "Vérifie le dossier de réception ou relance le " +
                    "transfert depuis l’autre appareil."
                )
                .font(AirBridgeDesign.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AirBridgeDesign.Spacing.lg)
                Button("Fermer") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, AirBridgeDesign.Spacing.sm)
            }
            .padding(AirBridgeDesign.Spacing.lg)
            .frame(maxWidth: 480)
            .navigationTitle("Aperçu indisponible")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { onDismiss() }
                }
            }
            #endif
        }
    }
}

// MARK: - View-local tint helper

private extension TransferUIStatus {

    /// Mirrors the tint used by `TransferProgressView` and
    /// `TransferStatusView`. Kept local to avoid leaking the
    /// mapping into the public design system surface — only the
    /// transfer feature needs it.
    var tint: Color {
        switch self {
        case .waiting: AirBridgeDesign.Color.info
        case .active: AirBridgeDesign.Color.accent
        case .awaitingConfirmation: AirBridgeDesign.Color.info
        case .completed: AirBridgeDesign.Color.success
        case .failed: AirBridgeDesign.Color.warning
        case .cancelled: AirBridgeDesign.Color.error
        }
    }
}
