//
//  SharingDiagnostics.swift
//  AirBridge
//
//  Diagnostic « pourquoi mon transfert ne part-il pas ? ».
//
//  Un partage AirBridge repose sur une chaîne d'étapes (autorisation
//  réseau local → Bonjour → TCP → handshake ECDH → pairage → annonce →
//  acceptation → chunks). Une seule étape manquante suffit à bloquer un
//  transfert sur « En attente » ou « Préparation », et la cause n'était
//  visible que dans Console.app.
//
//  Ce fichier découpe le diagnostic en deux parties :
//    - `SharingDiagnosticsBuilder` : fonction **pure** qui transforme un
//      `DiagnosticsInput` (valeurs simples) en liste de lignes
//      affichables. Testable sans réseau ni appareil.
//    - `DiagnosticsInput.make(...)` : collecte l'état réel depuis le Core,
//      `BonjourService`, `ConnectionManager`, `PairingStore` et le bundle.
//

import Foundation
import Network
import OSLog

/// Plateforme exécutée : c'est elle qui décide quel canal alimente le menu
/// Partager (extension `share-services` du Finder sur macOS, feuille de
/// partage système sur iOS).
///
/// `nonisolated` : valeur pure, injectée par les tests pour couvrir les
/// deux plateformes sans compilation conditionnelle.
nonisolated enum DiagnosticPlatform: String, Sendable, Equatable {
    case macOS
    case iOS
    case other
}

/// Entrée du constructeur de diagnostic : uniquement des valeurs simples,
/// afin que la logique d'affichage soit testable sans réseau.
nonisolated struct DiagnosticsInput: Equatable, Sendable {

    // Réseau
    let platform: DiagnosticPlatform
    let isPathSatisfied: Bool
    let isPathExpensive: Bool
    let pathSupportsDNS: Bool
    let interfaceNames: [String]

    // Autorisation « Réseau local » + Bonjour
    let isLocalNetworkAuthorizationDenied: Bool
    let isAdvertisingReady: Bool
    let isBrowsingReady: Bool
    let bonjourIssue: String?
    let discoveredPeerCount: Int

    // Session
    let peerName: String?
    let sessionStateDescription: String
    let isSessionReady: Bool
    let isSecureSessionReady: Bool

    // Pairage du pair connecté
    let isPeerRecorded: Bool
    let peerTrustState: TrustState

    // Contrôle écarté à la réception (cause directe d'un « En attente »)
    let lastReceptionRejection: ReceptionRejection?

    // Partage depuis le menu système
    let embeddedPluginNames: [String]
    let isAppGroupContainerAvailable: Bool
}

/// Une ligne de diagnostic affichable.
nonisolated struct DiagnosticItem: Identifiable, Equatable, Sendable {

    enum Status: String, Sendable, Equatable {
        /// Rien à signaler.
        case ok
        /// Fonctionne, mais un point mérite attention.
        case warning
        /// Bloquant pour le partage.
        case failure
        /// Non mesurable depuis l'app : consignes de vérification.
        case unchecked
    }

    let id: String
    let title: String
    let detail: String
    let status: Status

    /// Action concrète à effectuer, `nil` quand rien n'est à faire.
    let remediation: String?

    init(
        id: String,
        title: String,
        detail: String,
        status: Status,
        remediation: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.remediation = remediation
    }
}

