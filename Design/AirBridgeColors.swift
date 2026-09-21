//
//  AirBridgeColors.swift
//  AirBridge
//
//  Color tokens for AirBridge. All colors are system-driven so Light / Dark /
//  Increase Contrast modes are honoured automatically.
//

import SwiftUI

/// Color tokens used across the AirBridge UI.
///
/// Each color maps to a system semantic color so Light, Dark, and Increase
/// Contrast modes are honoured without us having to redefine palettes. We
/// avoid baking hex values in — they would break the system color contract
/// and force us to maintain a parallel palette.
extension AirBridgeDesign {

    enum Color {

        /// Primary action accent. Resolves to the user's chosen accent
        /// color in system settings.
        static let accent: SwiftUI.Color = .accentColor

        /// Foreground used for primary text and high-emphasis content.
        static let primaryText: SwiftUI.Color = .primary

        /// Foreground for secondary text (timestamps, captions).
        static let secondaryText: SwiftUI.Color = .secondary

        /// Status colors. All four are system-provided for proper
        /// Light/Dark adaptation and accessibility.
        static let success: SwiftUI.Color = .green
        static let warning: SwiftUI.Color = .orange
        static let error:   SwiftUI.Color = .red
        static let info:    SwiftUI.Color = .blue
    }
}

// MARK: - Radar

/// Tokens dédiés à la surface immersive de découverte (le radar).
///
/// Le radar était auparavant **forcé en sombre** (`.preferredColorScheme(.dark)`
/// + fond `Color.black` + textes `Color.white`). Sur macOS cela produisait une
/// interface mélangée : une colonne détail noire au milieu d'une fenêtre claire
/// (barre latérale, barre d'outils et feuilles suivaient, elles, le thème
/// système).
///
/// Toutes les couleurs ci-dessous sont **sémantiques** : le radar suit donc
/// l'apparence du système — entièrement clair en thème clair, entièrement
/// sombre en thème sombre — sur toutes les plateformes, sans palette parallèle
/// ni valeur codée en dur.
extension AirBridgeDesign.Color {

    enum Radar {

        /// Fond de base de la surface radar.
        ///
        /// - macOS : `windowBackgroundColor`, la couleur native du contenu de
        ///   fenêtre. Elle garantit que le radar se fond dans le reste de la
        ///   fenêtre (barre latérale, tableau des transferts, feuilles) au lieu
        ///   d'imposer un panneau noir en thème clair.
        /// - iOS : `systemBackground` (noir en mode sombre, blanc en mode
        ///   clair), comme n'importe quel écran plein écran.
        /// - Autres plateformes : transparent, le système fournit déjà le fond
        ///   de fenêtre.
        static var base: SwiftUI.Color {
#if os(macOS)
            SwiftUI.Color(nsColor: .windowBackgroundColor)
#elseif os(iOS)
            SwiftUI.Color(uiColor: .systemBackground)
#else
            SwiftUI.Color.clear
#endif
        }

        /// Halo d'accent peint par-dessus le fond (gradient radial).
        static let halo: SwiftUI.Color = .accentColor

        /// Étoiles / particules du fond. `.primary` devient blanc en thème
        /// sombre et noir en thème clair : les particules restent visibles
        /// dans les deux cas sans jamais être codées en dur.
        static let particles: SwiftUI.Color = .primary

        /// Titre et contenu de premier plan du radar.
        static let title: SwiftUI.Color = .primary

        /// Texte de second plan (statut, explications).
        static let subtitle: SwiftUI.Color = .secondary

        /// Anneaux concentriques du cadran.
        static let rings: SwiftUI.Color = SwiftUI.Color.secondary.opacity(0.22)

        /// Opacité du halo radial selon l'apparence : plus soutenue en thème
        /// sombre (le fond noir absorbe la couleur), plus discrète en thème
        /// clair pour ne pas teinter un fond blanc.
        static func haloOpacity(
            _ colorScheme: ColorScheme
        ) -> (core: Double, edge: Double) {
            switch colorScheme {
            case .dark:
                return (core: 0.18, edge: 0.08)
            case .light:
                return (core: 0.12, edge: 0.05)
            @unknown default:
                return (core: 0.15, edge: 0.07)
            }
        }

        /// Opacité globale des particules selon l'apparence : en thème clair
        /// elles sont atténuées pour rester une texture et non du bruit.
        static func particleOpacity(
            _ colorScheme: ColorScheme
        ) -> Double {
            switch colorScheme {
            case .dark:
                return 1.0
            case .light:
                return 0.55
            @unknown default:
                return 0.8
            }
        }
    }
}
