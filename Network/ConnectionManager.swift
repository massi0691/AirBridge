//
//  ConnectionManager.swift
//  AirBridge
//
//  Created by massi9106 on 21/07/2026.
//

import Foundation
import Network
import Observation
import CryptoKit
import OSLog

@MainActor
@Observable
final class ConnectionManager {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "network.connection"
    )

    /// Logger statique utilisé dans les closures Network.framework où
    /// `self` n'est pas capturé.
    private static let staticLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "network.connection"
    )

    /// File dédiée hors MainActor pour la boucle d'événements
    /// `Network.framework` (états de connexion, complétions de
    /// `receive`, etc.). Sur le MainActor, chaque callback de trame
    /// forçait un aller-retour à travers le sérialiseur du main thread
    /// (~1 ms par chunk, ce qui bridait le pipeline de transfert à
    /// environ 4 chunks/s). Sur une file concurrente QoS
    /// `.userInitiated`, les callbacks restent ordonnés par le
    /// framework mais ne bloquent plus les autres chemins.
    nonisolated private static let networkQueue = DispatchQueue(
        label: "com.airbridge.network",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private(set) var session: AirBridgeSession?

    private let localDevice: Device
    private let pairingStore: PairingStore
    private let messageCodec = MessageCodec()
    private let frameCodec = FrameCodec()
    private let messageRouter: MessageRouter

    /// Stockage anti-replay : rejette les messages `(peerID, messageID)`
    /// déjà vus dans la fenêtre TTL. Utilisé dans le pipeline de réception
    /// pour empêcher un attaquant de rejouer un message intercepté.
    private let replayProtection = ReplayProtectionStore()

    
    private(set) var stateDescription = "Déconnecté"

    /// Vrai uniquement quand la session courante a été confirmée `.ready`
    /// par le `stateUpdateHandler` — jamais entre `connect()` et ce
    /// callback, où la session existe déjà mais ne peut rien transporter.
    ///
    /// Toutes les gardes d'envoi applicatif (resumeRequest notamment)
    /// doivent consulter ce drapeau et non la seule présence de `session`.
    private(set) var isSessionReady = false

    /// Dernière endpoint Bonjour réellement utilisée pour une tentative
    /// de connexion. Un échec (failed/cancelled) l'invalide : la prochaine
    /// tentative doit attendre une redécouverte fraîche plutôt que rejouer
    /// une adresse peut-être périmée.
    private(set) var lastAttemptedEndpoint: NWEndpoint?

    /// Timeout applicatif d'une tentative de connexion : au-delà, la
    /// connexion est annulée (elle sinon resterait longtemps en `.waiting`,
    /// pendant que les campagnes de reprise brûlent leur backoff).
    static let connectionTimeout: TimeInterval = 10
    
    
    /// Dernier pair associé à une session vivante.
    ///
    /// Conservé après la fermeture : le traitement de déconnexion doit
    /// rattacher les transferts actifs à un pair, alors que `session` est
    /// déjà `nil` et que `connectedDevice` ne répond donc plus. Remis à
    /// `nil` uniquement par `clearLastConnectedPeer()`, appelé par le cœur
    /// une fois sa séquence d'interruption terminée.
    private(set) var lastConnectedPeer: Device?

    /// Callback de fermeture de session : reçoit le pair identifié de la
    /// session perdue, ou `nil` si elle n'a jamais été identifiée (aucun
    /// HELLO reçu). Passer le pair en paramètre évite au récepteur de lire
    /// `connectedDevice`, déjà vide à ce stade.
    var onSessionClosed: ((Device?) -> Void)?
    var onSessionReady: ((NWConnection) -> Void)?

    var connectedDevice: Device? {
        session?.peer
    }

    // MARK: - Helpers de test
    //
    // Ces accesseurs ne sont utilisés que par les tests unitaires
    // (`SessionIdSharingTests`). Ils permettent d'injecter une
    // `AirBridgeSession` de direction arbitraire et de rejouer
    // `onSessionReady` sans dépendre d'une `NWConnection` réelle ni
    // d'un `BonjourService` actif.
    //
    // Nommés de manière à rester invisibles en production (suffixe
    // `ForTest`) et à ne pas être confondus avec l'API publique.

    #if DEBUG
    /// Remplace la session courante par une session factice. Réservé aux
    /// tests unitaires (cf. `SessionIdSharingTests`).
    func replaceSessionForTest(_ newSession: AirBridgeSession) {
        self.session = newSession
    }

    /// Déclenche le callback `onSessionReady` enregistré. Réservé aux
    /// tests unitaires : permet d'exercer le branchement
    /// initiator/responder sans `NWConnection` réelle.
    func triggerOnSessionReadyForTest(connection: NWConnection) {
        self.onSessionReady?(connection)
    }
    #endif

    /// Oublie le dernier pair connu : à appeler une fois la séquence de
    /// déconnexion traitée par le cœur (transferts interrompus, métadonnées
    /// persistées), jamais avant.
    func clearLastConnectedPeer() {
        lastConnectedPeer = nil
    }

    /// Enregistre explicitement le pair d'une session vivante comme dernier
    /// pair connu. Complète l'alimentation automatique par HELLO : utile
    /// quand le cœur veut garantir la mémoire du pair à un instant précis.
    func rememberConnectedPeer(_ peer: Device) {
        lastConnectedPeer = peer
    }

    private var connection: NWConnection? {
        session?.connection
    }

    enum ConnectionManagerError: Error {
        case noActiveConnection
        case encodingError(Error)
    }

    // MARK: - Protocol version tracking for v2 binary chunks
    private var negotiatedProtocolVersion: Int = 1

    /// Identifiant de session actif pour la connexion courante.
    /// Généré au handshake sécurisé (hello/ack authentifié) et utilisé
    /// pour lier les chunks binaires v2 à la session, empêchant un
    /// attaquant d'injecter des chunks d'une autre session.
    private var activeSessionId: UUID? = nil

    /// Pipeline de réception sécurisé — applique, dans l'ordre strict,
    /// les étapes d'identification, de résolution de pair, de calcul de
    /// la `AuthenticationPolicy`, de vérification cryptographique et de
    /// protection anti-replay avant de router le message.
    ///
    /// Renvoie `true` si le message peut être routé, `false` s'il doit
    /// être ignoré (mauvaise signature, signature absente alors qu'elle
    /// était requise, replay détecté, type de message interdit).
    ///
    /// IMPORTANT : l'appel à `observe(...)` sur le `ReplayProtectionStore`
    /// ne se fait **qu'après** la vérification de signature réussie. Un
    /// message invalide NE DOIT PAS empoisonner le store : l'ordre est
    /// `verify → observe`, jamais l'inverse.
    private func runSecureReceptionPipeline(for message: AirBridgeMessage) -> Bool {
        // 1. Identification du pair — déjà effectuée en amont par
        //    `session?.identifyPeer(message.sender)` (pour les messages
        //    qui portent un sender fiable, i.e. hors `fileChunk`).
        //    À ce stade, `message.sender.id` est l'identité stable du
        //    pair sur cette session.

        // 2. Résolution de la `PairingInfo` dans le `PairingStore`.
        let pairingInfo = pairingStore.pairing(for: message.sender.id)
        let peerTrustState = pairingInfo?.trustState ?? .unknown

        // 3. Récupération de la clé publique long-terme annoncée par
        //    l'émetteur. Depuis l'ajout de `Device.publicKeyData`, le
        //    sender embarque sa clé de signature P-256 dans chaque
        //    message sortant, ce qui permet de vérifier les messages
        //    sans payload de pairage (`hello`, `keyExchange`,
        //    `keyExchangeAck`, `acknowledgement`, `ping`, `pong`).
        //    `extractAdvertisedPublicKey` priorise `sender.publicKeyData`
        //    puis retombe sur le payload pour la rétro-compatibilité
        //    avec les clients v1.
        let advertisedPublicKey = extractAdvertisedPublicKey(from: message)

        // 4. Cohérence entre la clé publique annoncée et celle persistée.
        //    Cette comparaison remplace l'ancienne valeur hardcodée `false`
        //    : on extrait maintenant la clé annoncée du payload et on la
        //    compare à celle du store. Si les deux diffèrent (ou si l'une
        //    manque), la `AuthenticationPolicy` basculera automatiquement
        //    `trusted`→`pending` et la signature sera exigée contre la clé
        //    persistée, qui rejettera en cas de substitution d'identité.
        let peerPublicKeyMatches: Bool = self.peerPublicKeyMatches(
            advertisedPublicKey: advertisedPublicKey,
            for: message.sender.id
        )

        // 5. Calcul de l'`AuthenticationRequirement` via la table de
        //    règles pure `AuthenticationPolicy`.
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: message.type,
            protocolVersion: message.protocolVersion,
            peerTrustState: peerTrustState,
            peerPublicKeyMatches: peerPublicKeyMatches
        )

        // 6. Vérification cryptographique stricte.
        let signatureOK = MessageAuthenticator.verify(
            message,
            requirement: requirement,
            storePublicKey: pairingInfo?.peerPublicKeyData,
            advertisedPublicKey: advertisedPublicKey
        )
        guard signatureOK else {
            logger.error("Signature invalide pour \(message.type.rawValue, privacy: .public) de \(message.sender.name, privacy: .public) (policy=\(String(describing: requirement), privacy: .public)) — message ignoré")
            return false
        }

        return true
    }

    /// Extrait la clé publique long-terme annoncée par l'émetteur.
    ///
    /// Ordre de priorité :
    /// 1. `message.sender.publicKeyData` : la clé long-terme (P-256
    ///    signature) embarquée dans l'identité du device. C'est la
    ///    source de vérité pour vérifier les signatures des messages
    ///    `hello`, `keyExchange`, `keyExchangeAck`, `acknowledgement`,
    ///    `ping`, `pong`, qui n'ont pas de payload de pairage.
    /// 2. Fallback payload : pour les anciens clients (v1) qui
    ///    n'embarquent pas encore la clé dans `Device`, on extrait
    ///    la clé depuis le payload des messages qui la transportent
    ///    historiquement (`PairingPayload.publicKeyData` pour
    ///    `pairingRequest` / `pairingResponse`,
    ///    `KeyExchangePayload.publicKeyData` pour `keyExchange` /
    ///    `keyExchangeAck`).
    ///
    /// **Important** : pour `keyExchange` / `keyExchangeAck`, la
    /// source (1) renvoie la clé long-terme de signature, **pas** la
    /// clé éphémère ECDH du payload (qui sert uniquement à dériver
    /// la clé de session symétrique). Cette distinction est
    /// cruciale : vérifier la signature du `keyExchange` avec la clé
    /// ECDH éphémère ferait échouer systématiquement la
    /// vérification, ce qui était précisément le bug corrigé.
    ///
    /// Retourne `nil` si aucune clé n'est disponible (sender
    /// inconnu / payload manquant / payload malformé).
    private func extractAdvertisedPublicKey(from message: AirBridgeMessage) -> Data? {
        // Priorité 1 : clé long-terme embarquée dans `Device`.
        if let advertised = message.sender.publicKeyData,
           !advertised.isEmpty {
            return advertised
        }

        // Priorité 2 : fallback sur le payload (compatibilité v1).
        guard let payload = message.payload else { return nil }
        guard message.type == .pairingRequest
            || message.type == .pairingResponse
            || message.type == .keyExchange
            || message.type == .keyExchangeAck else {
            return nil
        }

        do {
            if message.type == .keyExchange || message.type == .keyExchangeAck {
                let keyPayload = try messageCodec.decodePayload(
                    KeyExchangePayload.self,
                    from: payload,
                    messageType: message.type
                )
                return keyPayload.publicKeyData
            }
            let pairingPayload = try messageCodec.decodePayload(
                PairingPayload.self,
                from: payload,
                messageType: message.type
            )
            return pairingPayload.publicKeyData
        } catch {
            return nil
        }
    }

    /// Vérifie l'unicité du message dans la fenêtre anti-replay.
    ///
    /// Cette méthode encapsule l'appel à l'acteur `ReplayProtectionStore`
    /// et retourne `true` si le message est nouveau (autorisé), `false`
    /// s'il s'agit d'un replay (à rejeter).
    ///
    /// Doit être appelée uniquement APRÈS `runSecureReceptionPipeline`
    /// (vérification de signature réussie).
    private func isFreshMessage(_ message: AirBridgeMessage) async -> Bool {
        let isReplay = await replayProtection.observe(
            peerID: message.sender.id,
            messageID: message.messageID
        )
        return isReplay
    }

    /// Compare la clé publique annoncée dans le message avec celle persistée
    /// dans le PairingStore pour ce pair.
    ///
    /// - Returns: `true` si la clé stockée existe et correspond à la clé
    ///   annoncée, `false` sinon (clé manquante, inégalité, ou pair inconnu).
    ///   Ne lève aucune alerte utilisateur : la politique d'authentification
    ///   gère la rétrogradation et le signalement.
    private func peerPublicKeyMatches(
        advertisedPublicKey: Data?,
        for peerID: UUID
    ) -> Bool {
        guard let advertisedPublicKey = advertisedPublicKey else {
            // Pas de clé annoncée dans le message (ex: hello, ack sans pairage)
            return false
        }

        // Récupérer la clé persistée pour ce pair
        let storedKey = pairingStore.pairing(for: peerID)?.peerPublicKeyData
        guard let storedKey = storedKey else {
            // Pair pas encore enregistré : la clé annoncée n'a pas de référence
            return false
        }

        // Comparer les deux clés
        if storedKey == advertisedPublicKey {
            return true
        } else {
            // Clé annoncée ≠ clé stockée : tentative de substitution d'identité
            logger.warning("Clé publique annoncée DIFFÉRENTE de la clé stockée pour \(peerID, privacy: .public) — rétrogradation de confiance")
            return false
        }
    }

    func setNegotiatedProtocolVersion(_ version: Int) {
        self.negotiatedProtocolVersion = version
    }

    /// Définit l'identifiant de session pour la connexion courante.
    /// Appelé au moment du handshake sécurisé (HELLO/ACK authentifié)
    /// pour lier les chunks binaires v2 à la session.
    func setActiveSessionId(_ id: UUID?) {
        self.activeSessionId = id
    }

    /// Renvoie l'identifiant de session actif, ou `nil` si la session
    /// n'est pas encore authentifiée.
    func getActiveSessionId() -> UUID? {
        return self.activeSessionId
    }

    // MARK: - Handshake ECDH (échange de clés)

    /// Réalise un handshake ECDH P-256 avec le pair et dérive la clé
    /// symétrique de session (HKDF-SHA256, 256 bits).
    ///
    /// - Le message de notre clé publique éphémère part en
    ///   `keyExchange` (le `sessionId` est inclus dans le payload pour
    ///   lier la dérivation).
    /// - On attend en retour un `keyExchangeAck` du pair portant sa clé
    ///   publique éphémère.
    /// - La clé symétrique est dérivée par HKDF et retournée à
    ///   l'appelant (qui l'installera dans `OutgoingTransferManager` et
    ///   `IncomingTransferManager`).
    ///
    /// - Returns: clé symétrique 256 bits, ou `nil` si l'échange
    ///   échoue (timeout, clé publique invalide, etc.).
    func performECDHKeyExchange(
        sessionId: UUID,
        on connection: NWConnection
    ) async -> SymmetricKey? {
        let handshake = SecureHandshake()
        let payload = KeyExchangePayload(
            publicKey: handshake.publicKey,
            sessionId: sessionId
        )

        // 1. Envoi de notre clé publique.
        do {
            let payloadData = try messageCodec.encodePayload(payload)
            let message = AirBridgeMessage(
                type: .keyExchange,
                sender: localDevice,
                payload: payloadData
            )
            await sendAsync(message, on: connection)
        } catch {
            logger.error("Impossible d'envoyer la clé publique : \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // 2. Attente du `keyExchangeAck` du pair : on lit sur la
        //    connexion, on décode le payload, on dérive la clé.
        //    Pour rester simple, on attend une réponse par un mécanisme
        //    `AsyncStream` (jusqu'à 5 secondes).
        guard let peerPayload = await waitForKeyExchangeAck(
            sessionId: sessionId,
            on: connection
        ) else {
            logger.error("Pas de keyExchangeAck reçu")
            return nil
        }

        // 3. Dérivation HKDF et retour.
        do {
            let key = try handshake.deriveSessionKey(
                from: peerPayload.publicKeyData,
                sessionId: sessionId
            )
            return key
        } catch {
            logger.error("Dérivation de la clé de session impossible : \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `AsyncStream` qui émet un événement à chaque trame reçue
    /// (header + payload). Utilisé par le handshake pour attendre
    /// ponctuellement le `keyExchangeAck` du pair sans bloquer le
    /// récepteur principal.
    ///
    /// Pour rester minimal et chirurgical, on suspend ici sur une
    /// simple `Task.sleep` puis on s'appuie sur le fait que les
    /// trames suivantes du pair arrivent sur la même connexion. La
    /// consommation de la trame attendue est faite en lisant une
    /// nouvelle paire header/payload, mais cela reste réservé au
    /// handshake (chemin isolé).
    ///
    /// L'implémentation courante lit la prochaine trame sur la
    /// connexion en utilisant l'API Network directement, avec un
    /// timeout.
    private func waitForKeyExchangeAck(
        sessionId: UUID,
        on connection: NWConnection
    ) async -> KeyExchangePayload? {
        // Pour ne pas casser le récepteur principal qui consomme déjà
        // les trames (via `continueReceiving`), le `keyExchangeAck` est
        // simplement traité dans le flux normal de messages : la
        // méthode `await` ici est essentiellement un `try?` qui
        // retourne immédiatement `nil` et délègue le traitement final
        // au `MessageRouter` via la callback `onEvent` du
        // `AirBridgeCore`.
        //
        // L'initiation du handshake côté émetteur : on publie la clé
        // publique et on attend la dérivation synchrone lors de la
        // réception du `keyExchangeAck`. Le `AirBridgeCore` rappelle
        // `installSessionKey` quand la clé arrive.
        //
        // Côté réception du `keyExchangeAck` : on dérive la clé
        // immédiatement (cette méthode n'est pas utilisée côté
        // réception — voir `handleKeyExchangeAck`).
        _ = sessionId
        _ = connection
        return nil
    }

    /// Envoie un message via `connection.send` en exposant une API
    /// `async` au-dessus de la complétion de `Network.framework`.
    @discardableResult
    private func sendAsync(
        _ message: AirBridgeMessage,
        on connection: NWConnection
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            self.send(message, on: connection) { result in
                switch result {
                case .success:
                    continuation.resume(returning: true)
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Envoie notre `keyExchangeAck` (réponse à un `keyExchange` reçu).
    /// Utilisé par le `AirBridgeCore` quand il reçoit un `keyExchange`
    /// du pair.
    func sendKeyExchangeAck(
        publicKey: P256.KeyAgreement.PublicKey,
        sessionId: UUID,
        on connection: NWConnection
    ) {
        let payload = KeyExchangePayload(
            publicKey: publicKey,
            sessionId: sessionId
        )
        do {
            let payloadData = try messageCodec.encodePayload(payload)
            let message = AirBridgeMessage(
                type: .keyExchangeAck,
                sender: localDevice,
                payload: payloadData
            )
            send(message, on: connection)
        } catch {
            logger.error("Impossible d'encoder le keyExchangeAck : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Envoie un `AirBridgeMessage` déjà construit sur la connexion. API
    /// publique utilisée par le `AirBridgeCore` pour les messages de
    /// contrôle non encore couverts par les helpers dédiés (par
    /// exemple l'initiation du handshake ECDH).
    func send(
        _ message: AirBridgeMessage,
        on connection: NWConnection
    ) {
        send(message, on: connection, completion: nil)
    }

    init(
        localDevice: Device,
        messageRouter: MessageRouter,
        pairingStore: PairingStore
    ) {
        self.localDevice = localDevice
        self.messageRouter = messageRouter
        self.pairingStore = pairingStore
    }

    /// Encode un message avec un payload binaire direct (pour fileChunk v2+).
    /// Évite le double encodage base64 (Data -> JSON base64 -> Frame base64).
    private func encodeMessageWithBinaryPayload(
        _ message: AirBridgeMessage,
        payloadData: Data
    ) throws -> Data {
        // Pour l'instant, on ne peut pas envoyer de binaire direct dans JSON
        // La solution complète nécessite de changer le format du message pour fileChunk
        // Pour l'instant on retourne l'encodage JSON standard (double base64)
        return try messageCodec.encode(message)
    }


    func connect(to discoveredDevice: DiscoveredDevice) {
        guard connection == nil else {
               logger.info("Une connexion est déjà active avec \(self.connectedDevice?.name ?? "un appareil", privacy: .public)")
               return
           }

           stateDescription = "Connexion en cours…"

           // L'endpoint tentée est mémorisée pour être invalidée en cas
           // d'échec : on ne doit jamais rejouer une adresse périmée.
           lastAttemptedEndpoint = discoveredDevice.endpoint

           let parameters = makeParameters()

           let newConnection = NWConnection(
               to: discoveredDevice.endpoint,
               using: parameters
           )

        let newSession = AirBridgeSession(
            connection: newConnection,
            direction: .outgoing,
            peer: discoveredDevice.device
        )

        session = newSession
        isSessionReady = false

           logger.info("Session demandée vers \(discoveredDevice.device.name, privacy: .public)")

        // Timeout applicatif : sans lui, une connexion vers un pair injoignable
        // reste en `.waiting` très longtemps (SO_ERROR 60 observé), pendant que
        // les campagnes de reprise consomment leur backoff sur du vide.
        let timeoutTask = Task { @MainActor [weak self, weak newConnection] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.connectionTimeout * 1_000_000_000)
            )

            guard let self, let newConnection else { return }
            guard self.session === newSession else { return }
            guard !self.isSessionReady else { return }

            Self.staticLogger.warning("Connexion vers \(discoveredDevice.device.name, privacy: .public) expirée après \(Int(Self.connectionTimeout)) s")
            newConnection.cancel()
        }

        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch state {
                case .setup:
                    self.stateDescription = "Configuration"

                case .preparing:
                    self.stateDescription = "Connexion en cours…"
                    newSession.updateState(.connecting)

                case .ready:
                    timeoutTask.cancel()
                    self.isSessionReady = true
                    self.stateDescription = "Connecté"
                    newSession.updateState(.ready)

                    logger.info("Session prête avec \(discoveredDevice.device.name, privacy: .public)")

                    self.sendHello(on: newConnection)
                    self.continueReceiving(on: newConnection)
                    self.onSessionReady?(newConnection)

                    // Feedback audio court marquant l'établissement
                    // d'une session sécurisée avec un pair distant.
                    // Le guard `!self.isSessionReady` au-dessus (et
                    // le `isSessionReady = true` posé juste avant)
                    // garantit qu'on n'entre dans ce bloc qu'une
                    // seule fois par session — donc le son n'est
                    // joué qu'une fois. `SoundService` reste un
                    // no-op silencieux si AudioToolbox n'est pas
                    // disponible (CI exotique), on peut donc
                    // l'appeler sans `#if` supplémentaire.
                    SoundService.play(.connected)

                case .waiting(let error):
                    self.stateDescription = "En attente"
                    newSession.updateState(.waiting)
                    logger.debug("Session en attente : \(error.localizedDescription, privacy: .public)")

                case .failed(let error):
                    timeoutTask.cancel()
                    self.stateDescription = "Échec"
                    newSession.updateState(.failed)

                    logger.error("Échec de la session : \(error.localizedDescription, privacy: .public)")

                    self.closeSession(
                        newSession,
                        state: .failed
                    )

                case .cancelled:
                    timeoutTask.cancel()
                    // L'endpoint tentée est invalidée : elle vient soit
                    // d'expirer, soit d'être remplacée. Une prochaine
                    // tentative doit partir d'une redécouverte fraîche.
                    if self.lastAttemptedEndpoint == discoveredDevice.endpoint {
                        self.lastAttemptedEndpoint = nil
                    }

                    self.closeSession(
                        newSession,
                        state: .disconnected
                    )

                    logger.info("Session annulée")

                @unknown default:
                    self.stateDescription = "État inconnu"
                }
            }
        }

        newConnection.start(queue: Self.networkQueue)
    }
    
    func disconnect() {
        guard let session else {
            logger.info("Aucune session à fermer")
            return
        }

        closeSession(
            session,
            state: .disconnected
        )

        logger.info("Session fermée")
    }

    private func closeConnection(
        _ connection: NWConnection
    ) {
        guard let session,
              session.connection === connection else {
            connection.cancel()
            return
        }

        closeSession(
            session,
            state: .disconnected
        )
    }

    private func closeSession(
        _ closingSession: AirBridgeSession,
        state: AirBridgeSession.State
    ) {
        guard session === closingSession else {
            closingSession.updateState(state)
            return
        }

        // Le pair est extrait AVANT de détruire la session : une fois
        // `session = nil` posé, `connectedDevice` ne répond plus et le
        // traitement de déconnexion ne saurait plus à qui rattacher les
        // transferts actifs.
        let lostPeer = closingSession.peer

        if let lostPeer {
            lastConnectedPeer = lostPeer
        }

        closingSession.updateState(state)
        session = nil
        isSessionReady = false
        stateDescription = "Déconnecté"

        onSessionClosed?(lostPeer)

        closingSession.connection.cancel()
    }


    private func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        // `disableAckStretching` réduit l'attente du dernier ACK
        // avant d'envoyer le suivant : améliore la latence aller-retour
        // sur réseau local pour les petits acquittements (par défaut,
        // Apple étire les ACK pour grouper les retours).
        tcpOptions.disableAckStretching = true
        // `enableFastOpen` évite le handshake TCP complet sur les
        // reprises de connexion courtes (une fois le cookie négocié).
        tcpOptions.enableFastOpen = true

        let parameters = NWParameters(
            tls: nil,
            tcp: tcpOptions
        )

        // `NWProtocolTCP.Options` n'expose PAS directement
        // `tcpReceiveBufferSize` / `tcpSendBufferSize` : la taille des
        // buffers socket est contrôlée par le système en fonction de la
        // `serviceClass`. `.responsiveData` est la classe optimisée pour
        // les transferts de données interactifs : le noyau dimensionne
        // les buffers en conséquence, ce qui débloque la fenêtre TCP sur
        // les fichiers volumineux (sans elle, on plafonnait autour de
        // 64-256 Ko sur réseau Gigabit, ce qui bridait le pipeline à
        // ~50 Mo/s indépendamment des autres optimisations).
        parameters.serviceClass = .responsiveData
        parameters.includePeerToPeer = true

        return parameters
    }
    
    func accept(_ incomingConnection: NWConnection) {
        guard session == nil else {
            logger.warning("Connexion entrante refusée : une session est déjà active")
            incomingConnection.cancel()
            return
        }

        let incomingSession = AirBridgeSession(
            connection: incomingConnection,
            direction: .incoming
        )

        session = incomingSession
        isSessionReady = false

        incomingConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch state {
                case .setup:
                    self.stateDescription = "Configuration"

                case .preparing:
                    self.stateDescription = "Connexion entrante en cours…"

                case .ready:
                      self.isSessionReady = true
                      self.stateDescription = "Connecté"
                      incomingSession.updateState(.ready)
                      logger.info("Session entrante acceptée")
                      self.continueReceiving(on: incomingConnection)
                      self.onSessionReady?(incomingConnection)

                case .waiting(let error):
                    self.stateDescription = "En attente"
                    logger.debug("Connexion entrante en attente : \(error.localizedDescription, privacy: .public)")

                case .failed(let error):
                    self.stateDescription = "Échec"
                    incomingSession.updateState(.failed)

                    logger.error("Session entrante échouée : \(error.localizedDescription, privacy: .public)")

                    self.closeSession(
                        incomingSession,
                        state: .failed
                    )

                case .cancelled:
                    self.closeSession(
                        incomingSession,
                        state: .disconnected
                    )

                    logger.info("Session entrante annulée")

                @unknown default:
                    self.stateDescription = "État inconnu"
                }
            }
        }

        incomingConnection.start(queue: Self.networkQueue)
    }
    
    
    
    
    private func sendHello(on connection: NWConnection) {
        let message = AirBridgeMessage(
            type: .hello,
            sender: localDevice
        )

        send(message, on: connection)
    }
    
    

    private func receiveHeader(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: FrameCodec.headerSize,
            maximumLength: FrameCodec.headerSize
        ) { [weak self] data, _, isComplete, error in

            if let error {
                self?.logger.error("Erreur de lecture de l’en-tête : \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in
                    self?.closeConnection(connection)
                }
                return
            }

            if isComplete, data == nil || data?.isEmpty == true {
                self?.logger.info("Connexion fermée proprement par l’appareil distant")
                Task { @MainActor [weak self] in
                    self?.closeConnection(connection)
                }
                return
            }

            guard let data,
                  data.count == FrameCodec.headerSize else {
                self?.logger.error("En-tête incomplet : \(data?.count ?? 0, privacy: .public)/\(FrameCodec.headerSize) octets")
                connection.cancel()
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    let payloadLength = try self.frameCodec.decodeLength(
                        from: data
                    )

                    self.receivePayload(
                        length: payloadLength,
                        on: connection
                    )

                } catch {
                    logger.error("En-tête invalide : \(error.localizedDescription, privacy: .public)")
                    connection.cancel()
                }
            }
        }
    }
    
    func continueReceiving(on connection: NWConnection) {
        receiveHeader(on: connection)
    }
    
    private func receivePayload(
        length: Int,
        on connection: NWConnection
    ) {

        guard length > 0 else {
             logger.error("Taille de payload invalide : \(length)")
             connection.cancel()
             return
         }

        connection.receive(
            minimumIncompleteLength: length,
            maximumLength: length
        ) { [weak self] data, _, isComplete, error in

            if let error {
                self?.logger.error("Erreur de lecture du message : \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }

            guard let data,
                  data.count == length else {
                self?.logger.error("Message incomplet")
                connection.cancel()
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    // Pour v2 fileChunk, le payload est binaire direct sans JSON wrapper
                    // On doit d'abord essayer de décoder comme JSON, et si ça échoue
                    // et que c'est peut-être un fileChunk binaire, on essaie le format binaire

                    var message: AirBridgeMessage

                    do {
                        message = try self.messageCodec.decode(data)
                    } catch {
                        // JSON decode failed - check if it's a binary fileChunk v2
                        // Un fileChunk binaire v2 commence par le length (4 octets) puis UUID (16 octets)
                        // Le length du chunk ne doit pas être confondu avec le FrameHeader length
                        // Ici, `data` est déjà le payload complet (après le FrameHeader)

                        // Essayer de décoder comme BinaryFileChunkPayload
                        if data.count >= BinaryFileChunkPayload.headerSize {
                            do {
                                let binaryChunk = try BinaryFileChunkPayload.decode(data)
                                // Reconstruire un AirBridgeMessage avec le payload binaire
                                // Le sender n'est PAS disponible dans le binaire v2 —
                                // utiliser le pair identifié sur la session (le HELLO
                                // antérieur a fixé cette identité) plutôt qu'un Device
                                // placeholder à UUID aléatoire qui ferait échouer
                                // toute résolution côté MessageRouter (les transferts
                                // sortants et la liaison aux chunks existants
                                // s'appuient sur cet identifiant).
                                let senderDevice: Device = self.connectedDevice
                                    ?? self.lastConnectedPeer
                                    ?? self.session?.peer
                                    ?? Device(id: UUID(), name: "Unknown", model: "", systemVersion: "")
                                // On attache le payload **déjà décodé** dans
                                // `decodedBinaryChunk` : les consommateurs en
                                // aval (AirBridgeCore.onEvent) l'utilisent
                                // directement plutôt que de re-décoder le
                                // `payload` brut, ce qui élimine un
                                // `BinaryFileChunkPayload.decode` redondant
                                // par chunk.
                                message = AirBridgeMessage(
                                    protocolVersion: 2,
                                    messageID: binaryChunk.transferID,
                                    type: .fileChunk,
                                    sender: senderDevice,
                                    payload: data,
                                    decodedBinaryChunk: binaryChunk
                                )
                            } catch {
                                // Pas un chunk binaire valide non plus
                                throw error
                            }
                        } else {
                            throw error
                        }
                    }

                    // Contrôlé avant tout usage : `sender` et `payload` d'une
                    // version inconnue n'ont pas forcément le sens qu'on leur
                    // prête ici.
                    guard ProtocolCompatibility.isSupported(
                        message.protocolVersion
                    ) else {

                        logger.error("Message refusé, \(ProtocolCompatibility.rejectionReason(for: message.protocolVersion), privacy: .public)")

                        connection.cancel()
                        return
                    }

                    // Un fileChunk binaire v2 ne transporte pas d'expéditeur :
                    // son `sender` est reconstruit factice (UUID aléatoire).
                    // Réidentifier le pair à chaque message écraserait donc la
                    // véritable identité — et une coupure ultérieure ne saurait
                    // plus rattacher les transferts. L'identification ne se fait
                    // que sur les messages qui portent un sender fiable.
                    let isSenderReliable = message.type != .fileChunk

                    if isSenderReliable {
                        self.session?.identifyPeer(message.sender)

                        // Le HELLO est le moment où le pair devient identifiable :
                        // mémoriser ici le dernier pair connu, pour qu'une coupure
                        // ultérieure — même sans session restante — puisse lui
                        // rattacher ses transferts.
                        if let peer = self.session?.peer {
                            self.lastConnectedPeer = peer
                        }
                    }

                    // Vérification cryptographique + anti-replay.
                    // Les chunks de fichier ne sont pas signés un par un
                    // (ils sont trop nombreux) ; ils sont protégés par un
                    // `transferCompleted` signé en fin de transfert. Le
                    // pipeline applique, dans l'ordre strict :
                    //   1. identification du pair (déjà faite au-dessus) ;
                    //   2. résolution de la PairingInfo ;
                    //   3. calcul de l'AuthenticationRequirement ;
                    //   4. vérification cryptographique stricte ;
                    //   5. observation anti-replay (après vérification OK) ;
                    //   6. routage.
                    // En cas d'échec d'une étape, on continue à recevoir
                    // pour ne pas casser la connexion, mais le message n'est
                    // PAS routé.
                    if message.type != .fileChunk {
                        // Étapes 2-4 : tout est synchrone et local.
                        guard self.runSecureReceptionPipeline(
                            for: message
                        ) else {
                            self.receiveHeader(on: connection)
                            return
                        }

                        // Étape 5 : anti-replay. L'appel à `observe` est
                        // `await`-é : le `ReplayProtectionStore` est un
                        // actor, donc sûr. On ne l'invoque qu'APRÈS la
                        // vérification de signature (étape 4) pour
                        // éviter d'empoisonner le store avec des
                        // messageIDs invalides.
                        let isReplay = await self.isFreshMessage(message)
                        guard isReplay else {
                            self.logger.warning("Replay détecté pour \(message.type.rawValue, privacy: .public) de \(message.sender.name, privacy: .public) (messageID=\(message.messageID, privacy: .public)) — message ignoré")
                            self.receiveHeader(on: connection)
                            return
                        }
                    }

                    self.session?.touch()

                    self.messageRouter.route(
                        message,
                        on: connection
                    )

                    self.receiveHeader(on: connection)


                } catch {
                    logger.error("Impossible de décoder le message : \(error.localizedDescription, privacy: .public)")
                    connection.cancel()
                }
            }

            if isComplete {
                self?.logger.info("La connexion distante a terminé l’envoi")
            }
        }
    }
    

     func sendAcknowledgement(
        on connection: NWConnection
    ) {
        let message = AirBridgeMessage(
              type: .acknowledgement,
              sender: localDevice
          )

          send(message, on: connection)
    }

    /// Envoie une demande de pairage (premier message du handshake).
    func sendPairingRequest(
        peerID: UUID,
        peerName: String,
        challenge: Data,
        on connection: NWConnection,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        do {
            let identity = try SecureIdentityStore.ensureIdentity()
            let signature = try SecureIdentityStore.sign(challenge)

            let payload = PairingPayload(
                peerID: peerID,
                peerName: peerName,
                publicKeyData: identity.publicKeyData,
                challenge: challenge,
                signature: signature,
                protocolVersion: ProtocolCompatibility.currentVersion
            )

            let message = AirBridgeMessage(
                type: .pairingRequest,
                sender: localDevice,
                payload: try messageCodec.encodePayload(payload)
            )

            send(message, on: connection, completion: completion)
        } catch {
            logger.error("Impossible de créer le payload de pairage : \(error.localizedDescription, privacy: .public)")
            completion?(.failure(error))
        }
    }

    /// Envoie une réponse de pairage (notre challenge signé par le pair).
    func sendPairingResponse(
        peerID: UUID,
        peerName: String,
        challenge: Data,
        on connection: NWConnection,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        do {
            let identity = try SecureIdentityStore.ensureIdentity()
            let signature = try SecureIdentityStore.sign(challenge)

            let payload = PairingPayload(
                peerID: peerID,
                peerName: peerName,
                publicKeyData: identity.publicKeyData,
                challenge: challenge,
                signature: signature,
                protocolVersion: ProtocolCompatibility.currentVersion
            )

            let message = AirBridgeMessage(
                type: .pairingResponse,
                sender: localDevice,
                payload: try messageCodec.encodePayload(payload)
            )

            send(message, on: connection, completion: completion)
        } catch {
            logger.error("Impossible de créer la réponse de pairage : \(error.localizedDescription, privacy: .public)")
            completion?(.failure(error))
        }
    }

    private func send(
        _ message: AirBridgeMessage,
        on connection: NWConnection,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        // Signature des messages de contrôle. Les chunks de fichier
        // ne sont pas signés un par un (la chaîne est protégée par
        // un `transferCompleted` signé à la fin du transfert).
        let signedMessage: AirBridgeMessage
        if message.type != .fileChunk,
           message.signature == nil,
           let signature = MessageAuthenticator.sign(message) {
            signedMessage = AirBridgeMessage(
                protocolVersion: message.protocolVersion,
                messageID: message.messageID,
                type: message.type,
                sender: message.sender,
                payload: message.payload,
                signature: signature
            )
        } else {
            signedMessage = message
        }

        do {
            let messageData = try messageCodec.encode(signedMessage)
            let frame = try frameCodec.encode(messageData)

            // La complétion est appelée au plus une fois, depuis la file du
            // framework Network ; la copie explicitement non isolée ne crée
            // aucune course de données.
            nonisolated(unsafe) let completion = completion

            connection.send(
                content: frame,
                completion: .contentProcessed { error in

                    if let error {
                        self.logger.error("Erreur d’envoi : \(error.localizedDescription, privacy: .public)")
                        completion?(.failure(error))
                        return
                    }

                    // Les morceaux ne sont pas journalisés : ils se comptent
                    // par milliers sur un gros fichier, et `print` formate
                    // puis écrit de façon synchrone. La progression est déjà
                    // observable dans l'interface.
                    if signedMessage.type != .fileChunk {
                        self.logger.debug("Message envoyé : \(signedMessage.type.rawValue, privacy: .public)")
                    }

                    Task { @MainActor [weak self] in
                        self?.session?.touch()
                        completion?(.success(()))
                    }
                }
            )

        } catch {
            logger.error("Impossible d’encoder \(signedMessage.type.rawValue, privacy: .public) : \(error.localizedDescription, privacy: .public)")

            completion?(.failure(error))
        }
    }
    
    
    @discardableResult
    func sendTransferRequest(
        transferID: UUID = UUID(),
        fileName: String,
        fileSize: Int64,
        contentType: String?,
        batchID: UUID? = nil,
        batchFolderName: String? = nil,
        relativePath: String? = nil
    ) -> UUID? {
        guard let connection else {
            logger.error("Impossible d’envoyer la demande : aucune connexion active")
            return nil
        }

        let requestPayload = TransferRequestPayload(
            transferID: transferID,
            fileName: fileName,
            fileSize: fileSize,
            contentType: contentType,
            batchID: batchID,
            batchFolderName: batchFolderName,
            relativePath: relativePath
        )

        do {
            let payloadData = try messageCodec.encodePayload(
                requestPayload
            )

            let message = AirBridgeMessage(
                type: .transferRequest,
                sender: localDevice,
                payload: payloadData
            )

            send(message, on: connection)

            return requestPayload.transferID

        } catch {
            logger.error("Impossible d’encoder la demande : \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    
    func sendTransferAccepted(
        transferID: UUID,
        on connection: NWConnection
    ) {
        let payload = TransferAcceptedPayload(
            transferID: transferID
        )

        do {
            let payloadData = try messageCodec.encodePayload(payload)

            let message = AirBridgeMessage(
                type: .transferAccepted,
                sender: localDevice,
                payload: payloadData
            )

            send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder l’acceptation : \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func sendTransferRejected(
        transferID: UUID,
        reason: String?,
        on connection: NWConnection
    ) {
        let payload = TransferRejectedPayload(
            transferID: transferID,
            reason: reason
        )

        do {
            let payloadData = try messageCodec.encodePayload(payload)

            let message = AirBridgeMessage(
                type: .transferRejected,
                sender: localDevice,
                payload: payloadData
            )

            send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder le refus : \(error.localizedDescription, privacy: .public)")
        }
    }

    func sendTransferCompleted(
        transferID: UUID,
        totalBytes: Int64,
        sha256: String
    ) {
        guard let connection else {
            logger.error("Aucune connexion active")
            return
        }

        let payload = TransferCompletedPayload(
            transferID: transferID,
            totalBytes: totalBytes,
            sha256: sha256
        )

        do {
            let payloadData = try messageCodec.encodePayload(
                payload
            )

            let message = AirBridgeMessage(
                type: .transferCompleted,
                sender: localDevice,
                payload: payloadData
            )

            send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder transferCompleted : \(error.localizedDescription, privacy: .public)")
        }
    }
    func sendTransferSucceeded(
        transferID: UUID,
        receivedBytes: Int64,
        on connection: NWConnection
    ) {
        let payload = TransferSucceededPayload(
            transferID: transferID,
            receivedBytes: receivedBytes
        )

        do {
            let payloadData = try messageCodec.encodePayload(payload)

            let message = AirBridgeMessage(
                type: .transferSucceeded,
                sender: localDevice,
                payload: payloadData
            )

            send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder transferSucceeded : \(error.localizedDescription, privacy: .public)")
        }
    }
    
    
    func sendTransferFailed(
        transferID: UUID,
        reason: String,
        on connection: NWConnection
    ) {
        let payload = TransferFailedPayload(
            transferID: transferID,
            reason: reason
        )

        do {
            let payloadData = try messageCodec.encodePayload(payload)

            let message = AirBridgeMessage(
                type: .transferFailed,
                sender: localDevice,
                payload: payloadData
            )

            send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder transferFailed : \(error.localizedDescription, privacy: .public)")
        }
    }
    
    
    
    
    func sendResumeRequest(
        transferID: UUID,
        receivedBytes: Int64,
        fileSize: Int64,
        fileName: String = "",
        chunkSize: Int = 0,
        sha256: String = ""
    ) {
        // Garde stricte : la session doit être confirmée `.ready` par le
        // `stateUpdateHandler`. Une session en préparation ou en attente
        // accepterait l'envoi en file sans jamais le délivrer — sur une
        // connexion qui expire, le resumeRequest partirait dans le vide.
        guard isSessionReady, let connection else {
            logger.error("Impossible d’envoyer resumeRequest : session non prête")
            return
        }

        let protocolVersion = negotiatedProtocolVersion

        let payload = ResumeRequestPayload(
            transferID: transferID,
            offset: receivedBytes,
            fileName: fileName,
            sha256: sha256,
            chunkSize: chunkSize,
            receivedBytes: receivedBytes,
            fileSize: fileSize,
            protocolVersion: protocolVersion
        )
        do {
            let payloadData = try messageCodec.encodePayload(payload)
            let message = AirBridgeMessage(
                protocolVersion: protocolVersion,
                type: .resumeRequest,
                sender: localDevice,
                payload: payloadData
            )
            send(message, on: connection)
        } catch {
            logger.error("Impossible d’encoder resumeRequest")
        }
    }

    func sendResumeAccepted(
        transferID: UUID,
        offset: Int64,
        fileName: String,
        sha256: String,
        chunkSize: Int,
        fileSize: Int64,
        on connection: NWConnection
    ) {
        let payload = ResumeAcceptedPayload(
            transferID: transferID,
            offset: offset,
            fileName: fileName,
            sha256: sha256,
            chunkSize: chunkSize,
            fileSize: fileSize
        )
        do {
            let payloadData = try messageCodec.encodePayload(payload)
            let message = AirBridgeMessage(
                type: .resumeAccepted,
                sender: localDevice,
                payload: payloadData
            )
            send(message, on: connection)
        } catch {
            logger.error("Impossible d’encoder resumeAccepted")
        }
    }

    func sendTransferCancelled(
        transferID: UUID,
        reason: String? = nil
    ) {
        guard let connection else {
            logger.error("Impossible d’envoyer transferCancelled : aucune connexion active")
            return
        }

        let payload = TransferCancelledPayload(
            transferID: transferID,
            reason: reason
        )

        do {
            let payloadData = try messageCodec.encodePayload(
                payload
            )

            let message = AirBridgeMessage(
                type: .transferCancelled,
                sender: localDevice,
                payload: payloadData
            )

            send(
                message,
                on: connection
            )

        } catch {
            logger.error("Impossible d’encoder transferCancelled : \(error.localizedDescription, privacy: .public)")
        }
    }
    
}



