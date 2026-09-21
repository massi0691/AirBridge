//
//  MainView.swift
//  AirBridge
//

import SwiftUI
import OSLog
internal import UniformTypeIdentifiers

/// Point d'entrée principal de l'application.
///
/// iPhone : barre d'onglets (Appareils, Transferts, Réglages), chaque
/// onglet possédant sa propre pile de navigation, donc le détail d'un
/// transfert s'empile sans quitter l'onglet.
///
/// macOS : barre latérale avec les mêmes sections et une colonne de
/// détail, où le détail d'un transfert s'empile également.
///
/// La demande d'autorisation est présentée ici, à la racine : elle doit
/// s'afficher quelle que soit la section consultée.
struct MainView: View {

    @Bindable var core: AirBridgeCore

    /// Contrôleur du lot stationné par une extension de partage
    /// (Finder macOS / Share Extension iOS). Injection explicite :
    /// `MainView` n'est instanciée qu'une seule fois (AirBridgeApp).
    let pendingShareController: PendingShareController

    @State private var presentedRequest: TransferRequestPresentation?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "ui.main"
    )

#if os(macOS)
    @State private var selectedSection: AppSection? = .devices

    /// Indicateur de survol drop global macOS. Tant qu'un fichier
    /// du Finder survole la fenêtre, on affiche un overlay
    /// similaire à celui de `ShareView` (ligne 261-291) pour
    /// signaler à l'utilisateur que la zone accepte le drop.
    @State private var isDropTargetedGlobal: Bool = false
#endif

    var body: some View {

        sections
            .sheet(item: $presentedRequest) { _ in

                TransferRequestSheet(core: core)
            }
            .sheet(
                item: pendingShareBinding
            ) { item in
                // Lot stationné par l'extension : présentation de la
                // surface d'envoi EXISTANTE avec les fichiers pré-attachés,
                // sans envoi automatique. « Fermer » ne supprime rien.
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

                synchronizeRequestSheet(
                    batchID: newValue
                )
            }
#if os(macOS)
            // Drag-and-drop global macOS (Phase 5) : l'utilisateur
            // peut glisser un fichier du Finder n'importe où sur la
            // fenêtre, et le transfert démarre automatiquement si
            // un pair est connecté. Si aucun pair n'est lié, on
            // refuse le drop (return false) et on joue un warning
            // haptique. La conversion des providers est déléguée à
            // `ShareDropHandler.loadFileURLs` pour rester cohérent
            // avec le drop iOS existant sur `ShareView`.
            .onDrop(
                of: [.fileURL],
                isTargeted: $isDropTargetedGlobal,
                perform: handleGlobalDrop
            )
            .overlay {
                if isDropTargetedGlobal && isConnected {
                    globalDropOverlay
                }
            }
#endif
    }
}

// MARK: - Sections

/// Sections de l'application, communes aux deux plateformes.
///
/// `.history` a été retiré au profit du nouvel écran « Transferts »
/// (qui présente les transferts actifs et terminés dans deux onglets
/// internes). Les onglets restants sont branchés directement sur les
/// nouvelles Views de `Features/` ; `.settings` reste temporairement
/// sur l'ancienne `SettingsView` parce qu'aucun équivalent n'a encore
/// été produit côté `Features/`.
enum AppSection: String, CaseIterable, Identifiable, Hashable {

    case devices
    case transfers
    case settings

    var id: String { rawValue }

    var title: String {

        switch self {
        case .devices: "Appareils"
        case .transfers: "Transferts"
        case .settings: "Réglages"
        }
    }

    var symbolName: String {

        switch self {
        case .devices: "antenna.radiowaves.left.and.right"
        case .transfers: "arrow.left.arrow.right"
        case .settings: "gearshape"
        }
    }
}

private extension MainView {

    @ViewBuilder
    var sections: some View {

#if os(iOS)

        TabView {

            ForEach(AppSection.allCases) { section in

                NavigationStack {
                    content(for: section)
                }
                .tabItem {
                    Label(
                        section.title,
                        systemImage: section.symbolName
                    )
                }
            }
        }

#else

        NavigationSplitView {

            List(
                AppSection.allCases,
                selection: $selectedSection
            ) { section in

                NavigationLink(value: section) {
                    Label(
                        section.title,
                        systemImage: section.symbolName
                    )
                }
            }
            .navigationTitle("AirBridge")

        } detail: {
            shareToolbarContent


            NavigationStack {

                if let selectedSection {
                    content(for: selectedSection)

                } else {
                    ContentUnavailableView(
                        "Sélectionnez une section",
                        systemImage: "sidebar.left"
                    )
                }
            }
        }

#endif
    }

    @ViewBuilder
    func content(
        for section: AppSection
    ) -> some View {

        switch section {

        case .devices:
            // Phase 1 : Radar immersif plein écran avec pairing automatique
            RadarFullScreenView(core: core)

        case .transfers:
            TransferView(core: core)

        case .settings:
            // Pas d'équivalent dans `Features/` pour l'instant : la
            // nouvelle UI ne couvre que Discovery / Sharing /
            // Transfert / Pairing. On garde l'ancienne vue
            // temporairement, avec sa liste d'appareils appairés,
            // ses notifications, etc.
            SettingsView(
                receivedFolderStore:
                    core.receivedFolderStore,
                notificationManager: core.notificationManager,
                pairingStore: core.pairingStore,
                core: core
            )
        }
    }

