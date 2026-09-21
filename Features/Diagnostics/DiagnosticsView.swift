//
//  DiagnosticsView.swift
//  AirBridge
//
//  Panneau « Diagnostic du partage » : réseau, autorisations, découverte,
//  session sécurisée, pairage, pare-feu et menu Partager.
//

import SwiftUI

/// Section de diagnostic, à insérer dans un `Form` (Réglages).
///
/// Chaque ligne suit la chaîne réelle d'un partage : si un transfert reste
/// « En attente » ou « Préparation », la première ligne en échec en donne la
/// cause et l'action à effectuer. La vue ne calcule rien elle-même : elle
/// lit l'état du Core et le met en forme via `SharingDiagnosticsBuilder`.
struct DiagnosticsView: View {

    let core: AirBridgeCore

    @State private var pathMonitor = LocalNetworkPathMonitor()

    var body: some View {
        Section {
            ForEach(items) { item in
                DiagnosticRow(item: item)
            }
        } header: {
            Text("Diagnostic du partage")
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            pathMonitor.start()
        }
        .onDisappear {
            pathMonitor.stop()
        }
    }

    private var items: [DiagnosticItem] {
        SharingDiagnosticsBuilder.items(
            from: DiagnosticsCollector.input(
                core: core,
                path: pathMonitor.snapshot
            )
        )
    }

    private var footerText: String {
        let blocking = SharingDiagnosticsBuilder.blockingCount(in: items)

        guard blocking > 0 else {
            return "Aucun point bloquant détecté. Si un transfert reste "
                + "« En attente », annulez-le puis relancez-le : le "
                + "diagnostic est réévalué à chaque affichage."
        }

        return blocking == 1
            ? "1 point bloquant détecté : corrigez-le puis relancez le transfert."
            : "\(blocking) points bloquants détectés : corrigez-les puis relancez le transfert."
    }
}

/// Ligne de diagnostic : titre, état, détail et action à effectuer.
private struct DiagnosticRow: View {

    let item: DiagnosticItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbolName)
                    .foregroundStyle(statusColor)

                Text(item.title)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 0)
            }

            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let remediation = item.remediation {
                Text("À faire : \(remediation)")
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch item.status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .unchecked: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .ok: return .green
        case .warning: return .orange
        case .failure: return .red
        case .unchecked: return .secondary
        }
    }
}
