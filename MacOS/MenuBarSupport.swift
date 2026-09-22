//
//  MenuBarSupport.swift
//  AirBridge
//
//  Résidence en arrière-plan macOS (barre des menus) :
//   - `MacBackgroundActivity` : assertion d'activité qui empêche App Nap
//     de throtler Bonjour / les sockets tant que l'app vit en arrière-
//     plan sans fenêtre (sinon découverte et transferts ralentissent
//     dès que l'app n'est plus au premier plan) ;
//   - `MacMenuBarContentView` : contenu du `MenuBarExtra` (état de
//     connexion, ouverture, envoi rapide, quitter) ;
//   - notifications de coordination fenêtre ↔ menu.
//
//  Fichier compilé uniquement sur macOS (dossier `MacOS/`, guard
//  plateforme) et rattaché à la cible principale via le groupe
//  synchronisé `MacOS`.
//

#if os(macOS)

import AppKit
import SwiftUI

// MARK: - Notifications de coordination

extension Notification.Name {
    /// Demande d'ouverture de la fenêtre principale (depuis le menu).
    static let airbridgeShowWorkspace = Notification.Name(
        "airbridgeShowWorkspace"
    )

    /// Demande d'ouverture de la fenêtre + sélecteur de fichiers
    /// (« Envoyer un fichier… » du menu).
    static let airbridgeQuickSend = Notification.Name(
        "airbridgeQuickSend"
    )
}

// MARK: - Assertion d'activité (anti App Nap)

/// Tient une assertion `ProcessInfo` tant que la résidence en barre des
/// menus est active. Sans elle, macOS met l'app en veille active quand
/// aucune fenêtre n'est visible : les mises à jour Bonjour ralentissent
/// (« l'iPhone n'est plus détecté ») et les relances de connexion
/// deviennent tardives.
final class MacBackgroundActivity {

    /// Token d'assertion — `nil` quand aucune activité n'est tenue.
    private var token: NSObjectProtocol?

    /// Démarre l'assertion (idempotent).
    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [
                // Travail utilisateur en arrière-plan : coupe l'App Nap
                // (qui throtlerait Bonjour) tout en autorisant la veille
                // idle du système.
                .userInitiatedAllowingIdleSystemSleep,
                // L'app ne doit jamais s'autoriser ni se tuer toute
                // seule pendant une résidence en barre des menus.
                .automaticTerminationDisabled,
                .suddenTerminationDisabled
            ],
            reason: "AirBridge résident dans la barre des menus (découverte Bonjour active)"
        )
    }

    /// Relâche l'assertion (idempotent).
    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit {
        end()
    }
}

// MARK: - Contenu du MenuBarExtra

/// Contenu du menu de la barre des menus.
///
/// Style `.menu` : uniquement des éléments de menu (Text/Button/
/// Divider). Le Core peut ne pas encore exister au premier rendu —
/// l'état affiché dégrade proprement vers « Initialisation… ».
struct MacMenuBarContentView: View {

    /// Accès paresseux au Core (dépend de l'initialisation du
    /// `CoreHolder` de l'app — peut être `nil` au démarrage).
    let coreProvider: () -> AirBridgeCore?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let core = coreProvider()

        Button {
            openWorkspace()
        } label: {
            Text(statusLine(for: core))
        }
        .disabled(true)

        Divider()

        Button("Ouvrir AirBridge") {
            openWorkspace()
        }

        Button("Envoyer un fichier…") {
            NotificationCenter.default.post(
                name: .airbridgeQuickSend,
                object: nil
            )
            openWorkspace()
        }
        .disabled(core?.connectionManager.connectedDevice == nil)

        Divider()

        Button("Quitter AirBridge") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Ligne d'état : pair connecté (session sécurisée), sinon la
    /// description Core, sinon initialisation.
    private func statusLine(for core: AirBridgeCore?) -> String {
        guard let core else {
            return "Initialisation…"
        }
        if let device = core.connectionManager.connectedDevice {
            let suffix = core.connectionManager.isSecureSessionReady
                ? " — sécurisée"
                : ""
            return "Connecté à \(device.name)\(suffix)"
        }
        let discoveredCount = core.bonjourService.discoveredDevices.count
        if discoveredCount > 0 {
            return "\(discoveredCount) appareil(s) à proximité"
        }
        return "Non connecté"
    }

    /// Révèle la fenêtre principale (recrée la scène `workspace` si
    /// toutes les fenêtres sont fermées — l'app reste résidente).
    private func openWorkspace() {
        NSApp.activate()
        NotificationCenter.default.post(
            name: .airbridgeShowWorkspace,
            object: nil
        )
        openWindow(id: "workspace")
    }
}

#endif
