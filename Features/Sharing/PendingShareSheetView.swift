//
//  PendingShareSheetView.swift
//  AirBridge
//
//  Feuille de présentation d'un lot stationné par une extension de
//  partage (Finder Service macOS / Share Extension iOS) dans le
//  conteneur App Group. Extraite de `MainView` pour être réutilisée
//  par l'espace de travail macOS (`MacTransferWorkspaceView`) sans
//  duplication — le comportement est strictement identique.
//

import SwiftUI

/// Présente les fichiers d'un lot stationné par une extension dans
/// l'interface d'envoi existante, SANS envoi automatique : l'utilisateur
/// choisit le destinataire puis envoie explicitement. Après un envoi
/// effectivement consommé par le moteur, `finish(imported: true)` clôt la
/// feuille ; les fichiers de lot non livrés sont conservés pour retry.
struct PendingShareSheetView: View {
    let core: AirBridgeCore
    let item: PendingShareItem
    let controller: PendingShareController

    var body: some View {
        NavigationStack {
            ShareView(
                core: core,
                initialURLs: item.urls,
                onSendResult: { accepted in
                    guard accepted else { return }
                    controller.finish(imported: true)
                }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        controller.dismissed()
                    }
                }
            }
        }
    }
}
