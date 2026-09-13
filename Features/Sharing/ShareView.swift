//
//  ShareView.swift
//  AirBridge
//
//  Main share screen.
//
//  Shows the local device identity, the list of attached files, a
//  recipient picker, and a send button. The View is a pure adapter :
//  it reads the ViewModel and forwards user gestures (file pick,
//  drop, recipient tap, send) to it. It never reaches into the Core
//  directly.
//

import SwiftUI
import Network
internal import UniformTypeIdentifiers

/// Main share screen.
///
/// Cross-platform iOS + macOS. iOS-specific affordances (drag and
/// drop on iPad) are guarded by `#if os(iOS)`.
struct ShareView: View {

    @Bindable var core: AirBridgeCore

    /// Fichiers pré-attachés à la présentation (lot stationné par une
    /// extension de partage dans l'App Group). Vide pour le partage
    /// direct depuis l'app. Aucun envoi automatique : l'utilisateur
    /// choisit le destinataire puis envoie explicitement.
    var initialURLs: [URL] = []

    /// Notification d'issue d'un envoi, consommée par la surface qui
    /// héberge cette vue (feuille de lot). `true` = le Core a importé
    /// au moins un fichier. Jamais utilisée pour supprimer un fichier.
    var onSendResult: ((Bool) -> Void)? = nil

    @State private var viewModel: ShareViewModel?
    @State private var isFileImporterPresented = false
    @State private var lastError: ShareError?

#if os(iOS)
    @State private var isDropTargeted = false
#endif

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                Color.clear
                    .onAppear {
                        viewModel = ShareViewModel(core: core)
                        // Lot stationné par l'extension : on pré-attache les
                        // fichiers à la sélection, sans envoyer automatiquement.
                        if !initialURLs.isEmpty {
                            viewModel?.attach(urls: initialURLs)
                        }
                    }
            }
        }
        .navigationTitle("Partager")
        .alert(
            item: $lastError
        ) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(
        viewModel: ShareViewModel
    ) -> some View {
        VStack(spacing: AirBridgeDesign.Spacing.md) {
            header(viewModel: viewModel)
            preconditionsBanner(viewModel: viewModel)
            FilePreviewGrid(
                urls: viewModel.attachedURLs,
                onRemove: { index in
                    viewModel.remove(urlAt: index)
                }
            )
            RecipientSelector(
                recipients: viewModel.availableRecipients,
                connectedDeviceID: viewModel.connectedDevice?.id,
                showAll: viewModel.showAllRecipients,
                trustedPeerIDs: trustedPeerIDs(),
                onToggleShowAll: { newValue in
                    viewModel.showAllRecipients = newValue
                },
                onSelect: { device in
                    handleSend(to: device, viewModel: viewModel)
                }
            )
            actionBar(viewModel: viewModel)
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.md)
        .padding(.bottom, AirBridgeDesign.Spacing.md)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.data, .folder],
            allowsMultipleSelection: true,
            onCompletion: { result in
                handleSelection(
                    result,
                    viewModel: viewModel
                )
            }
        )
#if os(iOS)
        .onDrop(
            of: [.fileURL],
            isTargeted: $isDropTargeted,
            perform: { providers in
                handleDrop(
                    providers: providers,
                    viewModel: viewModel
                )
            }
        )
        .overlay(
            isDropTargeted ? dropOverlay : nil
        )
#endif
    }

    // MARK: - Header

    private func header(viewModel: ShareViewModel) -> some View {
        let local = viewModel.localDevice
        let kind = AirBridgeDesign.DeviceKind.from(
            model: local.model
        )
        return HStack(spacing: AirBridgeDesign.Spacing.sm) {
            DeviceAvatarView(
                kind: kind,
                size: .small,
                state: .idle
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(local.name)
                    .font(AirBridgeDesign.Typography.headline)
                Text(
                    viewModel.isConnected
                        ? "Connecté à "
                            + (viewModel.connectedDevice?.name ?? "")
                        : viewModel.connectionStateDescription
                )
                .font(AirBridgeDesign.Typography.caption)
                .foregroundStyle(
                    viewModel.isConnected
                        ? AirBridgeDesign.Color.success
                        : .secondary
                )
            }
            Spacer()
            if let total = viewModel.totalAttachedSize {
                Text(total)
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.xs)
    }

    // MARK: - Pre-conditions

    @ViewBuilder
    private func preconditionsBanner(
        viewModel: ShareViewModel
    ) -> some View {
        if !viewModel.isConnected {
            banner(
                icon: "antenna.radiowaves.left.and.right.slash",
                tint: .orange,
                title: "Connecte-toi d'abord à un appareil.",
                subtitle: "Aucun destinataire disponible tant que la session n'est pas ouverte."
            )
        } else if viewModel.attachedURLs.isEmpty {
            banner(
                icon: "doc.badge.plus",
                tint: .secondary,
                title: "Ajoute au moins un fichier.",
                subtitle: "Glisse-dépose ou utilise le bouton « Choisir »."
            )
        }
    }

    private func banner(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AirBridgeDesign.Typography.callout)
                Text(subtitle)
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(AirBridgeDesign.Spacing.sm)
        .background(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium
            )
            .fill(.regularMaterial)
        )
    }

    // MARK: - Action bar

    private func actionBar(
        viewModel: ShareViewModel
    ) -> some View {
        HStack(spacing: AirBridgeDesign.Spacing.sm) {
            Button {
                isFileImporterPresented = true
            } label: {
                Label(
                    "Choisir",
                    systemImage: "doc.badge.plus"
                )
                .frame(minHeight: AirBridgeDesign.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.data, .folder],
                allowsMultipleSelection: true,
                onCompletion: { result in
                    handleSelection(
                        result,
                        viewModel: viewModel
                    )
                }
            )

            Button {
                if let peer = viewModel.connectedDevice {
                    handleSend(
                        to: DiscoveredDevice(
                            device: peer,
                            endpoint: dummyEndpoint()
                        ),
                        viewModel: viewModel
                    )
                } else {
                    lastError = .noConnectedDevice
                }
            } label: {
                Label(
                    "Envoyer",
                    systemImage: "paperplane.fill"
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: AirBridgeDesign.minimumTapTarget
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canShare)
        }
    }

#if os(iOS)
    private var dropOverlay: some View {
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
            .fill(
                Color.accentColor.opacity(0.08)
            )
        )
        .overlay {
            VStack(spacing: AirBridgeDesign.Spacing.sm) {
                Image(
                    systemName: "square.and.arrow.down"
                )
                .font(.system(size: 32, weight: .light))
                Text("Dépose pour ajouter")
                    .font(AirBridgeDesign.Typography.callout)
            }
            .foregroundStyle(.tint)
        }
    }
