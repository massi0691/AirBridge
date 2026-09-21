//
//  FileActionSheet.swift
//  AirBridge
//
//  Feuille d'actions sur un fichier transféré (historique).
//  Pattern AirDrop-like : on liste explicitement les actions
//  disponibles plutôt que de basculer immédiatement vers la
//  preview. Compatible iOS et macOS — les affordances purement
//  macOS (Afficher dans le Finder) sont gardées derrière
//  `#if os(macOS)`.
//
//  Cette vue ne mute aucun état elle-même : elle remonte les
//  gestes au caller (`TransferView`) via les closures `onPreview`,
//  `onShare`, etc. Le caller route ensuite vers les helpers
//  existants (`previewPresentation`, `deleteStoredFile`,
//  `removeFromHistory`). Cela garde une seule source de vérité
//  pour la résolution d'URL et la suppression.
//

import SwiftUI

/// Mapping local entre `TransferUIStatus` et une couleur système.
///
/// Le `tint` "officiel" est `private` dans `TransferStatusView.swift`
/// — on ne peut donc pas y accéder depuis ce fichier. Plutôt que de
/// toucher à la visibilité partagée, on re-déclare la même palette
/// localement : elle est minuscule (5 cas, 5 couleurs système) et
/// c'est la définition de l'identité visuelle du statut qui compte,
/// pas sa déclaration technique. Si la palette évolue, il faut
/// mettre à jour les deux endroits — c'est documenté ici.
private extension TransferUIStatus {
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

/// Feuille d'actions sur un fichier transféré.
///
/// Toutes les actions destructives passent par un
/// `confirmationDialog` interne : on ne supprime jamais sans
/// confirmation explicite, sauf "Supprimer de la liste" qui est
/// considérée comme cosmétique (l'historique est volatile par
/// construction — voir `TransferHistoryStore.clearAll()`).
struct FileActionSheet: View {

    let model: TransferUIModel
    let localURL: URL?
    let onPreview: () -> Void
    let onShare: () -> Void
    let onShowInFinder: () -> Void
    let onShowFolder: () -> Void
    let onDeleteFromStorage: () -> Void
    let onDeleteFromList: () -> Void
    let onDeleteBoth: () -> Void
    let onCancel: () -> Void

    /// Confirmation en attente pour les actions destructives.
    @State private var pendingConfirmation: PendingConfirmation?

    /// Type d'action destructive en attente de confirmation. On
    /// utilise un enum `Identifiable` pour pouvoir brancher le
    /// `confirmationDialog` proprement (les dialogs SwiftUI
    /// n'acceptent pas une simple enum non-Identifiable comme
    /// `presenting`).
    private enum PendingConfirmation: Identifiable {
        case deleteStorage
        case deleteBoth
        var id: String {
            switch self {
            case .deleteStorage: "deleteStorage"
            case .deleteBoth: "deleteBoth"
            }
        }
    }

    // MARK: - Computed availability

    private var hasFile: Bool { localURL != nil }

    /// Vrai si le fichier a été reçu (téléchargé) sur cet appareil.
    /// On adapte l'UX à cette direction : pour un fichier reçu, on
    /// n'expose plus "Partager" (le fichier est déjà local) mais
    /// "Afficher dans le Finder" en action principale, et on retire
    /// "Supprimer du stockage" au profit d'un unique "Supprimer" qui
    /// efface à la fois le fichier et l'entrée d'historique.
    private var isReceived: Bool {
        model.direction == .incoming
    }

    private var sizeText: String {
        ByteCountFormatter.string(
            fromByteCount: model.totalBytes,
            countStyle: .file
        )
    }

