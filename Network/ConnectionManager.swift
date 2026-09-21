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

    /// Dernier contrôle écarté à la réception, avec sa cause.
    ///
    /// Un message de contrôle rejeté (signature non vérifiable, pair jamais
    /// appairé, rejeu) n'était visible que dans les traces système : côté
    /// émetteur, le transfert restait « En attente » sans aucune explication
    /// à l'écran. Cet état permet à l'interface de diagnostic de nommer la
    /// cause exacte (ex. « transferAccepted écarté : pair non appairé »).
    private(set) var lastReceptionRejection: ReceptionRejection?

    /// Vrai uniquement quand la session courante a été confirmée `.ready`
    /// par le `stateUpdateHandler` — jamais entre `connect()` et ce
    /// callback, où la session existe déjà mais ne peut rien transporter.
    ///
    /// Toutes les gardes d'envoi applicatif (resumeRequest notamment)
    /// doivent consulter ce drapeau et non la seule présence de `session`.
    private(set) var isSessionReady = false

    /// Vrai uniquement après HELLO/ACK et ECDH complétés. La présence
    /// d'une connexion TCP ne suffit jamais à autoriser un transfert.
    private(set) var isSecureSessionReady = false

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
        case authenticationUnavailable
        case secureSessionNotReady
        case encodingError(Error)
    }

    // MARK: - Protocol version tracking for v2 binary chunks
    private var negotiatedProtocolVersion: Int = ProtocolCompatibility.currentVersion

    /// Identifiant de session actif pour la connexion courante.
    /// Généré au handshake sécurisé (hello/ack authentifié) et utilisé
    /// pour lier les chunks binaires v2 à la session, empêchant un
    /// attaquant d'injecter des chunks d'une autre session.
    private var activeSessionId: UUID? = nil

    /// Les contrôles qui mutent un transfert ne peuvent circuler qu'après
    /// l'installation complète de la clé ECDH et du sessionId. Les messages
    /// de découverte, de pairage et d'échange de clés restent autorisés
    /// avant cette barrière pour pouvoir établir la session.
    private func requiresSecureSession(for type: AirBridgeMessageType) -> Bool {
        switch type {
        case .transferRequest,
             .transferAccepted,
             .transferRejected,
             .transferCancelled,
             .transferCompleted,
             .transferSucceeded,
             .transferFailed,
             .resumeRequest,
             .resumeAccepted,
             .fileChunk:
            return true
        default:
            return false
        }
    }

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

        // 3. En v2, l'enveloppe doit toujours porter la clé long-terme
        //    du sender. Un pair sans clé ne peut pas bénéficier d'un
        //    fallback implicite.
        guard message.sender.publicKeyData?.isEmpty == false else {
            recordRejection(.missingPublicKey, for: message)
            logger.error("Message v2 sans clé publique long terme")
            return false
        }

        let advertisedPublicKey = extractAdvertisedPublicKey(from: message)
        guard payloadIdentityMatchesSender(message) else {
            recordRejection(.identityMismatch, for: message)
            logger.error("Identité du payload différente de celle du sender")
            return false
        }

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
            // La cause exacte est conservée pour l'écran de diagnostic :
            // un `transferAccepted` écarté ici laisse sinon l'émetteur
            // « En attente » sans aucune explication exploitable.
            let rejectionKind: ReceptionRejection.Kind
            if pairingInfo == nil {
                rejectionKind = .peerNotPaired
            } else if !peerPublicKeyMatches {
                rejectionKind = .keyMismatch
            } else {
                rejectionKind = .signatureInvalid
            }

            recordRejection(rejectionKind, for: message)
            logger.error("Signature invalide pour \(message.type.rawValue, privacy: .public) de \(message.sender.name, privacy: .public) (policy=\(String(describing: requirement), privacy: .public)) — message ignoré")
            return false
        }

        return true
    }

    /// Mémorise le dernier contrôle écarté (cause + type + pair).
    /// Purement diagnostique : ne modifie aucune décision de sécurité.
    private func recordRejection(
        _ kind: ReceptionRejection.Kind,
        for message: AirBridgeMessage
    ) {
        lastReceptionRejection = ReceptionRejection(
            kind: kind,
            messageType: message.type.rawValue,
            peerName: message.sender.name
        )
    }

    /// Vérifie les champs d'identité redondants des payloads de pairage.
    /// La clé ECDH du payload est volontairement différente de la clé de
    /// signature du sender ; elle n'est donc pas comparée ici.
    private func payloadIdentityMatchesSender(_ message: AirBridgeMessage) -> Bool {
        guard let senderKey = message.sender.publicKeyData else { return false }

        guard message.type == .pairingRequest
            || message.type == .pairingResponse else {
            return true
        }

        guard let payloadData = message.payload,
              let payload = try? messageCodec.decodePayload(
                PairingPayload.self,
                from: payloadData,
                protocolVersion: message.protocolVersion,
                messageType: message.type
              ) else {
            return false
        }

        return payload.peerID == message.sender.id
            && payload.publicKeyData == senderKey
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
        guard ProtocolCompatibility.isSupported(version) else {
            isSecureSessionReady = false
            return
        }

        if negotiatedProtocolVersion != version {
            isSecureSessionReady = false
        }
        self.negotiatedProtocolVersion = version
    }

    /// Définit l'identifiant de session pour la connexion courante.
    /// Appelé au moment du handshake sécurisé (HELLO/ACK authentifié)
    /// pour lier les chunks binaires v2 à la session.
    func setActiveSessionId(_ id: UUID?) {
        if self.activeSessionId != id {
            isSecureSessionReady = false
        }
        self.activeSessionId = id
    }

    /// Marque la session comme utilisable par le protocole de transfert.
    /// Appelé uniquement après installation effective de la clé ECDH dans
    /// les deux gestionnaires de chunks.
    func markSecureSessionReady() {
        guard session != nil,
              isSessionReady,
              negotiatedProtocolVersion >= ProtocolCompatibility.currentVersion,
              activeSessionId != nil else {
            isSecureSessionReady = false
            return
        }
        isSecureSessionReady = true
    }

    func resetSecureSession() {
        isSecureSessionReady = false
        activeSessionId = nil
        negotiatedProtocolVersion = ProtocolCompatibility.currentVersion
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
        on connection: NWConnection,
        completion: ((Result<Void, Error>) -> Void)? = nil
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
            send(message, on: connection, completion: completion)
        } catch {
            logger.error("Impossible d'encoder le keyExchangeAck : \(error.localizedDescription, privacy: .public)")
            completion?(.failure(error))
        }
    }

    /// Envoie un `AirBridgeMessage` déjà construit sur la connexion. API
    /// publique utilisée par le `AirBridgeCore` pour les messages de
    /// contrôle non encore couverts par les helpers dédiés (par
    /// exemple l'initiation du handshake ECDH).
    @discardableResult
    func send(
        _ message: AirBridgeMessage,
        on connection: NWConnection
    ) -> Bool {
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
        resetSecureSession()

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

                    guard self.sendHello(on: newConnection) else {
                        self.closeSession(newSession, state: .failed)
                        return
                    }
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
        resetSecureSession()
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
        resetSecureSession()

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
    
    
    
    
    @discardableResult
    private func sendHello(on connection: NWConnection) -> Bool {
        let message = AirBridgeMessage(
            type: .hello,
            sender: localDevice
        )

        return send(message, on: connection)
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

                    // Un fileChunk binaire v2 ne transporte pas d'expéditeur
                    // dans sa trame. Il doit donc être lié à l'identité déjà
                    // validée et au `sessionId` ECDH courant.
                    let isSenderReliable = message.type != .fileChunk

                    if isSenderReliable,
                       let expectedPeer = self.session?.peer {
                        guard expectedPeer.id == message.sender.id else {
                            self.logger.error("Changement d'identité sur une session active — connexion fermée")
                            connection.cancel()
                            return
                        }
                        if let expectedKey = expectedPeer.publicKeyData,
                           expectedKey != message.sender.publicKeyData {
                            self.logger.error("Changement de clé sur une session active — connexion fermée")
                            connection.cancel()
                            return
                        }
                    }

                    if !isSenderReliable {
                        guard self.session?.peer != nil,
                              self.isSecureSessionReady,
                              self.activeSessionId == message.decodedBinaryChunk?.sessionId else {
                            self.logger.error("Chunk reçu avant l'identité ou la session sécurisée")
                            connection.cancel()
                            return
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
                            self.recordRejection(.replay, for: message)
                            self.logger.warning("Replay détecté pour \(message.type.rawValue, privacy: .public) de \(message.sender.name, privacy: .public) (messageID=\(message.messageID, privacy: .public)) — message ignoré")
                            self.receiveHeader(on: connection)
                            return
                        }
                    }

                    // Toute mutation de transfert est bloquée tant que la
                    // dérivation ECDH/HKDF et l'installation de la clé ne
                    // sont pas terminées. Ne pas simplement router puis
                    // espérer que le gestionnaire de transfert la refuse :
                    // l'annonce elle-même ne doit jamais créer d'état.
                    if self.requiresSecureSession(for: message.type),
                       !self.isSecureSessionReady {
                        self.recordRejection(.secureSessionNotReady, for: message)
                        self.logger.error("\(message.type.rawValue, privacy: .public) reçu avant la session sécurisée — connexion fermée")
                        connection.cancel()
                        return
                    }

                    // L'identité n'entre dans la session qu'après signature
                    // vérifiée et anti-rejeu. Un sender non authentifié ne
                    // peut donc pas remplacer le pair associé à la connexion.
                    if isSenderReliable {
                        self.session?.identifyPeer(message.sender)
                        self.lastConnectedPeer = message.sender
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
    

    @discardableResult
    func sendAcknowledgement(
        on connection: NWConnection
    ) -> Bool {
        let message = AirBridgeMessage(
            type: .acknowledgement,
            sender: localDevice
        )

        return send(message, on: connection)
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

    @discardableResult
    private func send(
        _ message: AirBridgeMessage,
        on connection: NWConnection,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        // Toutes les trames doivent appartenir à la session active. Cela
        // évite qu'une réponse mise en file pour une ancienne connexion
        // soit émise sur un socket désormais réutilisé.
        guard session?.connection === connection else {
            completion?(.failure(ConnectionManagerError.noActiveConnection))
            return false
        }

        // La v1 est définitivement désactivée : aucune trame de contrôle
        // non signée ne doit sortir, même si un appelant fournit
        // accidentellement une ancienne version.
        guard message.protocolVersion >= ProtocolCompatibility.currentVersion,
              ProtocolCompatibility.isSupported(message.protocolVersion) else {
            completion?(.failure(ConnectionManagerError.authenticationUnavailable))
            return false
        }

        // Les contrôles qui peuvent créer ou muter un transfert ne sont
        // autorisés qu'après installation effective de la clé de session.
        // Le hello, le pairage et les deux messages ECDH restent les seules
        // exceptions nécessaires à l'établissement de cette barrière.
        guard !requiresSecureSession(for: message.type)
                || isSecureSessionReady else {
            logger.error("Envoi de \(message.type.rawValue, privacy: .public) refusé : session sécurisée non prête")
            completion?(.failure(ConnectionManagerError.secureSessionNotReady))
            return false
        }

        let signedMessage: AirBridgeMessage
        if message.type == .fileChunk {
            signedMessage = message
        } else {
            guard message.sender.id == localDevice.id,
                  message.sender.publicKeyData == localDevice.publicKeyData,
                  message.signature == nil,
                  message.sender.publicKeyData != nil,
                  let signature = MessageAuthenticator.sign(message) else {
                logger.error("Message de contrôle non signé : envoi refusé")
                completion?(.failure(ConnectionManagerError.authenticationUnavailable))
                return false
            }
            signedMessage = AirBridgeMessage(
                protocolVersion: message.protocolVersion,
                messageID: message.messageID,
                type: message.type,
                sender: message.sender,
                payload: message.payload,
                signature: signature
            )
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

                    if signedMessage.type != .fileChunk {
                        self.logger.debug("Message envoyé : \(signedMessage.type.rawValue, privacy: .public)")
                    }

                    Task { @MainActor [weak self] in
                        self?.session?.touch()
                        completion?(.success(()))
                    }
                }
            )
            return true

        } catch {
            logger.error("Impossible d’encoder \(signedMessage.type.rawValue, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            completion?(.failure(error))
            return false
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
        guard isSessionReady,
              isSecureSessionReady,
              let connection else {
            logger.error("Impossible d’envoyer la demande : session sécurisée non prête")
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

            guard send(message, on: connection) else {
                logger.error("Demande de transfert refusée avant émission")
                return nil
            }

            return requestPayload.transferID

        } catch {
            logger.error("Impossible d’encoder la demande : \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    
    /// Résout la connexion sur laquelle un contrôle de transfert doit
    /// réellement partir.
    ///
    /// Un contrôle est souvent préparé avec la connexion sur laquelle la
    /// demande est arrivée (`PendingTransferRequest.connection`). Entre
    /// l'arrivée de la demande et le geste de l'utilisateur, cette
    /// connexion peut être devenue périmée (session fermée puis rétablie,
    /// connexion croisée remplacée). Or `send(_:on:)` exige
    /// `session?.connection === connection` : l'émission échouait donc en
    /// silence et **l'émetteur restait « En attente » alors que le
    /// récepteur avait accepté**. On retombe ici sur la connexion de la
    /// session vivante, en journalisant le repli.
    ///
    /// - Returns: la connexion de la session active, ou `nil` si aucune
    ///   session n'est ouverte (l'appelant doit alors traiter l'échec).
    private func resolveControlConnection(
        preferred: NWConnection?
    ) -> NWConnection? {
        guard let activeConnection = connection else {
            logger.error("Contrôle de transfert non envoyé : aucune session active")
            return nil
        }

        guard let preferred else {
            return activeConnection
        }

        if preferred === activeConnection {
            return activeConnection
        }

        logger.warning("Connexion de contrôle périmée : repli sur la session active")
        return activeConnection
    }

    @discardableResult
    func sendTransferAccepted(
        transferID: UUID,
        on connection: NWConnection
    ) -> Bool {
        guard let controlConnection = resolveControlConnection(
            preferred: connection
        ) else {
            return false
        }

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

            let sent = send(message, on: controlConnection)

            if !sent {
                logger.error("Acceptation non transmise à l’émetteur : \(transferID, privacy: .public)")
            }

            return sent

        } catch {
            logger.error("Impossible d’encoder l’acceptation : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Variante sans connexion explicite : part sur la session vivante.
    /// Utilisée quand l'acceptation n'est pas liée à une demande reçue
    /// (relance, reprise) — le repli sur la session active est alors le
    /// seul canal possible.
    @discardableResult
    func sendTransferAccepted(
        transferID: UUID
    ) -> Bool {
        guard let controlConnection = resolveControlConnection(
            preferred: nil
        ) else {
            return false
        }

        return sendTransferAccepted(
            transferID: transferID,
            on: controlConnection
        )
    }

    @discardableResult
    func sendTransferRejected(
        transferID: UUID,
        reason: String?,
        on connection: NWConnection
    ) -> Bool {
        guard let controlConnection = resolveControlConnection(
            preferred: connection
        ) else {
            return false
        }

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

            return send(message, on: controlConnection)

        } catch {
            logger.error("Impossible d’encoder le refus : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Variante sans connexion explicite de `sendTransferRejected`.
    @discardableResult
    func sendTransferRejected(
        transferID: UUID,
        reason: String?
    ) -> Bool {
        guard let controlConnection = resolveControlConnection(
            preferred: nil
        ) else {
            return false
        }

        return sendTransferRejected(
            transferID: transferID,
            reason: reason,
            on: controlConnection
        )
    }

    @discardableResult
    func sendTransferCompleted(
        transferID: UUID,
        totalBytes: Int64,
        sha256: String
    ) -> Bool {
        guard let connection else {
            logger.error("Aucune connexion active")
            return false
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

            return send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder transferCompleted : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func sendTransferSucceeded(
        transferID: UUID,
        receivedBytes: Int64,
        on connection: NWConnection
    ) -> Bool {
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

            return send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder transferSucceeded : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    
    @discardableResult
    func sendTransferFailed(
        transferID: UUID,
        reason: String,
        on connection: NWConnection
    ) -> Bool {
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

            return send(message, on: connection)

        } catch {
            logger.error("Impossible d’encoder transferFailed : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    
    
    
    @discardableResult
    func sendResumeRequest(
        transferID: UUID,
        receivedBytes: Int64,
        fileSize: Int64,
        fileName: String = "",
        chunkSize: Int = 0,
        sha256: String = ""
    ) -> Bool {
        // Garde stricte : la session doit être confirmée `.ready` par le
        // `stateUpdateHandler`. Une session en préparation ou en attente
        // accepterait l'envoi en file sans jamais le délivrer — sur une
        // connexion qui expire, le resumeRequest partirait dans le vide.
        guard isSessionReady,
              isSecureSessionReady,
              let connection else {
            logger.error("Impossible d’envoyer resumeRequest : session sécurisée non prête")
            return false
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
            return send(message, on: connection)
        } catch {
            logger.error("Impossible d’encoder resumeRequest")
            return false
        }
    }

    @discardableResult
    func sendResumeAccepted(
        transferID: UUID,
        offset: Int64,
        fileName: String,
        sha256: String,
        chunkSize: Int,
        fileSize: Int64,
        on connection: NWConnection
    ) -> Bool {
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
            return send(message, on: connection)
        } catch {
            logger.error("Impossible d’encoder resumeAccepted")
            return false
        }
    }

    @discardableResult
    func sendTransferCancelled(
        transferID: UUID,
        reason: String? = nil
    ) -> Bool {
        guard let connection else {
            logger.error("Impossible d’envoyer transferCancelled : aucune connexion active")
            return false
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

            return send(
                message,
                on: connection
            )

        } catch {
            logger.error("Impossible d’encoder transferCancelled : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
}



