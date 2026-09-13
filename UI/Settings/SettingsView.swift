//
//  SettingsView.swift
//  AirBridge
//
//  Created by massi9106 on 26/07/2026.
//

import SwiftUI
import UserNotifications
import OSLog
#if os(macOS)
import AppKit
#endif
internal import UniformTypeIdentifiers

/// Réglages de l'application.
///
/// La vue est une section, pas une feuille : elle n'embarque donc ni pile
/// de navigation, ni bouton « Fermer », ni taille imposée. C'est l'écran
/// qui l'accueille (onglet sur iPhone, colonne de détail sur macOS) qui
/// fournit ce cadre.
struct SettingsView: View {

    let receivedFolderStore: ReceivedFolderStore
    let notificationManager: NotificationManager
    let pairingStore: PairingStore

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "ui.settings"
    )

    @State private var isFolderImporterPresented = false
    @State private var pairings: [PairingInfo] = []

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true

    var body: some View {
        Form {
            Section("Dossier de réception") {
                if let directory = receivedFolderStore.selectedDirectory {
                    Text(directory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                } else {
                    Text("Aucun dossier sélectionné")
                        .foregroundStyle(.secondary)
                }

                Button("Choisir le dossier") {
                    isFolderImporterPresented = true
                }

                if receivedFolderStore.selectedDirectory != nil {
                    Button(
                        "Oublier ce dossier",
                        role: .destructive
                    ) {
                        receivedFolderStore.clearDirectory()
                    }
                }
            }

            Section("Notifications") {
                Toggle("Activer les notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { oldValue, newValue in
                        Task { @MainActor in
                            if newValue && !notificationManager.areNotificationsEnabled {
                                _ = await notificationManager.requestAuthorization()
                            } else if !newValue {
                                notificationManager.refreshAuthorizationStatus()
                            }
                        }
                    }
                    .onChange(of: notificationManager.areNotificationsEnabled) { _, _ in
                        // Force UI refresh when authorization status changes
                    }

                HStack {
                    Text("Statut")
                    Spacer()
                    Text(authorizationStatusText)
                        .foregroundStyle(.secondary)
                }

                #if os(macOS)
                if notificationManager.isAuthorizationDenied {
                    Text("Notifications refusées. Activez-les dans Réglages Système → Notifications → AirBridge.")
                        .font(.caption)
                        .foregroundStyle(.red)

                    Button("Ouvrir Réglages système") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                #endif
            }

            Section("Appareils appairés") {
                if pairings.isEmpty {
                    Text("Aucun appareil appairé pour le moment")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairings, id: \.peerID) { pairing in
                        PairedDeviceRow(
                            pairing: pairing,
                            onAction: { action in
                                handlePairingAction(action, for: pairing.peerID)
                            }
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Réglages")
        .onAppear(perform: loadInitialPairings)
        .onChange(of: scenePhase) { _, newPhase in
            // Recharge la liste des pairages quand la scène redevient active
            // afin de refléter les nouveaux appairages effectués depuis un
            // autre écran.
            if newPhase == .active {
                loadInitialPairings()
            }
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleSelectedFolder
        )
    }

    private var authorizationStatusText: String {
        switch notificationManager.authorizationStatus {
        case .authorized:
            return "Autorisé"
        case .denied:
            return "Refusé (ouvrir Réglages)"
        case .notDetermined:
            return "Non déterminé"
        case .provisional:
            return "Provisoire"
        case .ephemeral:
            return "Éphémère"
        @unknown default:
            return "Inconnu"
        }
    }

    private func handleSelectedFolder(
        _ result: Result<[URL], Error>
    ) {
        switch result {
        case .success(let urls):
            guard let folderURL = urls.first else {
                return
            }
            receivedFolderStore.selectDirectory(folderURL)
        case .failure(let error):
            logger.error("Sélection du dossier impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handlePairingAction(
        _ action: PairingAction,
        for peerID: UUID
    ) {
        switch action {
        case .trust:
            pairingStore.setTrustState(.trusted, for: peerID)
        case .block:
            pairingStore.setTrustState(.blocked, for: peerID)
        case .remove:
            pairingStore.removePairing(for: peerID)
        }
        refreshPairings()
    }

    private func refreshPairings() {
        pairings = Array(pairingStore.loadAll().values).sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    private func loadInitialPairings() {
        pairings = Array(pairingStore.loadAll().values).sorted { $0.lastSeenAt > $1.lastSeenAt }
    }
}

/// Actions possibles sur un appareil appairé.
enum PairingAction {
    case trust
    case block
    case remove
}

/// Ligne pour un appareil appairé dans les réglages.
struct PairedDeviceRow: View {
    let pairing: PairingInfo
    let onAction: (PairingAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(pairing.peerName)
                        .font(.headline)
                    Text("Empreinte: \(pairing.peerFingerprint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trustStateBadge
            }

            HStack {
                ForEach(availableActions, id: \.self) { action in
                    Button(action.rawValue) {
                        onAction(action)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trustStateBadge: some View {
        switch pairing.trustState {
        case .trusted:
            Label("De confiance", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
        case .pending:
            Label("En attente", systemImage: "clock.fill")
                .foregroundStyle(.orange)
        case .blocked:
            Label("Bloqué", systemImage: "xmark.shield.fill")
                .foregroundStyle(.red)
        case .unknown:
            Label("Inconnu", systemImage: "questionmark.shield.fill")
                .foregroundStyle(.gray)
        }
    }

    private var availableActions: [PairingAction] {
        switch pairing.trustState {
        case .trusted:
            return [.block, .remove]
        case .pending:
            return [.trust, .block, .remove]
        case .blocked:
            return [.trust, .remove]
        case .unknown:
            return [.remove]
        }
    }
}

extension PairingAction: RawRepresentable {
    typealias RawValue = String

    init?(rawValue: String) {
        switch rawValue {
        case "Faire confiance": self = .trust
        case "Bloquer": self = .block
        case "Oublier": self = .remove
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .trust: return "Faire confiance"
        case .block: return "Bloquer"
        case .remove: return "Oublier"
        }
    }
}