    /// Bouton "Envoyer des fichiers" dans la barre d'outils macOS.
    /// Affiché uniquement quand un pair est connecté.
    @ViewBuilder
    var shareToolbarContent: some View {
        if core.connectionManager.connectedDevice != nil {
            ShareView(core: core)
        } else {
            ContentUnavailableView(
                "Aucun appareil connecté",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Connectez-vous à un appareil pour envoyer des fichiers.")
            )
        }
    }
}

// MARK: - Demande d'autorisation

/// Identifiant du lot présenté, pour piloter la feuille par valeur.
///
/// Le lot lui-même n'est pas copié : la feuille lit toujours l'état
/// courant du cœur, donc un fichier qui rejoint la demande apparaît sans
/// refermer la feuille.
private struct TransferRequestPresentation: Identifiable, Equatable {
    let id: UUID
}

private extension MainView {

    /// La présentation suit le modèle : un lot apparaît, la feuille
    /// s'ouvre ; le lot disparaît (accepté, refusé, connexion perdue),
    /// la feuille se referme.
    func synchronizeRequestSheet(
        batchID: UUID?
    ) {

        guard let batchID else {

            if presentedRequest != nil {

                presentedRequest = nil

                logger.info("Sheet de transfert fermée automatiquement")
            }

            return
        }

        guard presentedRequest?.id != batchID else {
            return
        }

        presentedRequest = TransferRequestPresentation(
            id: batchID
        )
    }
}

// MARK: - Drop-and-drop global macOS (Phase 5)

private extension MainView {

    /// Vrai si un pair est actuellement connecté. Lu via le
    /// `connectionManager` du Core pour rester synchronisé avec
    /// l'état réel (le Core étant `@Observable`, les changements
    /// re-rendent la vue).
    var isConnected: Bool {
        core.connectionManager.connectedDevice != nil
    }

    /// Handler drop global macOS. Reçoit les `NSItemProvider`
    /// déposés n'importe où sur la fenêtre, les convertit via le
    /// `ShareDropHandler` partagé, et route vers le Core si un
    /// pair est connecté.
    ///
    /// Retour :
    ///   - `true`  : le drop est accepté, l'overlay se ferme, le
    ///     Core reçoit les URL.
    ///   - `false` : aucun pair connecté, ou aucun fichier
    ///     extractible — on refuse le drop pour que l'OS ne joue
    ///     pas l'animation de retour vers le Finder, et on
    ///     prévient l'utilisateur via un warning haptique.
    @MainActor
    func handleGlobalDrop(
        providers: [NSItemProvider]
    ) -> Bool {
        // Pré-condition : on refuse le drop tant qu'aucun pair
        // n'est lié. `core.importAndRequestItems` re-vérifierait
        // la condition, mais en silence (juste un `print`). On
        // préfère un refus explicite + haptique pour que
        // l'utilisateur comprenne pourquoi rien ne se passe.
        guard isConnected else {
            Haptics.warning()
            return false
        }

        Task { @MainActor in
            let urls = await ShareDropHandler.loadFileURLs(
                from: providers
            )
            guard !urls.isEmpty else {
                // Aucun fichier exploitable dans le drop — on
                // prévient sans déranger (le warning couvre déjà
                // l'absence de pair, ici on reste muet : un
                // payload malformé est rarissime et le refus
                // silencieux est moins agressif qu'un haptique).
                return
            }
            // Le Core se charge de la file FIFO, des
            // security-scoped resources, et de la demande de
            // transfert vers le pair connecté. C'est exactement
            // le même chemin que le bouton « Choisir » de
            // `DiscoveryView` (ligne 311), donc le comportement
            // est strictement identique.
            core.importAndRequestItems(urls: urls)
            Haptics.impact(.medium)
        }
        return true
    }

    /// Overlay global macOS pendant le survol. Reprend le visuel
    /// de l'overlay de `ShareView` (cadre pointillé + libellé
    /// « Dépose pour envoyer ») mais est conditionné par
    /// `isConnected` : si l'utilisateur survole sans pair lié,
    /// l'overlay ne s'affiche pas (le drop est de toute façon
    /// refusé dans le handler).
    @ViewBuilder
    var globalDropOverlay: some View {
        RoundedRectangle(
            cornerRadius: AirBridgeDesign.Radius.large
        )
        .strokeBorder(
            Color.accentColor,
            style: StrokeStyle(
                lineWidth: 2,
                dash: [6, 4]
            )
        )
        .background(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.large
            )
            .fill(Color.accentColor.opacity(0.08))
        )
        .overlay {
            VStack(spacing: AirBridgeDesign.Spacing.sm) {
                Image(
                    systemName: "square.and.arrow.down"
                )
                .font(.system(size: 32, weight: .light))
                Text("Dépose pour envoyer")
                    .font(AirBridgeDesign.Typography.callout)
            }
            .foregroundStyle(.tint)
        }
        .padding(AirBridgeDesign.Spacing.md)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Feuille de lot partagé (macOS + iOS)

private extension MainView {

    /// Binding pilotant la feuille de lot depuis `PendingShareController`.
    /// SwiftUI ferme la feuille en écrivant `nil` ; la fermeture est
    /// routée vers `dismissed()` — aucune suppression de fichiers.
    var pendingShareBinding: Binding<PendingShareItem?> {
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