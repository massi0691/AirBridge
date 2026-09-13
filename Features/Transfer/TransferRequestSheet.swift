//
//  TransferRequestSheet.swift
//  AirBridge
//

import SwiftUI

/// Demande d'autorisation groupée.
///
/// La feuille lit le lot courant en direct : les fichiers qui rejoignent
/// une demande déjà affichée apparaissent sans la refermer. Quand le lot
/// disparaît (accepté, refusé, connexion perdue), le présentateur ferme
/// la feuille.
struct TransferRequestSheet: View {

    @Bindable var core: AirBridgeCore

    @Environment(\.dismiss) private var dismiss

    var body: some View {

        NavigationStack {

            VStack(spacing: 20) {

                if let batch = core.pendingTransferBatch {

                    Image(
                        systemName: "square.and.arrow.down"
                    )
                    .font(
                        .system(size: 48)
                    )

                    Text(title(batch))
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    details(batch)

                    buttons()

                } else {

                    ProgressView()
                }
            }
            .padding()
            .frame(
                minWidth: 320,
                minHeight: 260
            )
            .navigationTitle(
                "Demande de transfert"
            )
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Contenu

private extension TransferRequestSheet {

    func title(
        _ batch: PendingTransferBatch
    ) -> String {

        guard batch.fileCount > 1 else {

            return "\(batch.sender.name) veut vous envoyer un fichier"
        }

        return "\(batch.sender.name) veut vous envoyer \(batch.fileCount) fichiers"
    }

    func details(
        _ batch: PendingTransferBatch
    ) -> some View {

        VStack(spacing: 8) {

            Text(
                ByteCountFormatter.string(
                    fromByteCount: batch.totalSize,
                    countStyle: .file
                )
            )
            .font(.title3)
            .bold()

            Text(
                "\(batch.fileCount) fichier(s) au total"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView {

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {

                    ForEach(batch.requests) { pending in

                        HStack {

                            fileKindIcon(
                                fileName: pending.request.fileName
                            )

                            Text(
                                pending.request.fileName
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)

                            Spacer(minLength: 12)

                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount:
                                        pending.request.fileSize,
                                    countStyle: .file
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
            }
            .frame(maxHeight: 200)
        }
    }

    /// Icône de type déduite du nom de fichier. La logique de
    /// classification vit désormais dans `TransferFileKind` (vue
    /// d'origine) — conservée locale pour éviter de toucher le
    /// Core ou les fichiers de `Features/Transfer/` déjà
    /// stabilisés : la feuille est un écran transitoire qui n'a
    /// pas besoin de partager le modèle d'icône du tableau de
    /// bord.
    private func fileKindIcon(
        fileName: String
    ) -> some View {

        let kind = TransferFileKindSummary(
            fileName: fileName
        )

        return Image(systemName: kind.symbolName)
            .font(.caption)
            .foregroundStyle(kind.tint)
    }

    /// La fermeture est explicite : si le cœur ne trouve plus de connexion
    /// pour répondre, le lot reste en place et la feuille, non
    /// renvoyable au doigt, bloquerait l'écran.
    func buttons() -> some View {

        HStack {

            Button(
                "Refuser",
                role: .destructive
            ) {
                core.rejectPendingTransfer(
                    reason: "Refusé par l’utilisateur"
                )

                dismiss()
            }

            Button("Accepter") {

                core.acceptPendingTransfer()

                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Mini-classifieur de type de fichier

/// Vue compacte des types de fichier utilisés par la feuille
/// d'autorisation. Reprend les catégories de l'ancien
/// `TransferFileKind` sans dépendre du module d'UI historique
/// (que la phase 9-bis supprime).
private enum TransferFileKindSummary {

    case image
    case video
    case audio
    case pdf
    case archive
    case other

    init(fileName: String) {

        let ext = URL(
            fileURLWithPath: fileName
        )
        .pathExtension
        .lowercased()

        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "gif",
             "tiff", "webp", "bmp":
            self = .image
        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            self = .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg":
            self = .audio
        case "pdf":
            self = .pdf
        case "zip", "tar", "gz", "7z", "rar":
            self = .archive
        default:
            self = .other
        }
    }

    var symbolName: String {

        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .pdf: "doc.richtext"
        case .archive: "doc.zipper"
        case .other: "doc"
        }
    }

    var tint: Color {

        switch self {
        case .image: .purple
        case .video: .indigo
        case .audio: .pink
        case .pdf: .red
        case .archive: .orange
        case .other: .secondary
        }
    }
}