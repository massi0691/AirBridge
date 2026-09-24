//
//  AirBridgeSharedState.swift
//  AirBridge
//
//  État partagé entre l'application principale et les extensions de
//  partage (FinderService macOS, ShareExtension iOS) via l'App Group
//  `group.com.airbridge.shared`.
//
//  Deux usages :
//   1. **Dernier appareil connecté** — l'app publie snapshots à chaque
//      session ouverte / fermée ; l'extension Finder affiche alors
//      « Envoyer à <dernier appareil> » comme action principale de son
//      menu (sans quoi l'extension, processus séparé sans socket, ne
//      peut pas connaître l'état réseau de l'app).
//   2. **Directive d'envoi ciblé** — quand l'utilisateur appuie sur
//      « Envoyer à <X> » dans l'extension, celle-ci écrit une directive
//      `AirBridgeSendDirective` à côté du lot ; l'app la consomme au
//      démarrage du traitement du lot et programme l'envoi automatique
//      dès que la session avec X est sécurisée (`AirBridgeCore
//      .scheduleTargetedSend`).
//
//  Toutes les opérations sont *best-effort* : un conteneur App Group
//  absent (tests, configuration atypique) produit un simple `nil`, jamais
//  une exception. Aucune donnée sensible (clés, empreintes) ne transite
//  par ce canal : uniquement l'identifiant, le nom et le modèle.
//

import Foundation

// MARK: - Conteneur App Group

/// Résolution du conteneur App Group, surchargeable pour les tests.
enum AirBridgeAppGroup {

    /// Identifiant de l'App Group partagé avec les extensions.
    static let identifier = "group.com.airbridge.shared"

    /// Surcharge injectée par les tests (dossier temporaire). `nil` en
    /// production : le conteneur réel du système est utilisé.
    /// `nonisolated(unsafe)` : variable de configuration, écriture
    /// unique avant toute lecture concurrente (convention des stores de
    /// test du projet).
    nonisolated(unsafe) static var containerURLOverride: URL?

    /// Résolution système mémorisée (`nil` = pas encore résolu,
    /// `.some(nil)` = résolu et indisponible).
    ///
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
    /// journalise `container_create_or_lookup_app_group_path_by_app_group_identifier:
    /// client is not entitled` **à chaque appel** quand la capacité App
    /// Groups n'est pas provisionnée (compte gratuit, App ID sans
    /// l'App Group). Le balayage des lots partagés s'exécute à chaque
    /// retour au premier plan et consultait deux fois le conteneur :
    /// le journal système était saturé de lignes identiques, au point
    /// de masquer les vrais incidents.
    nonisolated(unsafe) private static var cachedSystemContainerURL: URL??
    private static let cacheLock = NSLock()

    /// URL du conteneur partagé, ou `nil` s'il est indisponible.
    ///
    /// La résolution système n'est faite qu'une fois par processus ; la
    /// surcharge de test, elle, est toujours lue en premier (elle peut
    /// changer entre deux tests).
    static func containerURL() -> URL? {
        if let containerURLOverride {
            return containerURLOverride
        }

        cacheLock.lock()
        if let cached = cachedSystemContainerURL {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        )

        cacheLock.lock()
        cachedSystemContainerURL = resolved
        cacheLock.unlock()

        return resolved
    }

    /// Oublie la résolution mémorisée. Réservé aux tests : en
    /// production le conteneur ne change pas pendant la vie du
    /// processus.
    static func resetContainerURLCache() {
        cacheLock.lock()
        cachedSystemContainerURL = nil
        cacheLock.unlock()
    }

    /// Racine des fichiers d'état partagés (séparée de
    /// `PendingShares/` : le balayage de purge n'y touche pas).
    static func stateRoot() -> URL? {
        containerURL()?.appendingPathComponent(
            "AirBridgeShared",
            isDirectory: true
        )
    }
}

// MARK: - Snapshot d'appareil

/// Extrait minimal d'un appareil, publié pour la consommation par les
/// extensions (affichage seul — jamais pour décider d'une sécurité).
struct AirBridgeSharedPeer: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let model: String

    /// Vrai tant que la session est ouverte (l'app a publié depuis
    /// `onSessionReady` et n'a pas encore publié la déconnexion).
    /// Attention : indicatif *pour l'affichage* — la source de vérité
    /// reste le socket de l'app principale.
    let sessionOpen: Bool

    /// Horodatage de publication (permet à l'extension d'inférer une
    /// staleness grossière si l'app a planté sans publier la fermeture).
    let updatedAt: Date

    init(
        id: UUID,
        name: String,
        model: String,
        sessionOpen: Bool,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.sessionOpen = sessionOpen
        self.updatedAt = updatedAt
    }
}

// MARK: - État partagé

/// Contenu de `AirBridgeShared/state.json`.
struct AirBridgeSharedState: Codable, Equatable, Sendable {
    /// Dernier appareil avec lequel une session a existé (même déjà
    /// fermée : c'est le « dernier appareil connecté » proposé par
    /// l'extension pour un envoi rapide).
    var lastPeer: AirBridgeSharedPeer?

