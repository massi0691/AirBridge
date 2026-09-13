//
//  HistoryPreviewView.swift
//  AirBridge
//
//  QuickLook preview sheet for completed transfers.
//
//  SwiftUI n'expose pas (encore) d'API publique stable et multi-plateforme
//  pour `QLPreviewController` / `QLPreviewPanel`. On passe donc par un
//  `UIViewControllerRepresentable` sur iOS — c'est le pattern recommandé par
//  Apple pour intégrer un contrôleur UIKit dans une hiérarchie SwiftUI,
//  sans dépendre d'un wrapper privé susceptible de casser entre les
//  versions d'OS. La feuille présente le fichier avec le viewer natif
//  (PDF, vidéo, images, texte) sans déclencher de permission réseau, car
//  QuickLook charge le fichier localement via le sandbox de l'app.
//
//  macOS : pas de preview dans l'app. `NSWorkspace.shared.open(url)`
//  délègue au viewer par défaut de l'utilisateur, ce qui est plus
//  cohérent avec le comportement système (QuickTime pour les vidéos,
//  Preview pour les PDF, etc.). C'est aussi le pattern utilisé ailleurs
//  dans le projet pour ouvrir un fichier reçu hors de l'app.
//

import SwiftUI
import QuickLook
#if os(macOS)
import AppKit
#endif

/// Affiche un fichier local via QuickLook (iOS) ou via l'app système par
/// défaut (macOS).
///
/// Le contrôleur est présenté comme une feuille SwiftUI sur iOS ; sur
/// macOS, l'ouverture est immédiate et la vue ne fait que demander à
/// `NSWorkspace` de présenter le fichier. Le callback `onDismiss` est
/// appelé une fois la feuille fermée (iOS) — sur macOS il est appelé
/// immédiatement après l'ouverture, car aucun surface ne reste à l'écran.
struct HistoryPreviewView: View {

    /// Fichier à prévisualiser. La vue ne vérifie pas l'existence du
    /// fichier — l'appelant (`TransferView`) le fait déjà avant
    /// d'instancier la sheet.
    let url: URL

    /// Callback invoqué quand la feuille disparaît (iOS) ou juste
    /// après le `NSWorkspace.open` (macOS). Le ViewModel ne s'en sert
    /// que pour réinitialiser son état de présentation.
    var onDismiss: () -> Void

    var body: some View {
#if os(iOS)
        // Wrapper UIKit : délègue le rendu à `QLPreviewController`,
        // qui supporte PDF / vidéo / images / texte / iWork / Office
        // sans qu'on ait à toucher au type detection côté SwiftUI.
        QuickLookPreviewRepresentable(
            url: url,
            onDismiss: onDismiss
        )
        .ignoresSafeArea()
#else
        // macOS : on délègue au système. La vue se referme
        // immédiatement, l'utilisateur bascule sur l'app native
        // associée au type de fichier. Si l'ouverture échoue (pas
        // d'app par défaut, fichier inaccessible), `NSWorkspace.open`
        // renvoie `false` — on appelle quand même `onDismiss` pour
        // laisser le ViewModel nettoyer son état.
        Color.clear
            .onAppear {
                let opened = NSWorkspace.shared.open(url)
                if !opened {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [url]
                    )
                }
                onDismiss()
            }
#endif
    }
}

#if os(iOS)

// MARK: - iOS QLPreviewController wrapper

/// Adapte `QLPreviewController` (UIKit) à SwiftUI via
/// `UIViewControllerRepresentable`.
///
/// On utilise deux coordinateurs pour gérer le cycle de vie :
///   - `Coordinator` joue le rôle de `QLPreviewControllerDelegate`
///     pour détecter la fermeture de la feuille et appeler
///     `onDismiss` une seule fois.
///   - Le `makeUIViewController` configure le contrôleur avec
///     l'unique URL à prévisualiser.
@MainActor
private struct QuickLookPreviewRepresentable: UIViewControllerRepresentable {

    let url: URL
    var onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: onDismiss)
    }

    func makeUIViewController(
        context: Context
    ) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: QLPreviewController,
        context: Context
    ) {
        // Rien à mettre à jour : la feuille est présentée avec une
        // seule URL figée, capturée à la construction. Un changement
        // d'URL se traduit par une nouvelle instance de la vue (le
        // ViewModel réinitialise son identifiant SwiftUI).
    }

    /// DataSource minimal : un seul fichier à prévisualiser.
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {

        let url: URL
        var onDismiss: () -> Void
        // Verrou anti-double-dismiss : `QLPreviewController` peut
        // appeler `previewControllerDidDismiss` plusieurs fois selon
        // les chemins (fermeture utilisateur, animation, changement
        // d'orientation). On ne veut appeler `onDismiss` qu'une fois.
        private var didDismiss = false

        init(url: URL, onDismiss: @escaping () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        // MARK: QLPreviewControllerDataSource

        func numberOfPreviewItems(
            in controller: QLPreviewController
        ) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            // `NSURL` se conforme automatiquement à `QLPreviewItem`
            // via une catégorie système ; pas besoin d'un wrapper
            // custom pour un fichier local simple.
            url as NSURL
        }

        // MARK: QLPreviewControllerDelegate

        func previewControllerDidDismiss(
            _ controller: QLPreviewController
        ) {
            guard !didDismiss else { return }
            didDismiss = true
            onDismiss()
        }
    }
}

#endif