#endif

    // MARK: - Send / Selection handlers

    private func handleSend(
        to device: DiscoveredDevice,
        viewModel: ShareViewModel
    ) {
        if !viewModel.isConnected {
            lastError = .noConnectedDevice
            Haptics.warning()
            return
        }
        if viewModel.attachedURLs.isEmpty {
            lastError = .noFiles
            Haptics.warning()
            return
        }
        if device.id != viewModel.connectedDevice?.id {
            lastError = .recipientMismatch
            Haptics.warning()
            return
        }
        let accepted = viewModel.send(to: device)
        // The Core signals its pre-condition check through the
        // return value : a `false` means the request was refused
        // (peer just dropped, files were already cleared, etc.) —
        // surface a warning so the user feels the no-op.
        let outcome = accepted
        // Quand cette vue est hébergée par la feuille de lot partagé, on
        // notifie la surface hôte de l'issue RÉELLE de l'envoi — c'est
        // elle et elle seule qui décide de la vie du lot stationné.
        // Aucune suppression n'a lieu ici.
        onSendResult?(outcome)
        if accepted {
            Haptics.success()
        } else {
            Haptics.warning()
        }
    }

    private func handleSelection(
        _ result: Result<[URL], Error>,
        viewModel: ShareViewModel
    ) {
        switch result {
        case .success(let urls):
            let accepted = urls.filter(\.isFileURL)
            viewModel.attach(urls: accepted)
            // A new file is a discrete physical action — a tap on
            // the picker thumbnail or a drop — so it deserves a
            // medium impact rather than a silent acknowledgement.
            if !accepted.isEmpty {
                Haptics.impact(.medium)
            }
        case .failure(let error):
            lastError = .selectionFailed(
                error.localizedDescription
            )
            Haptics.warning()
        }
    }

#if os(iOS)
    /// Handler drop iOS (iPad). Délègue la conversion des
    /// providers au `ShareDropHandler` partagé (Phase 5) puis
    /// transfère les URL au ViewModel. On reste `#if os(iOS)`
    /// car le `.onDrop` parent n'est câblé que sur iPad — la
    /// version macOS vit dans `MainView`.
    private func handleDrop(
        providers: [NSItemProvider],
        viewModel: ShareViewModel
    ) -> Bool {
        Task { @MainActor in
            let urls = await ShareDropHandler.loadFileURLs(
                from: providers
            )
            guard !urls.isEmpty else { return }
            viewModel.attach(urls: urls)
            // Le drop est une action physique discrète (le doigt
            // se pose sur l'écran) — un impact medium fait
            // écho au geste, comme pour le `fileImporter`.
            Haptics.impact(.medium)
        }
        return true
    }
#endif

    // MARK: - Helpers

    /// The "send" button doesn't always have a real `DiscoveredDevice`
    /// in scope (only the connected `Device`), so we wrap it in a
    /// placeholder. The `endpoint` is unused by the Core's
    /// `importAndRequestItems` path; a `host:port` value of "0.0.0.0:0"
    /// is a safe dummy.
    private func dummyEndpoint() -> NWEndpoint {
        NWEndpoint.hostPort(
            host: "0.0.0.0",
            port: 0
        )
    }

    /// Reads the pairing store. The store is not @Observable, so we
    /// read it once per render via the ViewModel — the Discovery view
    /// follows the same pattern.
    private func trustedPeerIDs() -> Set<UUID> {
        Set(
            core.pairingStore
                .loadAll()
                .filter { $0.value.trustState == .trusted }
                .keys
        )
    }
}

// MARK: - Errors

/// User-facing error surfaced by the share screen.
private struct ShareError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static let noConnectedDevice = ShareError(
        title: "Aucun appareil connecté",
        message: "Connecte-toi à un appareil avant d'envoyer des fichiers."
    )

    static let noFiles = ShareError(
        title: "Aucun fichier à envoyer",
        message: "Ajoute au moins un fichier à la sélection."
    )

    static let recipientMismatch = ShareError(
        title: "Destinataire indisponible",
        message: "L'appareil sélectionné n'est pas la session active."
    )

    static func selectionFailed(
        _ detail: String
    ) -> ShareError {
        ShareError(
            title: "Sélection impossible",
            message: detail
        )
    }
}