    /// Pair actuellement connecté, si session ouverte (raccourci pour
    /// l'UI : `lastPeer` reste renseigné après déconnexion).
    var connectedPeerID: UUID?

    init(
        lastPeer: AirBridgeSharedPeer? = nil,
        connectedPeerID: UUID? = nil
    ) {
        self.lastPeer = lastPeer
        self.connectedPeerID = connectedPeerID
    }
}

/// Lecture / écriture de `state.json` dans l'App Group.
///
/// Écriture atomique (`tmp` + `moveItem`) : une extension qui lit au
/// pire observe l'ancienne version, jamais un JSON tronqué.
enum AirBridgeSharedStateStore {

    // MARK: Fichiers

    static func stateFileURL() -> URL? {
        AirBridgeAppGroup.stateRoot()?.appendingPathComponent("state.json")
    }

    /// Lecture synchrone (léger : un fichier de quelques octets).
    static func read() -> AirBridgeSharedState? {
        guard let fileURL = stateFileURL(),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(
            AirBridgeSharedState.self,
            from: data
        )
    }

    /// Écriture atomique. Échec silencieux si le conteneur est
    /// indisponible — l'état partagé est un confort d'UX, pas un
    /// invariant de sécurité.
    @discardableResult
    static func write(_ state: AirBridgeSharedState) -> Bool {
        guard let root = AirBridgeAppGroup.stateRoot() else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            let tmp = root.appendingPathComponent(
                "state.json.tmp"
            )
            try data.write(to: tmp, options: .atomic)
            let destination = root.appendingPathComponent(
                "state.json"
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(
                at: tmp,
                to: destination
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: Publications de l'application principale

    /// Session ouverte avec `peerID` : publie l'appareil comme dernier
    /// connecté ET marque la session ouverte.
    ///
    /// Paramètres nommés (et non un `Device`) : ce fichier est aussi
    /// compilé dans les extensions, qui ne connaissent PAS le type
    /// `Device` de la cible principale.
    static func publishSessionOpened(
        peerID: UUID,
        name: String,
        model: String
    ) {
        var state = read() ?? AirBridgeSharedState()
        state.lastPeer = AirBridgeSharedPeer(
            id: peerID,
            name: name,
            model: model,
            sessionOpen: true
        )
        state.connectedPeerID = peerID
        write(state)
    }

    /// Session fermée : le dernier pair reste proposé (« dernier
    /// appareil connecté »), mais la session est marquée fermée.
    static func publishSessionClosed(peerID: UUID) {
        var state = read() ?? AirBridgeSharedState()
        if let lastPeer = state.lastPeer, lastPeer.id == peerID {
            state.lastPeer = AirBridgeSharedPeer(
                id: lastPeer.id,
                name: lastPeer.name,
                model: lastPeer.model,
                sessionOpen: false
            )
        }
        if state.connectedPeerID == peerID {
            state.connectedPeerID = nil
        }
        write(state)
    }
}

// MARK: - Directive d'envoi ciblé

/// Écrit par l'extension Finder (« Envoyer à <X> ») à côté d'un lot ;
/// consommée par l'app principale quand elle traite ce lot.
struct AirBridgeSendDirective: Codable, Equatable, Sendable, Identifiable {
    /// Identifiant du lot (`PendingShares/<batchID>`).
    let batchID: String
    /// Pair destinataire — l'app ne l'envoie que si la session réelle
    /// correspond (vérification côté app, jamais cru en l'extension).
    let targetPeerID: UUID
    /// Nom affiché (affichage seul).
    let targetPeerName: String
    let createdAt: Date

    var id: String { batchID }
}

/// Persistance des directives dans
/// `AirBridgeShared/SendDirectives/<batchID>.json`.
enum AirBridgeSendDirectiveStore {

    static func directivesRoot() -> URL? {
        AirBridgeAppGroup.stateRoot()?.appendingPathComponent(
            "SendDirectives",
            isDirectory: true
        )
    }

    static func fileURL(batchID: String) -> URL? {
        directivesRoot()?.appendingPathComponent(
            "\(batchID).json"
        )
    }

    /// Écrit la directive d'un lot (remplace une directive antérieure
    /// du même lot). `false` si le conteneur est indisponible.
    @discardableResult
    static func write(_ directive: AirBridgeSendDirective) -> Bool {
        guard let root = directivesRoot() else { return false }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(directive)
            guard let destination = fileURL(
                batchID: directive.batchID
            ) else { return false }
            let tmp = destination.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// Directive d'un lot, sans la consommer.
    static func read(batchID: String) -> AirBridgeSendDirective? {
        guard let url = fileURL(batchID: batchID),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(
            AirBridgeSendDirective.self,
            from: data
        )
    }

    /// Lit puis supprime la directive du lot (consommation unique :
    /// un lot ne doit jamais déclencher deux envois ciblés).
    static func consume(batchID: String) -> AirBridgeSendDirective? {
        guard let directive = read(batchID: batchID) else {
            return nil
        }
        if let url = fileURL(batchID: batchID) {
            try? FileManager.default.removeItem(at: url)
        }
        return directive
    }

    /// Supprime toute directive résiduelle (nettoyage opportuniste).
    static func removeAll() {
        guard let root = directivesRoot() else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
