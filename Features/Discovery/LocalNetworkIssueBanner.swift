//
//  LocalNetworkIssueBanner.swift
//  AirBridge
//
//  Bandeau « pourquoi le radar reste vide ».
//
//  Sans ce bandeau, un refus d'accès au réseau local (iOS 14+ :
//  `PolicyDenied(-65570)`) se traduisait par une recherche qui tourne
//  indéfiniment : ni la découverte ni la publication ne fonctionnent,
//  et l'utilisateur n'a aucun moyen de savoir que l'origine est une
//  autorisation système — ni où l'activer.
//
//  Le message vient de `BonjourService.localNetworkIssue` (construit
//  côté service, donc identique sur tous les écrans) ; le bandeau
//  n'ajoute que les deux actions possibles : ouvrir le bon réglage
//  selon la plateforme, et relancer la pile Bonjour.
//

import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct LocalNetworkIssueBanner: View {

    /// Explication de l'incident, fournie par `BonjourService`.
    let message: String

    /// Relance complète de la pile Bonjour (navigateur + écouteur).
    let onRestart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AirBridgeDesign.Spacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(AirBridgeDesign.Color.warning)

            VStack(
                alignment: .leading,
                spacing: AirBridgeDesign.Spacing.xs
            ) {
                Text("Accès au réseau local requis")
                    .font(AirBridgeDesign.Typography.subheadline)
                    .fontWeight(.semibold)

                Text(message)
                    .font(AirBridgeDesign.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: AirBridgeDesign.Spacing.sm) {
                    Button("Ouvrir les Réglages") {
                        Self.openLocalNetworkSettings()
                    }
                    Button("Relancer la recherche") {
                        onRestart()
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .padding(AirBridgeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium,
                style: .continuous
            )
            .fill(AirBridgeDesign.Color.warning.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: AirBridgeDesign.Radius.medium,
                style: .continuous
            )
            .strokeBorder(
                AirBridgeDesign.Color.warning.opacity(0.35),
                lineWidth: 1
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("localNetworkIssueBanner")
    }

    /// Ouvre le réglage « Réseau local » : page de l'application dans
    /// Réglages sur iOS (l'interrupteur y figure dès la première
    /// demande), volet Confidentialité des Réglages Système sur macOS.
    @MainActor
    static func openLocalNetworkSettings() {
        #if os(macOS)
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate),
               NSWorkspace.shared.open(url) {
                return
            }
        }
        #elseif canImport(UIKit)
        // `UIApplication.openSettingsURLString` ouvre la page de
        // l'application, qui porte l'interrupteur « Réseau local ». Les
        // schémas `App-Prefs:` (non publics) sont délibérément évités :
        // ils font rejeter l'application à la validation.
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

#Preview {
    LocalNetworkIssueBanner(
        message: "La recherche d'appareils est bloquée : PolicyDenied. "
            + "Vérifiez que « Réseau local » est autorisé pour AirBridge "
            + "(Réglages → AirBridge → Réseau local)."
    ) { }
    .padding()
}
