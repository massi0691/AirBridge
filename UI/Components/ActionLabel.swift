//
//  ActionLabel.swift
//  AirBridge
//

import Foundation

/// Place disponible pour un intitulé d'action.
///
/// Le choix ne dépend pas de la plateforme mais de la largeur : un iPhone en
/// portrait est à l'étroit, un iPad ou une fenêtre macOS ne le sont pas.
/// Raisonner en largeur plutôt qu'en système couvre donc aussi l'iPad et une
/// fenêtre partagée, que `#if os(iOS)` seul confondrait avec un iPhone.
/// Conformance `Equatable` (synthétisée : enum sans valeur
/// associée) — requise par les comparaisons
/// `actionLabelWidth == .compact` de `DiscoveryView` ; sans elle
/// elles ne compilent pas.
enum ActionLabelWidth: Sendable, Equatable {

    /// Une seule ligne étroite : les intitulés doivent tenir en un mot.
    case compact

    /// La place ne manque pas : l'intitulé complet est plus explicite.
    case full
}

/// Actions principales de l'écran « Appareils », intitulés compris.
///
/// Les deux versions de chaque intitulé vivent ici plutôt que dans la vue :
/// c'est ce qui rend le choix vérifiable sans hôte graphique.
enum ActionLabel: CaseIterable, Sendable {

    case file
    case folder
    case disconnect

    /// L'icône ne change pas avec la largeur : elle porte le sens quand
    /// l'intitulé est réduit, donc elle est présente sur les deux
    /// plateformes.
    var systemImage: String {

        switch self {
        case .file: "doc.badge.plus"
        case .folder: "folder.badge.plus"
        case .disconnect: "xmark.circle"
        }
    }

    func title(
        _ width: ActionLabelWidth
    ) -> String {

        switch (self, width) {

        case (.file, .compact): "Fichier"
        case (.file, .full): "Choisir un fichier"

        case (.folder, .compact): "Dossier"
        case (.folder, .full): "Choisir un dossier"

        case (.disconnect, .compact): "Déco"
        case (.disconnect, .full): "Déconnecter"
        }
    }
}

/// Dimensions minimales d'une cible tactile.
enum ActionLabelMetrics {

    /// 44 points, seuil en deçà duquel un bouton devient difficile à
    /// atteindre au doigt.
    static let minimumTapTarget: CGFloat = 44
}