    private var subtitleText: String {
        let direction = model.direction == .incoming ? "Reçu de" : "Envoyé à"
        return "\(direction) \(model.peer.name)"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .padding(.vertical, AirBridgeDesign.Spacing.sm)
            actionsList
        }
        .padding(.vertical, AirBridgeDesign.Spacing.lg)
        .frame(maxWidth: 560)
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium
            )
        )
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            presenting: pendingConfirmation
        ) { pending in
            Button(role: .destructive) {
                run(pending)
                onCancel()
            } label: {
                Text(confirmationActionLabel(for: pending))
            }
            Button("Annuler", role: .cancel) {
                pendingConfirmation = nil
            }
        } message: { pending in
            Text(confirmationMessage(for: pending))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AirBridgeDesign.Spacing.md) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: AirBridgeDesign.Radius.medium
                )
                .fill(model.status.tint.opacity(0.12))
                .frame(width: 56, height: 56)
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
                    .font(AirBridgeDesign.Typography.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(subtitleText)
                    .font(AirBridgeDesign.Typography.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: AirBridgeDesign.Spacing.xs) {
                    Text(sizeText)
                        .font(AirBridgeDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                    if let startDate = model.startDate {
                        Text("·")
                            .font(AirBridgeDesign.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(startDate, style: .date)
                            .font(AirBridgeDesign.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.lg)
    }

    // MARK: - Actions list

    /// Liste des actions proposées. On adapte la liste à la
    /// direction du fichier :
    ///   - Sortant : Aperçu · Partager · (Finder macOS) · Supprimer du
    ///     stockage · Supprimer de la liste · Supprimer les deux.
    ///   - Entrant (téléchargé) : Aperçu · Afficher le dossier (iOS) /
    ///     Afficher dans le Finder (macOS) · Supprimer de la liste ·
    ///     Supprimer. On retire "Partager" (le fichier est déjà local,
    ///     l'action n'apporte rien) et "Supprimer du stockage"
    ///     (équivalent fonctionnel de "Supprimer" qui efface aussi le
    ///     fichier).
    private var actionsList: some View {
        VStack(spacing: AirBridgeDesign.Spacing.sm) {
            previewAction
            if isReceived {
#if os(macOS)
                showInFinderAction
#else
                showFolderAction
#endif
                deleteFromListAction
                deleteBothAction
            } else {
                shareAction
#if os(macOS)
                showInFinderAction
#endif
                deleteFromStorageAction
                deleteFromListAction
                deleteBothAction
            }
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.lg)
    }

    // MARK: - Individual actions

    private var previewAction: some View {
        actionButton(
            title: "Aperçu",
            systemImage: "eye",
            role: nil,
            isEnabled: hasFile,
            accessibilityHint: "Ouvre le fichier dans une vue rapide."
        ) {
            onPreview()
        }
    }

    private var shareAction: some View {
        Group {
            if let url = localURL {
                ShareLink(item: url) {
                    actionLabel(
                        title: "Partager",
                        systemImage: "square.and.arrow.up",
                        role: nil,
                        isEnabled: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Partager"))
                .accessibilityHint(Text("Ouvre la feuille de partage système."))
            } else {
                actionButton(
                    title: "Partager",
                    systemImage: "square.and.arrow.up",
                    role: nil,
                    isEnabled: false,
                    accessibilityHint: nil
                ) {
                    onShare()
                }
            }
        }
    }

#if os(macOS)
    private var showInFinderAction: some View {
        actionButton(
            title: "Afficher dans le Finder",
            systemImage: "folder",
            role: nil,
            isEnabled: hasFile,
            accessibilityHint: "Ouvre une fenêtre Finder ciblant le fichier."
        ) {
            onShowInFinder()
        }
    }
#else
    private var showFolderAction: some View {
        actionButton(
            title: "Afficher le dossier",
            systemImage: "folder",
            role: nil,
            isEnabled: hasFile,
            accessibilityHint: "Ouvre le dossier de réception dans l'application Fichiers."
        ) {
            onShowFolder()
        }
    }
#endif

    private var deleteFromStorageAction: some View {
        actionButton(
            title: "Supprimer du stockage",
            systemImage: "trash",
            role: .destructive,
            isEnabled: hasFile,
            accessibilityHint: "Supprime uniquement le fichier sur le disque. L’entrée reste dans l’historique."
        ) {
            pendingConfirmation = .deleteStorage
        }
    }

    private var deleteFromListAction: some View {
        actionButton(
            title: "Supprimer de la liste",
            systemImage: "list.bullet.rectangle",
            role: nil,
            isEnabled: true,
            accessibilityHint: "Retire l’entrée de l’historique. Le fichier sur disque n’est pas touché."
        ) {
            onDeleteFromList()
            onCancel()
        }
    }

    private var deleteBothAction: some View {
        // Pour un fichier reçu (téléchargé), on simplifie le label en
        // "Supprimer" : c'est l'unique action de suppression (on a
        // retiré "Supprimer du stockage" et "Partager" dans ce cas).
        // On garde le label long pour les fichiers sortants où
        // plusieurs options de suppression coexistent.
        let title = isReceived
            ? "Supprimer"
            : "Supprimer le fichier et l’entrée"
        return actionButton(
            title: title,
            systemImage: "trash.slash",
            role: .destructive,
            isEnabled: hasFile,
            accessibilityHint: "Supprime à la fois le fichier sur disque et l’entrée dans l’historique."
        ) {
            pendingConfirmation = .deleteBoth
        }
    }

    // MARK: - Action button helpers

    /// Bouton d'action plein largeur avec icône + label, hauteur
    /// minimale `minimumTapTarget` (44pt) pour rester conforme aux
    /// HIG sur iOS et cliquable confortablement sur macOS.
    private func actionButton(
        title: String,
        systemImage: String,
        role: ButtonRole?,
        isEnabled: Bool,
        accessibilityHint: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            actionLabel(
                title: title,
                systemImage: systemImage,
                role: role,
                isEnabled: isEnabled
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title))
        .accessibilityHint(accessibilityHint.map(Text.init) ?? Text(""))
    }

    /// Contenu visuel d'un bouton d'action : HStack(icône + label),
    /// padding standard, opacité réduite si désactivé pour le
    /// rendu visuel (l'état `disabled` du Button gère déjà l'accès).
    private func actionLabel(
        title: String,
        systemImage: String,
        role: ButtonRole?,
        isEnabled: Bool
    ) -> some View {
        let foreground: Color = {
            if role == .destructive { return .red }
            return .primary
        }()
        return HStack(spacing: AirBridgeDesign.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 28)
            Text(title)
                .font(AirBridgeDesign.Typography.body)
                .foregroundStyle(foreground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AirBridgeDesign.Spacing.md)
        .frame(
            maxWidth: .infinity,
            minHeight: AirBridgeDesign.minimumTapTarget,
            alignment: .leading
        )
        .background(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.small
            )
            .fill(
                isEnabled
                    ? Color.secondary.opacity(0.08)
                    : Color.secondary.opacity(0.04)
            )
        )
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    // MARK: - Confirmation plumbing

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .deleteStorage:
            return "Supprimer du stockage ?"
        case .deleteBoth:
            // Cohérence avec le label du bouton : on simplifie pour
            // les fichiers reçus, où ce titre correspond à
            // l'unique action de suppression exposée.
            return isReceived
                ? "Supprimer ?"
                : "Supprimer le fichier et l’entrée ?"
        case .none:
            return ""
        }
    }

    private func confirmationActionLabel(
        for pending: PendingConfirmation
    ) -> String {
        switch pending {
        case .deleteStorage: return "Supprimer"
        case .deleteBoth: return "Supprimer"
        }
    }

    private func confirmationMessage(
        for pending: PendingConfirmation
    ) -> String {
        switch pending {
        case .deleteStorage:
            return "Le fichier sera supprimé du disque. L’entrée restera dans l’historique."
        case .deleteBoth:
            return "Le fichier et l’entrée d’historique seront supprimés. Cette action est irréversible."
        }
    }

    private func run(_ pending: PendingConfirmation) {
        switch pending {
        case .deleteStorage:
            onDeleteFromStorage()
        case .deleteBoth:
            onDeleteBoth()
        }
    }

    /// Binding booléen qui suit `pendingConfirmation` — permet de
    /// brancher un `confirmationDialog(item:)` standard tout en
    /// gardant l'enum comme source de vérité pour le message et le
    /// label du bouton.
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { newValue in
                if !newValue {
                    pendingConfirmation = nil
                }
            }
        )
    }
}