/// Constructeur pur des lignes de diagnostic.
///
/// L'ordre est celui de la chaîne de partage : réseau → autorisation →
/// découverte → session → pairage → contrôle écarté → menu Partager.
/// Lire le panneau de haut en bas revient donc à suivre le parcours réel
/// d'un fichier.
nonisolated enum SharingDiagnosticsBuilder {

    /// Nom de l'extension embarquée attendue pour alimenter le menu
    /// Partager de la plateforme.
    static func expectedShareExtensionName(
        on platform: DiagnosticPlatform
    ) -> String {
        switch platform {
        case .macOS:
            // Extension `com.apple.share-services` du Finder.
            return "FinderService.appex"
        case .iOS:
            return "ShareExtension.appex"
        case .other:
            return "ShareExtension.appex"
        }
    }

    static func items(
        from input: DiagnosticsInput
    ) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        items.append(networkItem(input))
        items.append(localNetworkPermissionItem(input))
        items.append(discoveryItem(input))
        items.append(sessionItem(input))
        items.append(pairingItem(input))

        if let rejection = input.lastReceptionRejection {
            items.append(receptionRejectionItem(rejection))
        }

        items.append(firewallItem(input))
        items.append(shareMenuItem(input))

        return items
    }

    /// Nombre de lignes bloquantes — utilisé pour le résumé en tête de
    /// panneau (« 2 points bloquants »).
    static func blockingCount(
        in items: [DiagnosticItem]
    ) -> Int {
        items.filter { $0.status == .failure }.count
    }

    // MARK: - Lignes

    private static func networkItem(
        _ input: DiagnosticsInput
    ) -> DiagnosticItem {
        let interfaces = input.interfaceNames.isEmpty
            ? "aucune interface"
            : input.interfaceNames.joined(separator: ", ")

        guard input.isPathSatisfied else {
            return DiagnosticItem(
                id: "network",
                title: "Connexion réseau",
                detail: "Aucun chemin réseau disponible (\(interfaces)).",
                status: .failure,
                remediation: "Connectez le Mac et l’iPhone au même Wi-Fi "
                    + "(ou activez le Bluetooth pour le pair-à-pair), puis "
                    + "relancez AirBridge."
            )
        }

        // Un chemin « coûteux » n'empêche pas AirBridge (les données
        // passent en pair-à-pair Wi-Fi / LAN), mais il trahit souvent un
        // partage de connexion : dans ce cas le Mac et l'iPhone ne sont
        // plus sur le même réseau local et la découverte échoue.
        if input.isPathExpensive {
            return DiagnosticItem(
                id: "network",
                title: "Connexion réseau",
                detail: "Chemin réseau actif mais coûteux (\(interfaces)) : "
                    + "partage de connexion ou cellulaire.",
                status: .warning,
                remediation: "Désactivez le partage de connexion / le "
                    + "cellulaire et placez les deux appareils sur le même "
                    + "Wi-Fi."
            )
        }

        guard input.pathSupportsDNS else {
            return DiagnosticItem(
                id: "network",
                title: "Connexion réseau",
                detail: "Le chemin réseau actif ne résout pas le DNS (\(interfaces)) : "
                    + "la découverte Bonjour mDNS peut échouer.",
                status: .warning,
                remediation: "Vérifiez le Wi-Fi utilisé (réseau invité, VPN "
                    + "ou proxy en cours)."
            )
        }

        return DiagnosticItem(
            id: "network",
            title: "Connexion réseau",
            detail: "Chemin réseau disponible via \(interfaces).",
            status: .ok
        )
    }

    private static func localNetworkPermissionItem(
        _ input: DiagnosticsInput
    ) -> DiagnosticItem {
        if input.isLocalNetworkAuthorizationDenied {
            let destination: String
            switch input.platform {
            case .macOS:
                destination = "Réglages Système → Confidentialité et sécurité "
                    + "→ Réseau local → activez AirBridge."
            case .iOS:
                // L'interrupteur existe aussi sur la page de
                // l'application (Réglages → AirBridge → Réseau local) :
                // c'est le chemin le plus court, mentionné en premier.
                destination = "Réglages → AirBridge → Réseau local → "
                    + "activez l’accès (liste complète : Réglages → "
                    + "Confidentialité et sécurité → Réseau local). Si "
                    + "l’interrupteur n’apparaît pas, désinstallez puis "
                    + "réinstallez l’application : iOS ne le crée qu’après "
                    + "une première demande."
            case .other:
                destination = "Autorisez l’accès au réseau local pour AirBridge."
            }

            return DiagnosticItem(
                id: "local-network-permission",
                title: "Autorisation « Réseau local »",
                detail: "Refusée : ni la découverte ni la réception ne "
                    + "fonctionnent, un transfert reste bloqué.",
                status: .failure,
                remediation: destination
            )
        }

        if let issue = input.bonjourIssue {
            return DiagnosticItem(
                id: "local-network-permission",
                title: "Autorisation « Réseau local »",
                detail: issue,
                status: .warning,
                remediation: "Vérifiez l’autorisation « Réseau local » puis "
                    + "relancez AirBridge."
            )
        }

        return DiagnosticItem(
            id: "local-network-permission",
            title: "Autorisation « Réseau local »",
            detail: "Aucun refus d’autorisation signalé par le système.",
            status: .ok
        )
    }

    private static func discoveryItem(
        _ input: DiagnosticsInput
    ) -> DiagnosticItem {
        let publishing = input.isAdvertisingReady
            ? "publication active"
            : "publication inactive"
        let browsing = input.isBrowsingReady
            ? "recherche active"
            : "recherche inactive"
        let peers = input.discoveredPeerCount == 1
            ? "1 appareil découvert"
            : "\(input.discoveredPeerCount) appareils découverts"

        if !input.isBrowsingReady || !input.isAdvertisingReady {
            return DiagnosticItem(
                id: "discovery",
                title: "Découverte Bonjour (_airbridge._tcp)",
                detail: "\(publishing), \(browsing), \(peers).",
                status: .failure,
                remediation: input.isAdvertisingReady
                    ? "Relancez la recherche (écran Radar) ; si rien "
                        + "n’apparaît, vérifiez le routeur (isolation des "
                        + "clients / AP isolation désactivée, mDNS autorisé)."
                    : "Redémarrez AirBridge : l’écoute des connexions "
                        + "entrantes n’est pas établie, la réception est "
                        + "impossible."
            )
        }

        if input.discoveredPeerCount == 0 {
            return DiagnosticItem(
                id: "discovery",
                title: "Découverte Bonjour (_airbridge._tcp)",
                detail: "\(publishing), \(browsing), aucun appareil visible.",
                status: .warning,
                remediation: "Ouvrez AirBridge sur l’autre appareil et "
                    + "vérifiez qu’il est sur le même Wi-Fi (ou à portée "
                    + "Bluetooth pour le pair-à-pair)."
            )
        }

        return DiagnosticItem(
            id: "discovery",
            title: "Découverte Bonjour (_airbridge._tcp)",
            detail: "\(publishing), \(browsing), \(peers).",
            status: .ok
        )
    }

    private static func sessionItem(
        _ input: DiagnosticsInput
    ) -> DiagnosticItem {
        guard let peerName = input.peerName else {
            return DiagnosticItem(
                id: "session",
                title: "Session avec le destinataire",
                detail: "Aucun appareil connecté (\(input.sessionStateDescription)).",
                status: .warning,
                remediation: "Sélectionnez le destinataire dans le radar pour "
                    + "établir la session avant d’envoyer."
            )
        }

        guard input.isSecureSessionReady else {
            let detail = input.isSessionReady
                ? "Connecté à \(peerName), mais la session sécurisée (ECDH) "
                    + "n’est pas établie : aucune annonce de transfert ne peut partir."
                : "Connexion à \(peerName) non prête (\(input.sessionStateDescription))."

            return DiagnosticItem(
                id: "session",
                title: "Session avec le destinataire",
                detail: detail,
                status: .failure,
                remediation: "Fermez puis rouvrez la connexion avec "
                    + "\(peerName) (radar). Si l’échec persiste, redémarrez "
                    + "AirBridge sur les deux appareils."
            )
        }

        return DiagnosticItem(
            id: "session",
            title: "Session avec le destinataire",
            detail: "Connecté à \(peerName), session sécurisée prête "
                + "(échange de clés terminé).",
            status: .ok
        )
    }

    private static func pairingItem(
        _ input: DiagnosticsInput
    ) -> DiagnosticItem {
        guard let peerName = input.peerName else {
            return DiagnosticItem(
                id: "pairing",
                title: "Pairage du destinataire",
                detail: "Aucun pair connecté : rien à vérifier.",
                status: .unchecked
            )
        }

        if !input.isPeerRecorded {
            return DiagnosticItem(
                id: "pairing",
                title: "Pairage du destinataire",
                detail: "\(peerName) n’est pas encore enregistré : son "
                    + "acceptation de transfert serait écartée et l’envoi "
                    + "resterait « En attente ».",
                status: .failure,
                remediation: "Relancez la connexion avec \(peerName) : "
                    + "AirBridge refait le pairage automatiquement. L’envoi "
                    + "est reporté tant que la clé n’est pas enregistrée."
            )
        }

        switch input.peerTrustState {
        case .blocked:
            return DiagnosticItem(
                id: "pairing",
                title: "Pairage du destinataire",
                detail: "\(peerName) est bloqué : tous ses messages sont refusés.",
                status: .failure,
                remediation: "Réglages → Appareils appairés → débloquez "
                    + "\(peerName) (ou oubliez-le puis réappairez)."
            )

        case .pending:
            return DiagnosticItem(
                id: "pairing",
                title: "Pairage du destinataire",
                detail: "\(peerName) est appairé mais non vérifié : chaque "
                    + "réception demande une confirmation.",
                status: .ok,
                remediation: "Pour des envois sans confirmation, faites "
                    + "confiance à l’appareil dans Réglages → Appareils appairés."
            )

        case .trusted:
            return DiagnosticItem(
                id: "pairing",
                title: "Pairage du destinataire",
                detail: "\(peerName) est de confiance : les transferts sont "
                    + "acceptés automatiquement.",
                status: .ok
            )

        case .unknown:
            return DiagnosticItem(
                id: "pairing",
                title: "Pairage du destinataire",
                detail: "\(peerName) est enregistré sans état de confiance "
                    + "connu : relancez le pairage.",
                status: .warning,
                remediation: "Réglages → Appareils appairés → oubliez "
                    + "\(peerName), puis reconnectez-vous."
            )
        }
    }

    private static func receptionRejectionItem(
        _ rejection: ReceptionRejection
    ) -> DiagnosticItem {
        let peer = rejection.peerName.map { " (pair : \($0))" } ?? ""

        return DiagnosticItem(
            id: "reception-rejection",
            title: "Dernier contrôle écarté à la réception\(peer)",
            detail: rejection.userFacingMessage,
            status: .failure,
            remediation: "C’est la cause directe d’un envoi qui reste "
                + "« En attente » alors que le destinataire a accepté."
        )
    }

    /// Le pare-feu n'est pas lisible depuis une application sandboxée :
    /// cette ligne ne prétend jamais connaître son état, elle donne les
    /// vérifications exactes à faire.
    private static func firewallItem(
        _ input: DiagnosticsInput
    ) -> DiagnosticItem {
        switch input.platform {
        case .macOS:
            let detail: String
            let status: DiagnosticItem.Status

            if input.isAdvertisingReady {
                detail = "L’écoute entrante est établie côté AirBridge : le "
                    + "pare-feu macOS ne bloque pas le port au moment de ce "
                    + "diagnostic."
                status = .ok
            } else {
                detail = "L’écoute entrante n’est pas établie : un pare-feu "
                    + "en mode « Bloquer toutes les connexions entrantes » "
                    + "produit exactement ce symptôme."
                status = .unchecked
            }

            return DiagnosticItem(
                id: "firewall",
                title: "Pare-feu macOS",
                detail: detail,
                status: status,
                remediation: "Réglages Système → Réseau → Pare-feu : "
                    + "« Bloquer toutes les connexions entrantes » doit être "
                    + "désactivé, et AirBridge autorisé en réception "
                    + "(Options…). Vérifiez aussi qu’aucun VPN ou filtre "
                    + "réseau tiers n’isole le trafic local."
            )

        case .iOS:
            return DiagnosticItem(
                id: "firewall",
                title: "Pare-feu / filtrage réseau",
                detail: "iOS n’expose pas de pare-feu applicatif. Les "
                    + "blocages viennent du réseau lui-même.",
                status: .unchecked,
                remediation: "Sur la borne Wi-Fi, désactivez l’isolation des "
                    + "clients (AP isolation) et autorisez mDNS/Bonjour. "
                    + "Évitez les réseaux invités et les VPN actifs. Sur le "
                    + "Wi-Fi utilisé, désactivez aussi « Adresse Wi-Fi "
                    + "privée » / « Limiter le suivi des adresses IP » et le "
                    + "Relais privé iCloud : les deux font échouer Bonjour "
                    + "en PolicyDenied même quand l’app est autorisée."
            )

        case .other:
            return DiagnosticItem(
                id: "firewall",
                title: "Pare-feu / filtrage réseau",
                detail: "Vérifiez qu’aucun filtrage réseau n’isole les "
                    + "appareils entre eux.",
                status: .unchecked
            )
        }
    }

    private static func shareMenuItem(
        _ input: DiagnosticsInput
    ) -> DiagnosticItem {
        let expected = expectedShareExtensionName(on: input.platform)

        guard input.embeddedPluginNames.contains(expected) else {
            return DiagnosticItem(
                id: "share-menu",
                title: "Menu Partager",
                detail: "L’extension \(expected) n’est pas embarquée dans "
                    + "l’application : AirBridge ne peut pas apparaître dans "
                    + "le menu Partager.",
                status: .failure,
                remediation: "Réinstallez l’application depuis Xcode "
                    + "(Produit → Exécuter) : l’extension est copiée dans "
                    + "PlugIns à la construction."
            )
        }

        guard input.isAppGroupContainerAvailable else {
            return DiagnosticItem(
                id: "share-menu",
                title: "Menu Partager",
                detail: "L’extension \(expected) est embarquée, mais le "
                    + "conteneur partagé (\(PendingShareController.appGroupIdentifier)) "
                    + "est indisponible : les fichiers partagés ne peuvent "
                    + "pas être remis à l’application. Le journal système "
                    + "« client is not entitled » confirme ce cas.",
                status: .failure,
                remediation: "Le profil de provisionnement ne porte pas la "
                    + "capacité App Groups : activez-la sur l’App ID puis "
                    + "dans Signing & Capabilities des cibles AirBridge et "
                    + "\(expected) (compte développeur payant — les comptes "
                    + "gratuits n’y ont pas droit), et réinstallez. Les "
                    + "transferts entre deux AirBridge restent possibles : "
                    + "seul le passage par le menu Partager est indisponible."
            )
        }

        let instructions: String
        switch input.platform {
        case .macOS:
            instructions = "Finder → sélectionnez le fichier → bouton "
                + "Partager (ou clic droit → Partager) → AirBridge. "
                + "Si l’entrée manque : Réglages Système → Général → "
                + "Connexion et extensions → Extensions → ajoutez/activez "
                + "AirBridge, puis relancez le Finder."
        case .iOS:
            instructions = "Fichiers/Photos → Partager → AirBridge. "
                + "Si l’entrée manque : Partager → Plus (…) → Modifier → "
                + "activez AirBridge et placez-le en favori. L’extension "
                + "prépare le lot puis l’application l’affiche dans sa "
                + "feuille d’envoi."
        case .other:
            instructions = "Utilisez le menu Partager du système et "
                + "sélectionnez AirBridge."
        }

        return DiagnosticItem(
            id: "share-menu",
            title: "Menu Partager",
            detail: "Extension \(expected) embarquée et conteneur partagé "
                + "accessible. \(instructions)",
            status: .ok
        )
    }
}
