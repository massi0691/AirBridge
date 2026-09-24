//
//  AirBridgeCore.swift
//  AirBridge
//
//  Created by massi9106 on 16/07/2026.
//

import Observation
import Network
import UserNotifications
import CryptoKit
import OSLog
internal import UniformTypeIdentifiers

/// Issue d'une tentative de démarrage d'un envoi approuvé par le pair.
///
/// Le démarrage peut échouer **sans** que le transfert soit condamné
/// (session sécurisée pas encore prête, entrée pas encore active dans la
/// file FIFO) : l'appelant doit alors conserver un délai de sécurité.
/// Distinguer explicitement ces issues supprime le blocage historique où
/// un `transferAccepted` annulait le délai d'approbation avant un
/// démarrage qui n'avait finalement jamais lieu — le transfert restait
/// « En attente » pour toujours, sans échec, sans reprise et sans log
/// exploitable.
///
/// `nonisolated` : valeur pure, comparable depuis les tests comme depuis
/// le cœur `@MainActor` (isolation par défaut du projet).
nonisolated enum OutgoingStartOutcome: Equatable {

    /// Le pipeline d'envoi a démarré.
    case started

    /// Le pipeline tournait déjà : rien à faire.
    case alreadyRunning

    /// Le transfert est terminé en échec (source illisible) : il n'est
    /// plus « En attente », aucun filet n'est nécessaire.
    case finishedInError

    /// Démarrage impossible pour l'instant ; un délai de sécurité doit
    /// rester armé.
    case deferred(reason: String)
}

@MainActor
@Observable
final class AirBridgeCore {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "core"
    )

    let bonjourService: BonjourService
    let connectionManager: ConnectionManager
    let messageRouter: MessageRouter
    let transferManager: TransferManager
    let receivedFolderStore: ReceivedFolderStore
    let transferHistoryStore: TransferHistoryStore
    let notificationManager = NotificationManager()

    private let messageCodec = MessageCodec()

    
    
    /// Lot d'autorisation prêt à être présenté à l'utilisateur.
    /// Reste `nil` pendant la fenêtre de coalescence pour qu'une
    /// sélection multiple ne produise qu'une seule demande.
    private(set) var pendingTransferBatch: PendingTransferBatch?

    private let pendingApprovalCoordinator =
        PendingApprovalCoordinator()

    private let outgoingTransferQueue =
        OutgoingTransferQueue()

    private let transferTimeoutManager =
        TransferTimeoutManager()

    let pairingStore: PairingStore
    private var pairingHandshake: PairingHandshake

    /// Challenge en attente pour le handshake de pairage (initiateur).
    /// Clé = peerID, Valeur = challenge envoyé.
    private var pendingPairingChallenges: [UUID: Data] = [:]

    private var outgoingFileHandles: [UUID: FileHandle] = [:]
    private var startedOutgoingTransfers: Set<UUID> = []
    private var approvalRequestsSent: Set<UUID> = []
    private var approvedOutgoingTransfers: Set<UUID> = []
    private var isCleaningUpSession = false

    /// Dernier pair connu, mémorisé pour rattacher les transferts à un
    /// peer même après que la session a été fermée (le `connectedDevice`
    /// vaut alors déjà `nil`).
    private var lastKnownPeerID: UUID?

    /// Reprises automatiques en cours : une seule tâche par transfert,
    /// jamais deux reprises simultanées du même identifiant.
    private var resumeTasks: [UUID: Task<Void, Never>] = [:]

    /// Vrai quand une campagne de reprise est déjà ouverte (des tâches de
    /// backoff tournent). Une seule campagne à la fois : sans ce verrou,
    /// chaque événement de session relancerait un cycle complet — d'où des
    /// `resumeRequest` répétés observés sur le terrain. Le verrou tombe aux
    /// sorties terminales (`endResumeCampaign`) pour qu'une prochaine
    /// session puisse en rouvrir une.
    private var isResumeCampaignActive = false

    // MARK: - Connexion automatique des pairs de confiance

    /// Dernière tentative de connexion automatique par pair.
    ///
    /// Bonjour redéclenche `onDeviceDiscovered` pour TOUS les appareils à
    /// chaque changement du jeu de résultats (et ces changements sont
    /// fréquents : TXT records, interfaces réseau…) : sans anti-rafale,
    /// chaque événement relancerait une tentative de connexion. La fenêtre
    /// est calculée par `AutoConnectPolicy.retryInterval` (backoff
    /// exponentiel plafonné, croissant avec `autoConnectFailureCounts`).
    private var lastAutoConnectAttempts: [UUID: Date] = [:]

    /// Échecs de session consécutifs (jamais de session sécurisée
    /// établie) par pair, depuis le dernier succès. Alimente le backoff
    /// d'`AutoConnectPolicy` : 15 s puis 30 s, 60 s, 120 s, 240 s.
    /// Remis à zéro dès qu'une session sécurisée aboutit vers ce pair.
    private var autoConnectFailureCounts: [UUID: Int] = [:]

    /// Pairs dont la connexion automatique est suspendue suite à une
    /// déconnexion EXPLICITE de l'utilisateur. La suspension est levée
    /// quand le pair quitte le réseau (il disparaît de la découverte) puis
    /// y revient, ou quand l'utilisateur se reconnecte manuellement —
    /// une déconnexion volontaire ne doit jamais être immédiatement
    /// annulée par la redécouverte, mais elle ne doit pas non plus être
    /// définitive.
    private var autoConnectSuppressedPeers: Set<UUID> = []

    /// Pairs vus au dernier événement de découverte. Permet de détecter
    /// les sorties du réseau (pair absent du nouveau jeu de résultats)
    /// pour lever la suspension de connexion automatique à son retour.
    private var previouslyDiscoveredPeerIDs: Set<UUID> = []

    // MARK: - Dernier appareil connecté (partagé avec l'extension Finder)

    /// Dernier pair avec lequel une session a existé, conservé après
    /// déconnexion. Publié dans l'App Group pour que l'extension Finder
    /// puisse proposer « Envoyer à <dernier appareil> » (l'extension est
    /// un processus séparé, sans accès au socket de l'app).
    private(set) var lastConnectedDevice: Device?

    // MARK: - Envoi ciblé programmé (« Envoyer à <X> »)

    /// Envoi demandé explicitement pour un pair qui n'est pas encore
    /// connecté : il partira automatiquement dès que la session avec ce
    /// pair exact devient sécurisée (auto-connexion, redécouverte…),
    /// dans la limite de `targetedSendLifetime`.
    private struct ScheduledTargetedSend {
        let recipientID: UUID
        let urls: [URL]
        let issuedAt: Date
    }

    private var scheduledTargetedSend: ScheduledTargetedSend?

    /// Nom du destinataire de l'envoi programmé — exposé pour l'UI
    /// (bandeau « Connexion à X en cours — envoi automatique… »).
    private(set) var scheduledTargetedSendPeerName: String?

    /// Durée de validité d'un envoi ciblé programmé (secondes). Passé ce
    /// délai sans session sécurisée avec le bon pair, l'envoi est
    /// abandonné et les fichiers restent dans la feuille d'envoi.
    private static let targetedSendLifetime: TimeInterval = 120

    /// Émis quand un envoi ciblé programmé est soldé :
    /// `(peerID, succès)` — `succès == true` signifie que le Core a
    /// importé les fichiers dans sa file sortante.
    var onTargetedSendFinished: ((UUID, Bool) -> Void)?

    /// Vrai une fois la session *sécurisée* (ECDH/HKDF aboutis) de la
    /// session courante — distingue un échec de connexion (à compter
    /// pour le backoff) d'une session ouverte puis fermée normalement.
    private var currentSessionDidReachSecureReady = false

    // MARK: - Délais de sécurité (jamais d'attente infinie)

    /// Délai accordé à un envoi **accepté par le pair** mais dont le
    /// démarrage a été reporté (session sécurisée pas prête, pair changé).
    /// Au-delà, une dernière tentative est faite puis le transfert échoue
    /// avec un motif explicite et le pair est prévenu.
    ///
    /// Court volontairement : à ce stade le destinataire a déjà dit oui,
    /// l'utilisateur attend un démarrage immédiat, pas les 300 s du délai
    /// d'approbation.
    private static let acceptedStartGracePeriod: Duration = .seconds(20)

    /// Délai accordé à l'annonce d'un envoi (`transferRequest`) quand elle
    /// est reportée (session sécurisée non prête, pairage non enregistré).
    /// Sans lui, un transfert pouvait rester « Préparation » indéfiniment
    /// sans jamais échouer ni prévenir l'utilisateur.
    private static let announcementGracePeriod: Duration = .seconds(30)


    init(
        bonjourService: BonjourService,
        connectionManager: ConnectionManager,
        messageRouter: MessageRouter,
        transferManager: TransferManager,
        receivedFolderStore: ReceivedFolderStore,
        transferHistoryStore: TransferHistoryStore,
        pairingStore: PairingStore
    ) {
        self.bonjourService = bonjourService
        self.connectionManager = connectionManager
        self.messageRouter = messageRouter
        self.transferManager = transferManager
        self.receivedFolderStore = receivedFolderStore
        self.transferHistoryStore = transferHistoryStore
        self.pairingStore = pairingStore
        self.pairingHandshake = PairingHandshake(pairingStore: pairingStore)

        configureBindings()
    }
    
    
    private func activateOutgoingTransfer(
        _ entry: OutgoingTransferQueue.Entry
    ) {
        guard outgoingTransferQueue.isActive(entry.id) else {
            return
        }

        sendApprovalRequestIfNeeded(for: entry)

        guard approvedOutgoingTransfers.contains(entry.id) else {
            return
        }

        // L'entrée a pu être acceptée par le pair pendant qu'elle attendait
        // son tour dans la file FIFO. Si son démarrage est maintenant
        // reporté (session sécurisée retombée, pair changé), un délai doit
        // être armé ici aussi : sans lui, plus aucun filet ne couvre cette
        // entrée et elle reste « Accepté » sans jamais démarrer.
        switch beginOutgoingTransfer(entry) {
        case .started, .alreadyRunning, .finishedInError:
            break

        case .deferred(let reason):
            logger.warning(
                "Activation d’un envoi déjà accepté mais démarrage reporté : \(reason, privacy: .public)"
            )
            armAcceptedStartTimeout(
                transferID: entry.id,
                reason: reason
            )
        }
    }

    /// Envoie l'annonce de transfert (`transferRequest`) d'une entrée, si
    /// les conditions de session et de pairage sont réunies.
    ///
    /// - Parameter allowDeferralTimeout: arme un délai borné quand
    ///   l'annonce est reportée. À `false` pour la relance effectuée depuis
    ///   ce même délai (sinon le report se réarmerait indéfiniment et le
    ///   transfert n'échouerait jamais).
    private func sendApprovalRequestIfNeeded(
        for entry: OutgoingTransferQueue.Entry,
        allowDeferralTimeout: Bool = true
    ) {
        // La queue peut être activée dès la connexion TCP, avant l'ECDH.
        // Attendre ici plutôt que transformer cette attente normale en
        // échec terminal ; `installSessionKeyAndMarkReady` réessaiera
        // l'entrée active après le handshake. L'attente reste bornée : sans
        // délai, un handshake qui n'aboutit pas laissait le transfert
        // « Préparation » pour toujours.
        guard connectionManager.isSecureSessionReady,
              connectionManager.connectedDevice?.id == entry.peer.id else {
            logger.info("Demande de transfert reportée : session sécurisée non prête")
            if allowDeferralTimeout {
                armAnnouncementTimeout(
                    transferID: entry.id,
                    reason: "session sécurisée non prête"
                )
            }
            return
        }

        guard !approvalRequestsSent.contains(entry.id) else {
            return
        }

        // Barrière de pairage.
        //
        // `transferRequest` est le seul contrôle sensible qu'un pair encore
        // inconnu peut recevoir (`AuthenticationPolicy` l'autorise avant
        // pairage), mais la réponse du destinataire — `transferAccepted` —
        // exige, elle, une clé déjà enregistrée dans le `PairingStore`.
        // Annoncer un transfert avant la fin du pairage produisait donc
        // exactement le blocage observé : le destinataire accepte, son
        // acceptation est écartée à la réception (signature invérifiable
        // faute de clé persistée), et l'émetteur reste « En attente ».
        //
        // On attend donc que le pair soit enregistré —
        // `retryDeferredApprovalRequests()` rejoue l'annonce dès que le
        // pairage aboutit — et on relance le pairage si rien n'est en vol.
        guard pairingStore.pairing(for: entry.peer.id) != nil else {
            logger.info("Demande de transfert reportée : pairage non enregistré pour \(entry.peer.name, privacy: .public)")
            restartPairingIfNeeded(for: entry.peer)
            if allowDeferralTimeout {
                armAnnouncementTimeout(
                    transferID: entry.id,
                    reason: "pairage non enregistré"
                )
            }
            return
        }

        transferManager.markWaitingForApproval(
            transferID: entry.id
        )

        guard let transferID = connectionManager.sendTransferRequest(
            transferID: entry.id,
            fileName: entry.fileName,
            fileSize: entry.fileSize,
            contentType: entry.contentType,
            batchID: entry.batchID,
            batchFolderName: entry.batchFolderName,
            relativePath: entry.relativePath
        ), transferID == entry.id else {
            failOutgoingTransfer(
                transferID: entry.id,
                reason: "Impossible d’envoyer la demande de transfert",
                notifyPeer: false
            )
            return
        }

        approvalRequestsSent.insert(entry.id)
        transferTimeoutManager.start(
            transferID: entry.id,
            kind: .approval,
            duration: .seconds(300)
        ) { [weak self] in
            guard let self else {
                return
            }

            logger.warning(
                "Délai d’acceptation dépassé : \(entry.id, privacy: .public)"
            )

            self.failOutgoingTransfer(
                transferID: entry.id,
                reason: "Délai d’acceptation dépassé",
                notifyPeer: true
            )
        }
    }

    /// Arme le délai borné d'une annonce reportée (session sécurisée non
    /// prête, pairage non enregistré).
    ///
    /// À l'échéance, une dernière tentative d'annonce est faite sans
    /// réarmer de délai ; si elle n'aboutit toujours pas, le transfert
    /// échoue avec un motif explicite plutôt que de rester « Préparation »
    /// indéfiniment.
    private func armAnnouncementTimeout(
        transferID: UUID,
        reason: String
    ) {
        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        transferTimeoutManager.start(
            transferID: transferID,
            kind: .approval,
            duration: Self.announcementGracePeriod
        ) { [weak self] in
            guard let self else {
                return
            }

            if let entry = self.outgoingTransferQueue.allEntries.first(where: {
                $0.id == transferID
            }) {
                self.sendApprovalRequestIfNeeded(
                    for: entry,
                    allowDeferralTimeout: false
                )

                if self.approvalRequestsSent.contains(transferID) {
                    self.logger.info("Annonce finalement transmise après relance : \(transferID, privacy: .public)")
                    return
                }
            }

            self.logger.error("Annonce de transfert impossible (\(reason, privacy: .public)) : échec du transfert \(transferID, privacy: .public)")

            self.failOutgoingTransfer(
                transferID: transferID,
                reason: "Transfert impossible : \(reason)",
                notifyPeer: false
            )
        }
    }

    /// Relance le pairage quand aucune demande n'est déjà en vol.
    ///
    /// C'est la seule sortie d'une annonce bloquée sur un pair jamais
    /// enregistré : sans elle, l'émetteur attendait une clé que personne ne
    /// venait lui donner.
    private func restartPairingIfNeeded(
        for peer: Device
    ) {
        guard pendingPairingChallenges[peer.id] == nil else {
            return
        }

        guard pairingStore.trustState(for: peer.id) != .blocked else {
            logger.warning("Pairage non relancé : \(peer.name, privacy: .public) est bloqué")
            return
        }

        guard let connection = connectionManager.session?.connection else {
            logger.info("Pairage non relancé : aucune session active")
            return
        }

        logger.info("Relance du pairage avec \(peer.name, privacy: .public)")
        initiatePairing(with: peer, on: connection)
    }

    /// Rejoue les annonces reportées de toutes les entrées de la file.
    ///
    /// Appelé quand un verrou saute (session sécurisée prête, pairage
    /// enregistré) : sans ce rappel, seules l'entrée active était retentée
    /// et les fichiers d'un lot pouvaient rester « Préparation » alors que
    /// la voie était libre.
    private func retryDeferredApprovalRequests() {
        let pendingEntries = outgoingTransferQueue.allEntries.filter {
            !approvalRequestsSent.contains($0.id)
        }

        guard !pendingEntries.isEmpty else {
            return
        }

        logger.info("Relance de \(pendingEntries.count) annonce(s) reportée(s)")

        for entry in pendingEntries {
            sendApprovalRequestIfNeeded(for: entry)
        }
    }

    /// Démarre un envoi approuvé par le pair.
    ///
    /// - Returns: l'issue de la tentative. `.deferred` signifie « pas
    ///   encore possible » : l'appelant DOIT conserver un délai de
    ///   sécurité, sinon le transfert reste « En attente » sans aucune
    ///   issue (ni échec, ni reprise) — c'était le blocage historique de
    ///   ce chemin, toutes les gardes échouant en silence.
    /// Le résultat n'est volontairement pas `@discardableResult` : un
    /// appelant qui l'ignore réintroduit le blocage historique (démarrage
    /// reporté sans délai, donc attente infinie).
    private func beginOutgoingTransfer(
        _ entry: OutgoingTransferQueue.Entry
    ) -> OutgoingStartOutcome {
        guard connectionManager.isSecureSessionReady else {
            logger.info("Démarrage reporté : session sécurisée non prête — \(entry.fileName, privacy: .public)")
            return .deferred(reason: "session sécurisée non prête")
        }

        guard connectionManager.connectedDevice?.id == entry.peer.id else {
            logger.info("Démarrage reporté : le pair connecté n’est plus \(entry.peer.name, privacy: .public)")
            return .deferred(reason: "l’appareil connecté n’est plus le destinataire")
        }

        guard outgoingTransferQueue.isActive(entry.id) else {
            logger.info("Démarrage différé : entrée non active dans la file — \(entry.fileName, privacy: .public)")
            return .deferred(reason: "entrée en attente dans la file d’envoi")
        }

        guard approvedOutgoingTransfers.contains(entry.id) else {
            logger.info("Démarrage différé : acceptation du pair non enregistrée — \(entry.fileName, privacy: .public)")
            return .deferred(reason: "acceptation du destinataire non enregistrée")
        }

        guard startedOutgoingTransfers.insert(entry.id).inserted else {
            logger.info("Démarrage ignoré : le pipeline tourne déjà — \(entry.fileName, privacy: .public)")
            return .alreadyRunning
        }

        do {
            let fileURL = try transferManager.outgoingFileURL(
                transferID: entry.id
            )

            transferTimeoutManager.cancel(
                transferID: entry.id
            )
            transferManager.markAccepted(
                transferID: entry.id
            )
            restartTransferActivityTimeout(
                transferID: entry.id
            )
            sendFileChunks(
                transferID: entry.id,
                fileURL: fileURL
            )

            return .started
        } catch {
            startedOutgoingTransfers.remove(entry.id)
            transferManager.markFailed(
                transferID: entry.id,
                reason: "Source du transfert introuvable"
            )
            finishOutgoingTransfer(
                transferID: entry.id
            )

            return .finishedInError
        }
    }

    /// Filet de sécurité d'un envoi accepté par le pair mais dont le
    /// démarrage a été reporté.
    ///
    /// À l'échéance, une dernière tentative de démarrage est faite (la
    /// session sécurisée a pu revenir entre-temps). Si elle échoue encore,
    /// le transfert passe en échec avec un motif explicite **et le pair est
    /// prévenu** : les deux appareils convergent au lieu de rester chacun
    /// sur un état contradictoire (« En attente » ici, « Accepté » là-bas).
    private func armAcceptedStartTimeout(
        transferID: UUID,
        reason: String
    ) {
        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        transferTimeoutManager.start(
            transferID: transferID,
            kind: .approval,
            duration: Self.acceptedStartGracePeriod
        ) { [weak self] in
            guard let self else {
                return
            }

            if let entry = self.outgoingTransferQueue.allEntries.first(where: {
                $0.id == transferID
            }) {
                switch self.beginOutgoingTransfer(entry) {
                case .started, .alreadyRunning, .finishedInError:
                    self.transferTimeoutManager.cancel(
                        transferID: transferID
                    )
                    self.logger.info("Démarrage réussi après relance : \(transferID, privacy: .public)")
                    return

                case .deferred(let retryReason):
                    self.logger.error("Démarrage toujours impossible : \(retryReason, privacy: .public)")
                }
            }

            self.failOutgoingTransfer(
                transferID: transferID,
                reason: "Transfert accepté par le destinataire mais démarrage impossible (\(reason))",
                notifyPeer: true
            )
        }
    }

    /// Sort un envoi approuvé dont l'entrée a disparu de la file (coupure,
    /// annulation locale, nettoyage de session) : il ne peut plus démarrer,
    /// donc il ne doit plus apparaître comme « En attente ».
    ///
    /// `.interrupted` (et non `.failed`) : rien n'a été envoyé, la source
    /// est toujours là, et la reprise automatique le proposera au retour du
    /// pair.
    private func recoverOrphanedApprovedTransfer(
        transferID: UUID
    ) {
        guard !transferManager.isTerminal(transferID: transferID) else {
            return
        }

        let transferredBytes = transferManager.transfers
            .first { $0.id == transferID }?
            .transferredBytes ?? 0

        transferManager.markInterrupted(
            transferID: transferID,
            transferredBytes: transferredBytes,
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        startedOutgoingTransfers.remove(transferID)
        approvalRequestsSent.remove(transferID)

        logger.warning("Acceptation reçue pour un envoi absent de la file — marqué interrompu (reprisable) : \(transferID, privacy: .public)")
    }

    private func failOutgoingTransfer(
        transferID: UUID,
        reason: String,
        notifyPeer: Bool
    ) {
        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        if notifyPeer {
            connectionManager.sendTransferCancelled(
                transferID: transferID,
                reason: reason
            )
        }

        // Le motif est conservé sur le transfert (`errorMessage`) et pas
        // seulement envoyé au pair : un échec de démarrage doit rester
        // explicable après coup, y compris dans les traces et l'historique.
        transferManager.markFailed(
            transferID: transferID,
            reason: reason
        )

        finishOutgoingTransfer(
            transferID: transferID
        )
    }

    private func restartTransferActivityTimeout(
        transferID: UUID
    ) {
        transferTimeoutManager.start(
            transferID: transferID,
            kind: .transferActivity,
            duration: .seconds(30)
        ) { [weak self] in
            guard let self else {
                return
            }

            logger.warning(
                "Délai d’activité dépassé : \(transferID, privacy: .public)"
            )

            // Décision métier : un timeout d'activité signale une liaison
            // silencieuse, pas un refus du pair. Si la session est encore
            // vivante, le transfert passe à `.interrupted` (récupérable par
            // reprise) au lieu de `.failed` (terminal). Hors session, le
            // handler de déconnexion a déjà interrompu le transfert : on ne
            // fait qu'un nettoyage terminal classique, sans notifier un pair
            // qui n'est plus joignable.
            //
            // Le chemin diffère selon la direction : côté réception,
            // `interruptOutgoingTransfer` retournait immédiatement (l'entrée
            // n'est pas dans la file sortante), donc un récepteur dont
            // l'émetteur se taisait restait figé « En cours » sans issue.
            let isIncoming = self.transferManager.transfers
                .first { $0.id == transferID }?
                .direction == .incoming

            if isIncoming {
                self.interruptStalledIncomingTransfer(transferID: transferID)
                return
            }

            guard self.connectionManager.session != nil else {
                // Liaison déjà perdue mais session pas encore fermée :
                // même politique que la coupure réseau, jamais `.failed`.
                logger.info("Timeout d'activité hors session : interruption récupérable")
                self.interruptOutgoingTransfer(transferID: transferID)
                return
            }

            self.interruptOutgoingTransfer(transferID: transferID)
        }
    }

    /// Fait passer une réception silencieuse à `.interrupted`.
    ///
    /// Le writer est fermé en conservant le `.partial`, et la métadonnée de
    /// reprise est persistée : la reprise (manuelle ou automatique au retour
    /// du pair) continue au lieu de repartir de zéro. Sans ce chemin, le
    /// délai d'activité armé à chaque morceau reçu n'avait aucun effet côté
    /// réception (`interruptOutgoingTransfer` retourne immédiatement quand
    /// l'entrée n'est pas dans la file sortante) : un récepteur dont
    /// l'émetteur se taisait restait figé « En cours » pour toujours.
    private func interruptStalledIncomingTransfer(
        transferID: UUID
    ) {
        transferTimeoutManager.cancel(
            transferID: transferID
        )

        // Ferme le writer, conserve le `.partial`, marque `.interrupted`.
        transferManager.interruptIncomingTransfer(
            transferID: transferID
        )

        // Persiste la métadonnée de reprise (offset = taille réelle du
        // `.partial`) pour une reprise après redémarrage.
        transferManager.markInterrupted(
            transferID: transferID,
            transferredBytes: transferManager.incomingPartialFileBytes(
                transferID: transferID
            ),
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        logger.warning("Réception interrompue : plus aucun morceau reçu — \(transferID, privacy: .public)")
    }

    /// Fait passer un envoi actif à `.interrupted` : progression conservée,
    /// handle fermé, entrée retirée de la file FIFO pour libérer le suivant,
    /// mais source sortante préservée — c'est elle qui porte l'offset déjà
    /// envoyé et servira de point de départ à la reprise.
    private func interruptOutgoingTransfer(transferID: UUID) {
        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        transferTimeoutManager.cancel(transferID: transferID)

        if let fileHandle = outgoingFileHandles.removeValue(
            forKey: transferID
        ) {
            try? fileHandle.close()
        }

        let transferredBytes = transferManager.transfers
            .first { $0.id == transferID }?
            .transferredBytes ?? 0

        transferManager.markInterrupted(
            transferID: transferID,
            transferredBytes: transferredBytes,
            protocolVersion: ProtocolCompatibility.currentVersion
        )

        // Retire l'entrée de la file (et active la suivante) sans toucher
        // à la source : `cleanupOutgoingTransfer` la supprimerait.
        _ = outgoingTransferQueue.cancel(transferID: transferID)

        startedOutgoingTransfers.remove(transferID)
    }

    @discardableResult
    private func finishOutgoingTransfer(
        transferID: UUID
    ) -> Bool {
        guard let entry = outgoingTransferQueue.allEntries.first(where: {
            $0.id == transferID
        }) else {
            startedOutgoingTransfers.remove(transferID)
            approvalRequestsSent.remove(transferID)
            approvedOutgoingTransfers.remove(transferID)
            return false
        }

        transferTimeoutManager.cancel(
            transferID: transferID
        )

        if let fileHandle = outgoingFileHandles.removeValue(
            forKey: transferID
        ) {
            try? fileHandle.close()
        }

        transferManager.cleanupOutgoingTransfer(
            transferID: transferID
        )

        guard outgoingTransferQueue.finish(transferID: transferID) else {
            return false
        }

        startedOutgoingTransfers.remove(transferID)
        approvalRequestsSent.remove(transferID)
        approvedOutgoingTransfers.remove(transferID)

        if entry.sourceFileURL != entry.fileURL {
            logger.info(
                "Fichier original conservé : \(entry.sourceFileURL.lastPathComponent, privacy: .public)"
            )
        }

        return true
    }

    func requestTransfer(
        fileURL: URL,
        sourceFileURL: URL,
        isTemporarySource: Bool = false
    ) {
        guard let peer = connectionManager.connectedDevice else {
            logger.error("Aucun appareil connecté")
            return
        }

        do {
            let resourceValues = try fileURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .contentTypeKey
                ]
            )

            guard let fileSize = resourceValues.fileSize else {
                logger.error("Impossible de lire la taille du fichier")
                return
            }

            let entry = OutgoingTransferQueue.Entry(
                peer: peer,
                fileName: fileURL.lastPathComponent,
                fileSize: Int64(fileSize),
                contentType: resourceValues.contentType?.preferredMIMEType,
                fileURL: fileURL,
                sourceFileURL: sourceFileURL
            )

            transferManager.createOutgoingTransfer(
                id: entry.id,
                peer: entry.peer,
                fileName: entry.fileName,
                fileSize: entry.fileSize,
                state: .requesting
            )

            transferManager.setSourceFileURL(
                transferID: entry.id,
                url: entry.sourceFileURL
            )

            transferManager.registerOutgoingSource(
                transferID: entry.id,
                fileURL: entry.fileURL,
                originalFileURL: sourceFileURL,
                isTemporary: isTemporarySource
            )

            if isCleaningUpSession,
               outgoingTransferQueue.allEntries.isEmpty {
                isCleaningUpSession = false
                startedOutgoingTransfers.removeAll()
            }

            outgoingTransferQueue.enqueue(entry)

            logger.info(
                "Transfert ajouté à la file : \(entry.fileName, privacy: .public)"
            )

        } catch {
            logger.error(
                "Impossible de préparer le fichier : \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func requestTransferEntries(
        _ entries: [OutgoingTransferQueue.Entry],
        batchID: UUID
    ) {
        for entry in entries {
            transferManager.createOutgoingTransfer(
                id: entry.id,
                peer: entry.peer,
                fileName: entry.fileName,
                fileSize: entry.fileSize,
                state: .requesting
            )
            // Tous les fichiers d'une même sélection partagent le lot :
            // l'aperçu des transferts terminés peut alors les présenter
            // comme un seul dossier.
            transferManager.setBatchID(
                transferID: entry.id,
                batchID: batchID
            )
            transferManager.setSourceFileURL(
                transferID: entry.id,
                url: entry.sourceFileURL
            )
            transferManager.registerOutgoingSource(
                transferID: entry.id,
                fileURL: entry.fileURL,
                originalFileURL: entry.sourceFileURL,
                isTemporary: true
            )
        }

        if isCleaningUpSession,
           outgoingTransferQueue.allEntries.isEmpty {
            isCleaningUpSession = false
            startedOutgoingTransfers.removeAll()
        }

        entries.forEach(outgoingTransferQueue.enqueue)
    }

    /// Envoie une sélection de l'utilisateur : des fichiers, des dossiers,
    /// ou les deux mélangés.
    ///
    /// Point d'entrée unique des sélecteurs et du dépôt. La sélection est
    /// répartie en lots — les fichiers isolés ensemble, chaque dossier à
    /// part — et chaque lot part avec son propre identifiant, donc son
    /// propre sous-dossier à l'arrivée.
    /// - Returns: `true` si au moins une entrée a été créée et mise en
    ///   file (les fichiers ont été copiés dans le temporaire du Core et
    ///   la sélection est donc consommée) ; `false` si rien n'a été
    ///   importé — aucun appareil connecté, sélection vide, ou échec de
    ///   copie. Le retour permet à l'appelant de savoir s'il peut
    ///   nettoyer une source temporaire (batch App Group du share
    ///   extension) sans perdre une sélection non consommée.
    @discardableResult
    func importAndRequestItems(
        urls: [URL]
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        guard connectionManager.connectedDevice != nil else {
            logger.error("Aucun appareil connecté")
            return false
        }

        // Un envoi ciblé programmé portant sur (au moins) un des mêmes
        // fichiers est obsolète : l'envoi explicite en cours le remplace.
        // Sans cette annulation, le lot partait une seconde fois quand
        // la programmation trouvait sa session plus tard.
        if let pending = scheduledTargetedSend,
           !Set(pending.urls).isDisjoint(with: urls) {
            scheduledTargetedSend = nil
            scheduledTargetedSendPeerName = nil
            logger.info(
                "Envoi ciblé programmé annulé : remplacé par un envoi explicite"
            )
        }

        let plans = OutgoingSelectionPlanner.plans(for: urls)

        guard !plans.isEmpty else {
            logger.info("Sélection sans fichier à envoyer")
            return false
        }

        var importedAny = false
        for plan in plans {
            importedAny = requestTransfers(for: plan) || importedAny
        }
        return importedAny
    }

    /// Prépare les fichiers d'un lot puis les met en file.
    ///
    /// L'accès au dossier choisi est tenu pendant toute la préparation :
    /// le système l'accorde au dossier et non à ses fichiers, donc le
    /// relâcher entre deux copies rendrait les suivantes illisibles.
    /// - Returns: `true` si au moins une entrée a été préparée (copie
    ///   réussie vers le temporaire du Core) et mise en file.
    @discardableResult
    private func requestTransfers(
        for plan: OutgoingSelectionPlan
    ) -> Bool {
        let folderAccess =
            plan.folderURL?.startAccessingSecurityScopedResource()
                ?? false

        defer {
            if folderAccess, let folderURL = plan.folderURL {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        var entries = plan.files.compactMap {
            makeEntry(for: $0, in: plan)
        }

        guard !entries.isEmpty else {
            logger.error("Aucun fichier exploitable dans la sélection")
            return false
        }

        let batchID = UUID()

        // Le lot n'est annoncé au récepteur que s'il en est vraiment un :
        // un dossier toujours, une sélection de fichiers à partir de deux.
        // Un fichier isolé reste ainsi à plat dans le dossier de réception,
        // et le récepteur n'a rien à compter pour le savoir.
        if plan.announcesBatch {

            for index in entries.indices {
                entries[index].batchID = batchID
            }
        }

        requestTransferEntries(entries, batchID: batchID)
        sendApprovalRequests(for: entries)
        return true
    }

    /// Copie un fichier vers le conteneur de l'app et décrit l'envoi.
    ///
    /// La copie protège l'original : le transfert lit ensuite sa propre
    /// copie, donc l'utilisateur peut déplacer ou modifier son fichier sans
    /// casser l'envoi en cours.
    private func makeEntry(
        for file: OutgoingSelectionPlan.File,
        in plan: OutgoingSelectionPlan
    ) -> OutgoingTransferQueue.Entry? {

        let fileURL = file.url
        let fileManager = FileManager.default

        // Utile pour un fichier isolé, à qui l'accès est accordé
        // directement. Sans effet pour l'enfant d'un dossier, dont l'accès
        // est déjà tenu par l'appelant.
        let hasAccess =
            fileURL.startAccessingSecurityScopedResource()

        defer {
            if hasAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let localURL = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "\(UUID().uuidString)-\(fileURL.lastPathComponent)"
                )

            try fileManager.copyItem(at: fileURL, to: localURL)

            let values = try localURL.resourceValues(
                forKeys: [.fileSizeKey, .contentTypeKey]
            )

            guard let fileSize = values.fileSize else {
                throw CocoaError(.fileReadUnknown)
            }

            guard let peer = connectionManager.connectedDevice else {
                return nil
            }

            return OutgoingTransferQueue.Entry(
                peer: peer,
                fileName: fileURL.lastPathComponent,
                fileSize: Int64(fileSize),
                contentType: values.contentType?.preferredMIMEType,
                fileURL: localURL,
                sourceFileURL: fileURL,
                batchFolderName: plan.folderName,
                relativePath: file.relativePath
            )

        } catch {
            logger.error(
                "Impossible d’importer \(fileURL.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func importAndRequestTransfers(
        fileURLs: [URL]
    ) {
        importAndRequestItems(urls: fileURLs)
    }

    func importAndRequestTransfer(
        fileURL: URL
    ) {
        importAndRequestItems(urls: [fileURL])
    }

    private func sendApprovalRequests(
        for entries: [OutgoingTransferQueue.Entry]
    ) {
        for entry in entries {
            sendApprovalRequestIfNeeded(for: entry)
        }
    }

    /// `chunkSize` est décidé une fois pour tout le transfert, puis passé de
    /// morceau en morceau : le découpage doit rester régulier même si le
    /// fichier change de taille sous nos pieds.
    ///
    /// Durée de la dernière lecture disque, consommée par l'instrumentation
    /// de performance (`TransferPerformanceLog`) via le chemin d'envoi.
    private var lastReadDuration: Double = 0

    private func sendNextChunk(
        transferID: UUID,
        fileHandle: FileHandle,
        fileSHA256: String,
        offset: Int64,
        chunkSize: Int,
        performanceMode: String? = nil,
        expectedTotalSize: Int64? = nil
    ) {
        // Wrapper de compatibilité : délègue au pipeline async.
        // Conserve la signature d'origine pour les appels existants
        // (reprise, tests) tout en bénéficiant des performances du
        // nouveau chemin (lecture disque + chiffrement off main thread,
        // envois concurrents).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runChunkPipeline(
                    transferID: transferID,
                    fileHandle: fileHandle,
                    fileSHA256: fileSHA256,
                    offset: offset,
                    chunkSize: chunkSize,
                    performanceMode: performanceMode,
                    expectedTotalSize: expectedTotalSize
                )
            } catch {
                // `runChunkPipeline` a déjà fait le ménage (fermeture du
                // handle, marquage échec/interruption). En cas d'erreur
                // non gérée, on s'assure au minimum que la queue est
                // nettoyée.
                self.outgoingFileHandles.removeValue(forKey: transferID)
                try? fileHandle.close()
                logger.error("Pipeline d'envoi : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pipeline d'envoi async.
    ///
    /// Remplace la récursion par complétion synchrone de
    /// `sendNextChunk`. Les bénéfices principaux :
    /// 1. **Lecture disque off main thread** : `FileHandle.read` est
    ///    appelé depuis une `Task.detached`, ce qui libère le `@MainActor`
    ///    pour le décodage entrant.
    /// 2. **Pas de saut `@MainActor` par chunk** : l'envoi passe par
    ///    `OutgoingTransferManager.sendChunkAsync`, qui utilise un
    ///    `CheckedContinuation` et reste hors MainActor entre chaque
    ///    chunk.
    /// 3. **Fenêtre en vol bornée** : jusqu'à `pipelineDepth = 4`
    ///    chunks peuvent être en transit simultanément. Le décodage
    ///    du chunk N+1 commence pendant que N est encore en transit,
    ///    masquant la latence du disque et du réseau.
    /// 4. **Ordre strict préservé** : bien que plusieurs chunks
    ///    puissent être en vol, l'incrément de `totalBytesSentCount`
    ///    et la mise à jour de `lastOffsetConsumed` sont sérialisés
    ///    par un `OrderedAckPump` qui ne libère les compteurs que
    ///    dans l'ordre d'émission (offset croissant). Le récepteur
    ///    peut donc traiter les chunks dans l'ordre d'arrivée sans
    ///    risque de réordonnancement côté émetteur.
    private func runChunkPipeline(
        transferID: UUID,
        fileHandle: FileHandle,
        fileSHA256: String,
        offset: Int64,
        chunkSize: Int,
        performanceMode: String?,
        expectedTotalSize: Int64? = nil
    ) async throws {

        if let performanceMode {
            TransferPerformanceLog.begin(
                transferID: transferID,
                mode: performanceMode,
                chunkSize: chunkSize
            )
        }

        let currentOffset = offset

        // Fenêtre en vol bornée à `pipelineDepth = 4` chunks. Le
        // compromis mémoire/débit :
        // - À 1 chunk en vol (l'ancien comportement séquentiel), le
        //   débit plafonne autour de 7 Mo/s : chaque chunk attend
        //   son acquittement avant que le suivant ne soit émis, ce
        //   qui sous-utilise la fenêtre TCP sur réseau local.
        // - À 4 chunks en vol, on masque la latence d'un aller-retour
        //   (~1 ms sur réseau local) tout en restant sous le seuil
        //   d'accumulation mémoire côté récepteur (4 × 2 Mio = 8 Mio
        //   en vol maximum, ce qui tient dans le buffer NWConnection).
        // - Au-delà de 4, les benchmarks sur réseau local Gigabit
        //   ne montrent pas de gain de débit mesurable mais
        //   continuent à accroître la mémoire réceptrice et la
        //   pression sur le réordonnancement.
        //
        // L'ordre reste strict grâce à `OrderedAckPump` (défini plus
        // bas) : le chunk N+1 peut être *en vol* en même temps que N,
        // mais son compteur d'octets ne s'incrémente qu'après
        // l'acquittement de N, et donc toujours dans l'ordre
        // d'émission. La back-pressure est effective via le sémaphore
        // `PipelineWindow` : le producteur attend qu'un slot se
        // libère avant d'émettre le chunk suivant.
        let pipelineDepth = 4

        // Batching des updates UI de progression. Avant le refactor,
        // chaque chunk acquitté franchissait `MainActor.run` pour
        // pousser `updateProgress` + `restartTransferActivityTimeout`,
        // ce qui sérialisait le pipeline sur le main thread (~1 ms
        // par chunk → ~4 chunks/s → ~8 Mo/s sur chunks de 2 Mio).
        //
        // À `uiBatchStride = 8`, on ne traverse le MainActor qu'une
        // fois tous les 8 chunks (16 Mio) — soit ~30 updates/s sur un
        // transfert à 100 Mo/s, imperceptible pour l'œil humain.
        // La progression n'est jamais en retard de plus de 16 Mio.
        // Le dernier chunk force toujours la mise à jour pour garantir
        // `progress == 100%` au moment de la finalisation.
        let uiBatchStride = 8

        // Channel producteur/consommateur entre la lecture disque
        // (détachée) et la boucle d'envoi. Politique de buffering
        // par défaut (`.unbounded`) : la back-pressure est désormais
        // imposée par le sémaphore `PipelineWindow` (le producteur
        // attend un slot libre avant de yield), donc un buffer borné
        // serait à la fois inutile et dangereux.
        //
        // Bug historique : la politique `.bufferingNewest(pipelineDepth)`
        // utilisée ici écrasait silencieusement les chunks les plus
        // récents quand le buffer interne de l'`AsyncStream` était
        // plein, ce qui faisait perdre la majorité d'un fichier dès
        // que le nombre de chunks dépassait `pipelineDepth`. Sur un
        // fichier de 736 Mo / 2 Mio par chunk = 369 chunks avec
        // `pipelineDepth = 4`, le récepteur ne recevait que quelques
        // chunks épars (les derniers ajoutés avant que le producteur
        // ne soit drainé).
        let (readStream, readContinuation) = AsyncStream<
            PipelineChunk
        >.makeStream()

        // 1. Producteur de chunks : lit le fichier off main thread.
        let readerTask = Task.detached(
            priority: .userInitiated
        ) { [chunkSize, transferID] in
            var fileOffset = currentOffset
            do {
                while true {
                    if Task.isCancelled { break }
                    let readStart = Date()
                    let data = try fileHandle.read(
                        upToCount: chunkSize
                    ) ?? Data()
                    let readDuration = Date().timeIntervalSince(readStart)
                    if data.isEmpty { break }
                    let nextOffset = fileOffset + Int64(data.count)
                    let isLast = data.count < chunkSize
                    let chunk = PipelineChunk(
                        transferID: transferID,
                        offset: fileOffset,
                        data: data,
                        isLastChunk: isLast,
                        readDuration: readDuration
                    )
                    fileOffset = nextOffset
                    readContinuation.yield(chunk)
                }
            } catch {
                // Erreur disque : on propage via le canal d'erreur.
                readContinuation.yield(
                    PipelineChunk(
                        transferID: transferID,
                        offset: -1,
                        data: Data(),
                        isLastChunk: true,
                        readDuration: 0,
                        readError: error
                    )
                )
            }
            readContinuation.finish()
        }

        // 2. Consommateur : fenêtre en vol bornée + acquittements
        //    ordonnés. Chaque chunk tiré du flux est envoyé dans une
        //    tâche enfant ; jusqu'à `pipelineDepth` envois peuvent
        //    être en transit simultanément. Les acquittements sont
        //    appliqués dans l'ordre strict d'émission grâce à
        //    `OrderedAckPump`, ce qui préserve l'invariant
        //    `totalBytesSentCount == expectedTotalSize` utilisé par
        //    le garde-fou d'intégrité.
        let window = PipelineWindow(limit: pipelineDepth)
        let pump = OrderedAckPump(startOffset: currentOffset)
        let errorSlot = PipelineErrorSlot()

        // Capture faible de self pour les callbacks MainActor
        // (mise à jour de la progression, redémarrage du timeout
        // d'activité). Le `withTaskGroup` attendra la fin de toutes
        // les tâches enfant avant de retourner, donc ces callbacks
        // s'exécutent nécessairement avant la sortie de la fonction.
        let transferMgr = transferManager
        let outgoingMgr = transferMgr.outgoingManager
        let transferIDForTasks = transferID
        let chunkSizeForTasks = chunkSize

        // Snapshot immuable de l'état d'envoi capturé une fois pour
        // toutes sous `@MainActor` (avant d'entrer dans le
        // `withTaskGroup`). Les tâches enfant (non isolées)
        // utiliseront ce snapshot pour appeler directement
        // `sendChunkOverConnection` sans jamais repasser par
        // `@MainActor` pour relire les `var` du manager.
        // C'est l'optimisation qui débloque le débit : avant le
        // refactor, chaque chunk payait un saut MainActor (~1 ms),
        // ce qui bridait le pipeline à ~4 chunks/s (~8 Mo/s sur
        // chunks de 2 Mio).
        let sendSnapshot = outgoingMgr.snapshotForSending()
        guard let snapshotConnection = sendSnapshot.connection else {
            // Pas de connexion : échec immédiat.
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            logger.error("Aucune connexion active pour le pipeline")
            return
        }
        let frameCodec = FrameCodec()
        let snapshotForTasks = sendSnapshot
        let connectionForTasks = snapshotConnection

        var lastError: Error?
        var lastReadDuration: Double = 0
        // Snapshot final lu depuis le pump une fois le groupe drainé :
        // l'ack pump a appliqué tous les submits dans l'ordre, donc
        // ses totaux sont la source de vérité.
        var lastOffsetConsumed = currentOffset
        var chunksSentCount: Int = 0
        var totalBytesSentCount: Int64 = 0
        var sentAnyChunk = false

        await withTaskGroup(of: Void.self) { group in
            for await chunk in readStream {
                // Vérifie d'abord si une tâche enfant a enregistré
                // une erreur : on ne continue pas à spawn si le
                // transfert est déjà condamné.
                if let err = errorSlot.consume() {
                    lastError = err
                    readerTask.cancel()
                    break
                }

                // Vérifie l'état d'activation avant chaque envoi :
                // si la queue a été annulée ou fermée, on arrête
                // immédiatement et on draine les envois en vol.
                guard outgoingTransferQueue.isActive(transferID) else {
                    readerTask.cancel()
                    break
                }

                if chunk.offset < 0 {
                    // Sentinelle d'erreur lecture.
                    lastError = chunk.readError
                    continue
                }

                // Attend un slot libre dans la fenêtre en vol. La
                // suspension permet aux tâches déjà en vol de
                // progresser (et de libérer leur slot à leur tour).
                await window.acquire()

                let capturedTransferID = chunk.transferID
                let capturedOffset = chunk.offset
                let capturedData = chunk.data
                let capturedIsLast = chunk.isLastChunk
                let capturedReadDuration = chunk.readDuration

                group.addTask { [weak self] in
                    do {
                        // Appel direct à la variante statique
                        // `nonisolated` du manager, avec le snapshot
                        // pré-capturé. Aucun saut MainActor par
                        // chunk : c'est la clé du gain de débit.
                        try await OutgoingTransferManager
                            .sendChunkOverConnectionStatic(
                                transferID: capturedTransferID,
                                offset: capturedOffset,
                                data: capturedData,
                                isLastChunk: capturedIsLast,
                                chunkSize: chunkSizeForTasks,
                                snapshot: snapshotForTasks,
                                frameCodec: frameCodec,
                                connection: connectionForTasks
                            )
                        // L'acquittement est appliqué en ordre strict
                        // par le pump : si le chunk N+1 termine avant
                        // N, son compteur attend que N soit passé.
                        await pump.submit(
                            offset: capturedOffset,
                            bytes: Int64(capturedData.count),
                            readDuration: capturedReadDuration
                        )
                        // Incrément atomique pour le batching UI :
                        // on ne traverse le MainActor qu'une fois
                        // tous les `uiBatchStride` chunks, pas à
                        // chaque chunk. Cela évite de saturer le
                        // sérialiseur du main thread (qui bridait
                        // le pipeline à ~4 chunks/s avant le refactor)
                        // tout en gardant la progression visible
                        // (~30 updates/s sur 1 Go / 2 Mio).
                        // Le dernier chunk force TOUJOURS la mise à
                        // jour pour garantir `progress == 100%` à
                        // l'UI.
                        let ackIndex = await pump.ackCount
                        let shouldUpdateUI = capturedIsLast
                            || (ackIndex % uiBatchStride == 0)

                        if shouldUpdateUI {
                            let snap = await pump.snapshot()
                            await MainActor.run {
                                transferMgr.updateProgress(
                                    transferID: transferIDForTasks,
                                    transferredBytes: snap.lastOffsetConsumed
                                )
                                // `restartTransferActivityTimeout` est
                                // une méthode de `self` (MainActor) : on
                                // l'invoque dans le même Run pour éviter
                                // une suspension supplémentaire. `self`
                                // est capturé faiblement par sécurité
                                // (le `withTaskGroup` parent garantit
                                // qu'on est toujours vivant pendant
                                // l'exécution, mais le compilateur
                                // l'ignore).
                                self?.restartTransferActivityTimeout(
                                    transferID: transferIDForTasks
                                )
                            }
                        }
                    } catch {
                        errorSlot.record(error)
                        readerTask.cancel()
                    }
                    // Le slot est toujours libéré, y compris en cas
                    // d'erreur : sans `defer`/`finally` on s'assure
                    // que la fenêtre ne fuit pas.
                    await window.release()
                }
            }

            // Attend la fin de toutes les tâches en vol avant de
            // continuer. Cela garantit que le snapshot du pump est
            // complet (tous les submits ont été appliqués ou ont
            // errored).
            await group.waitForAll()
        }

        // Snapshot final du pump (toutes les tâches ont été drainées).
        let finalSnapshot = await pump.snapshot()
        lastOffsetConsumed = finalSnapshot.lastOffsetConsumed
        chunksSentCount = finalSnapshot.chunkCount
        totalBytesSentCount = finalSnapshot.totalBytes
        lastReadDuration = finalSnapshot.lastReadDuration
        sentAnyChunk = chunksSentCount > 0

        // 3. Nettoyage systématique.
        outgoingFileHandles.removeValue(forKey: transferID)
        try? fileHandle.close()
        TransferPerformanceLog.finish(transferID: transferID)

        if let error = lastError {
            // Lecture ou envoi échoué.
            guard outgoingTransferQueue.isActive(transferID) else {
                return
            }
            if NetworkErrorClassifier.isRecoverableNetworkInterruption(error) {
                logger.info("Interruption réseau pendant l'envoi : \(error.localizedDescription, privacy: .public)")
                interruptOutgoingTransfer(transferID: transferID)
                return
            }
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            logger.error("Échec d'envoi : \(error.localizedDescription, privacy: .public)")
            return
        }

        // Un fichier vide (ou une reprise arrivée exactement à sa taille
        // finale) n'a aucun chunk à envoyer. Il reste pourtant un transfert
        // valide : `transferCompleted(totalBytes: 0)` permet au récepteur
        // de finaliser son writer vide et de conserver le fichier.
        if !sentAnyChunk {
            guard expectedTotalSize == 0 || expectedTotalSize == nil else {
                transferTimeoutManager.cancel(transferID: transferID)
                transferManager.markFailed(transferID: transferID)
                finishOutgoingTransfer(transferID: transferID)
                logger.error("Aucun morceau pour un fichier non vide : \(transferID, privacy: .public)")
                return
            }
        }

        // 4. Garde-fou d'intégrité : on vérifie que la somme des chunks
        //    envoyés correspond bien à la taille de fichier annoncée.
        //    Si ce n'est pas le cas, c'est qu'un chunk a été perdu en
        //    route (buffer borné, écrasement, etc.) et on lève une
        //    erreur AVANT d'envoyer un `transferCompleted` mensonger.
        if let expectedSize = expectedTotalSize,
           totalBytesSentCount != expectedSize {
            logger.error("Intégrité pipeline : \(totalBytesSentCount) octets envoyés pour \(expectedSize) attendus (\(chunksSentCount) chunks)")
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            throw PipelineIntegrityError(
                expected: expectedSize,
                sent: totalBytesSentCount,
                chunks: chunksSentCount
            )
        }

        // 5. Envoi du `transferCompleted` et armement du timeout de
        //    confirmation finale. Identique à l'ancien chemin.
        guard connectionManager.sendTransferCompleted(
            transferID: transferID,
            totalBytes: lastOffsetConsumed,
            sha256: fileSHA256
        ) else {
            transferTimeoutManager.cancel(transferID: transferID)
            transferManager.markFailed(transferID: transferID)
            finishOutgoingTransfer(transferID: transferID)
            logger.error("Impossible d'envoyer transferCompleted : session sécurisée non disponible")
            return
        }

        // Les données sont intégralement parties : le transfert passe
        // en « Validation du récepteur ». La progression est figée à
        // 100 % (dernier offset consommé) MAIS le transfert n'est PAS
        // terminé : seul le `transferSucceeded` du récepteur — envoyé
        // après son contrôle SHA-256 et l'enregistrement du fichier —
        // déclenchera le `markCompleted` (handler
        // `handleTransferSucceeded`). Le protocole est inchangé :
        // toujours aucun ACK par chunk.
        transferManager.markAwaitingConfirmation(
            transferID: transferID,
            transferredBytes: lastOffsetConsumed
        )

        transferTimeoutManager.cancel(transferID: transferID)
        transferTimeoutManager.start(
            transferID: transferID,
            kind: .completionConfirmation,
            duration: .seconds(30)
        ) { [weak self] in
            guard let self else { return }
            logger.warning("Confirmation finale non reçue : \(transferID, privacy: .public)")
            self.transferManager.markFailed(transferID: transferID)
            self.finishOutgoingTransfer(transferID: transferID)
        }
        logger.info("Tous les morceaux ont été envoyés : \(lastOffsetConsumed) octets (\(chunksSentCount) chunks)")
    }

    /// Structure interne au pipeline d'envoi async : un chunk lu depuis
    /// le fichier, prêt à être chiffré puis envoyé. `offset == -1`
    /// signale une erreur de lecture (champ `readError`).
    private struct PipelineChunk: Sendable {
        let transferID: UUID
        let offset: Int64
        let data: Data
        let isLastChunk: Bool
        let readDuration: Double
        var readError: Error? = nil
    }

    /// Sémaphore compteur bornant la fenêtre en vol de chunks dans
    /// `runChunkPipeline`. Jusqu'à `limit` chunks peuvent être en
    /// transit simultanément ; les autres attendent passivement
    /// qu'un slot se libère via une `CheckedContinuation`.
    ///
    /// Le pattern `waiters.first`-prioritaire transfère le slot
    /// d'une libération à l'acquéreur en attente sans repasser
    /// par la valeur 0 : cela évite une fenêtre de course où deux
    /// acquéreurs pourraient croire disposer du slot.
    ///
    /// Exposé en `internal` (et non `private`) pour que les tests
    /// de régression puissent l'instancier directement et exercer
    /// le type de production, pas un doublon. Le code de production
    /// reste dans ce fichier, donc le type n'est pas exposé hors
    /// du module.
    actor PipelineWindow {
        private var inFlight = 0
        private let limit: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// Pic d'occupation de la fenêtre observé en interne. Mis à
        /// jour à chaque `acquire()` (chemin rapide) et à chaque
        /// `release()` (transfert de slot). Utile pour l'instrumentation
        /// et les tests de non-régression sur la back-pressure.
        private(set) var maxObservedInFlight: Int = 0

        init(limit: Int) {
            self.limit = limit
        }

        func acquire() async {
            if inFlight < limit {
                inFlight += 1
                maxObservedInFlight = max(maxObservedInFlight, inFlight)
                return
            }
            // Anti-fuite de continuation : si la `Task` appelante est
            // annulée pendant l'attente, la continuation abandonnée
            // doit être retirée de la queue sans être resumée. Sinon,
            // elle s'accumule comme une entrée morte et consomme un
            // slot à perpétuité.
            //
            // Le handler `onCancel` tourne HORS de l'actor : on ré-entre
            // par `Task { await ... }` pour respecter l'isolation
            // d'acteur. Si la continuation a déjà été reprise par
            // `release()` (transfert au prochain acquéreur) entre
            // l'`onCancel` et l'exécution de la `Task`, le retrait
            // échoue silencieusement (`firstIndex` ne trouve rien),
            // ce qui est correct.
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    waiters.append(continuation)
                }
            } onCancel: { [weak self] in
                // La `Task` interne ne capture que `self` faiblement
                // pour ne pas maintenir une référence sur l'actor si
                // l'instance a été détruite avant que le cancel ne
                // soit délivré.
                Task { [weak self] in
                    await self?.removeFirstWaiter()
                }
            }
            // Slot acquis (soit par le chemin rapide, soit après
            // reprise via `release()`) : on met à jour le pic.
            maxObservedInFlight = max(maxObservedInFlight, inFlight)
        }

        func release() {
            if let next = waiters.first {
                // Transfère directement le slot au prochain
                // acquéreur : `inFlight` reste constant.
                waiters.removeFirst()
                next.resume()
                return
            }
            inFlight = max(0, inFlight - 1)
        }

        /// Retire la première continuation en attente, sans la
        /// resumer. Utilisé par le handler `onCancel` de `acquire()`
        /// pour ne pas laisser une continuation morte bloquer un
        /// slot à perpétuité après une annulation.
        ///
        /// Retire uniquement la première pour préserver le FIFO :
        /// chaque appelant de `acquire()` annulé supprime *sa*
        /// continuation, qui est forcément en tête de file (les
        /// `release()` ne retirent que `waiters.first`).
        private func removeFirstWaiter() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst()
        }

        /// Utilisé en debug / tests : retourne le nombre d'envois
        /// actuellement en vol. N'est pas appelé dans le chemin
        /// nominal.
        func currentInFlight() -> Int { inFlight }
    }

    /// Sérialise l'application des acquittements de chunks dans
    /// l'ordre strict d'émission (offset croissant). Plusieurs chunks
    /// peuvent être en vol simultanément, mais le compteur global
    /// `totalBytes` et la position du dernier offset acquitté
    /// (`lastOffsetConsumed`) n'avancent que dans l'ordre.
    ///
    /// L'algorithme : une map `pending` indexée par offset conserve
    /// les acquittements qui arrivent avant leur tour (suspendus
    /// via `CheckedContinuation`). Quand un acquittement in-order
    /// est appliqué, on draine `pending` autant que possible
    /// (offsets contigus au nouvel `nextOffset`) en reprenant
    /// chaque continuation.
    ///
    /// Exposé en `internal` (et non `private`) pour que les tests
    /// de régression puissent l'instancier directement et exercer
    /// le type de production, pas un doublon.
    actor OrderedAckPump {
        private var nextOffset: Int64
        private var pending: [Int64: PendingAck] = [:]
        private(set) var totalBytes: Int64 = 0
        private(set) var chunkCount: Int = 0
        private(set) var lastOffsetConsumed: Int64
        private(set) var lastReadDuration: Double = 0
        /// Nombre total d'appels à `submit()` (acks reçus, dans
        /// l'ordre ou hors ordre). Utilisé pour le batching UI : on
        /// ne traverse le MainActor qu'une fois tous les N acks,
        /// pas à chaque ack.
        private(set) var ackCount: Int = 0

        private struct PendingAck {
            let bytes: Int64
            let readDuration: Double
            let cont: CheckedContinuation<Void, Never>
        }

        init(startOffset: Int64) {
            self.nextOffset = startOffset
            self.lastOffsetConsumed = startOffset
        }

        /// Soumet un acquittement de chunk. Suspend jusqu'à ce que
        /// tous les chunks d'offset inférieur aient été acquittés,
        /// puis applique celui-ci et draine les suivants.
        func submit(
            offset: Int64,
            bytes: Int64,
            readDuration: Double
        ) async {
            ackCount += 1
            if offset == nextOffset {
                applyInOrder(
                    offset: offset,
                    bytes: bytes,
                    readDuration: readDuration
                )
                drainPending()
                return
            }
            // Hors ordre : on attend notre tour.
            //
            // Anti-fuite de continuation : si la `Task` appelante est
            // annulée pendant l'attente, la continuation abandonnée
            // doit être retirée du `pending` sans être resumée. Sinon,
            // l'entrée reste en map comme un acquittement mort, et
            // `drainPending` pourrait la reprendre sans contexte valide.
            //
            // Le handler `onCancel` tourne HORS de l'actor : on ré-entre
            // par `Task { await ... }` pour respecter l'isolation
            // d'acteur. Si l'entrée a déjà été reprise par
            // `drainPending` (l'offset est devenu `nextOffset`),
            // `removeValue` renvoie `nil` et l'opération est sans
            // effet — comportement correct.
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    (cont: CheckedContinuation<Void, Never>) in
                    pending[offset] = PendingAck(
                        bytes: bytes,
                        readDuration: readDuration,
                        cont: cont
                    )
                }
            } onCancel: { [weak self] in
                Task { [weak self] in
                    await self?.removePending(offset: offset)
                }
            }
        }

        /// Retire l'entrée `pending` pour l'offset donné, sans
        /// resumer sa continuation. Utilisé par le handler
        /// `onCancel` de `submit()` pour ne pas laisser une
        /// continuation morte bloquer un offset dans la map après
        /// une annulation.
        private func removePending(offset: Int64) {
            pending.removeValue(forKey: offset)
        }

        private func applyInOrder(
            offset: Int64,
            bytes: Int64,
            readDuration: Double
        ) {
            nextOffset += bytes
            lastOffsetConsumed = offset + bytes
            totalBytes += bytes
            chunkCount += 1
            // `lastReadDuration` du pump reflète le dernier ack
            // *appliqué* (donc dans l'ordre), pas le dernier ack
            // *reçu* : c'est le comportement souhaité, aligné sur
            // le code séquentiel d'origine.
            lastReadDuration = readDuration
        }

        private func drainPending() {
            while let head = pending.removeValue(forKey: nextOffset) {
                nextOffset += head.bytes
                lastOffsetConsumed += head.bytes
                totalBytes += head.bytes
                chunkCount += 1
                lastReadDuration = head.readDuration
                head.cont.resume()
            }
        }

        struct Snapshot {
            let totalBytes: Int64
            let chunkCount: Int
            let lastOffsetConsumed: Int64
            let lastReadDuration: Double
        }

        func snapshot() -> Snapshot {
            Snapshot(
                totalBytes: totalBytes,
                chunkCount: chunkCount,
                lastOffsetConsumed: lastOffsetConsumed,
                lastReadDuration: lastReadDuration
            )
        }
    }

    /// Stockage d'erreur partagé entre les tâches enfant du
    /// `withTaskGroup` et la boucle principale. La boucle
    /// principale lit l'erreur via `consume()` au début de chaque
    /// itération pour stopper le producteur et sortir
    /// proprement. Une seule erreur est conservée (la première) :
    /// les suivantes sont ignorées car le transfert est de toute
    /// façon condamné.
    ///
    /// Exposé en `internal` (et non `private`) pour que les tests
    /// de régression puissent l'instancier directement et exercer
    /// le type de production, pas un doublon.
    final class PipelineErrorSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var _error: Error?

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if _error == nil { _error = error }
        }

        /// Lit l'erreur enregistrée puis l'efface, pour qu'une
        /// seconde consultation (par une autre itération) ne la
        /// revoie pas. C'est la sémantique "edge-triggered"
        /// attendue par la boucle principale.
        func consume() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            let value = _error
            _error = nil
            return value
        }
    }



    func dismissPendingTransferRequest() {
        pendingApprovalCoordinator.clear()
    }

    private func appendPendingTransferRequest(
        _ request: PendingTransferRequest
    ) {
        pendingApprovalCoordinator.append(request)
    }

    private func clearPendingTransferBatch(
        transferIDs: Set<UUID>
    ) {
        pendingApprovalCoordinator.remove(
            transferIDs: transferIDs
        )
    }

    private func pendingRequests() -> [PendingTransferRequest] {
        pendingApprovalCoordinator.requests
    }

    /// Point unique de sortie de l'état « En attente » côté émetteur.
    ///
    /// Enregistre l'approbation du pair puis :
    /// - démarre le pipeline si l'entrée est active ;
    /// - laisse l'entrée en file démarrer à son activation (FIFO) ;
    /// - sort explicitement de « En attente » un envoi dont l'entrée a
    ///   disparu de la file ;
    /// - **conserve un délai de sécurité** si le démarrage est reporté.
    ///
    /// Le délai d'approbation (300 s) n'est annulé que lorsque le
    /// pipeline tourne réellement : l'annuler avant — comme c'était le cas
    /// auparavant — laissait un transfert accepté mais non démarré bloqué
    /// « En attente » sans aucun filet.
    private func markOutgoingTransferApproved(_ transferID: UUID) {
        guard approvedOutgoingTransfers.insert(transferID).inserted else {
            logger.info("Acceptation déjà traitée : \(transferID, privacy: .public)")
            return
        }

        guard let entry = outgoingTransferQueue.allEntries.first(where: {
            $0.id == transferID
        }) else {
            transferTimeoutManager.cancel(transferID: transferID)
            recoverOrphanedApprovedTransfer(transferID: transferID)
            return
        }

        guard outgoingTransferQueue.isActive(transferID) else {
            // File FIFO strictement sérialisante : l'entrée démarrera à son
            // activation (`activateOutgoingTransfer`). Le délai
            // d'approbation n'a plus d'objet ; le délai d'activité prendra
            // le relais dès le premier chunk.
            transferTimeoutManager.cancel(transferID: transferID)
            logger.info("Transfert accepté, en file derrière l’envoi actif : \(entry.fileName, privacy: .public)")
            return
        }

        switch beginOutgoingTransfer(entry) {
        case .started, .alreadyRunning, .finishedInError:
            transferTimeoutManager.cancel(transferID: transferID)
            logger.info("Transfert accepté : \(transferID, privacy: .public)")

        case .deferred(let reason):
            logger.warning("Transfert accepté mais démarrage reporté : \(reason, privacy: .public)")
            armAcceptedStartTimeout(
                transferID: transferID,
                reason: reason
            )
        }
    }

    private func sendFileChunks(
        transferID: UUID,
        fileURL: URL
    ) {
        do {
            let sha256 = try FileHasher.sha256(
                of: fileURL
            )

            transferManager.setSHA256(
                transferID: transferID,
                sha256: sha256
            )

            let fileHandle = try FileHandle(
                forReadingFrom: fileURL
            )

            outgoingFileHandles[transferID] = fileHandle

            // La taille lue sur le disque, et non celle du transfert : c'est
            // ce fichier-ci que l'on découpe. Une lecture qui échoue laisse
            // la taille à zéro, donc le découpage d'origine.
            let fileSize = (
                try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey]
                )
                .fileSize
            )
            .map(Int64.init) ?? 0

            let chunkSize = TransferChunkSizing.chunkSize(
                forFileSize: fileSize
            )

            logger.info(
                "Morceaux de \(chunkSize / 1024) Kio pour \(fileSize) octets"
            )

            TransferPerformanceLog.begin(
                transferID: transferID,
                mode: "NORMAL",
                chunkSize: chunkSize
            )

            sendNextChunk(
                transferID: transferID,
                fileHandle: fileHandle,
                fileSHA256: sha256,
                offset: 0,
                chunkSize: chunkSize,
                expectedTotalSize: fileSize
            )

        } catch {
            logger.error(
                "Impossible de préparer le fichier : \(error.localizedDescription, privacy: .public)"
            )

            self.transferTimeoutManager.cancel(
                transferID: transferID
            )
            
            transferManager.markFailed(
                transferID: transferID
            )

            finishOutgoingTransfer(
                transferID: transferID
            )
        }
    }


    private func configureBindings() {
        // Configure notification categories at startup
        notificationManager.configureCategories()

        // Chargement de l'état de reprise au démarrage : scanner le dossier
        // des métadonnées et restaurer les transferts interrompus.
        Task { @MainActor in
            do {
                let dir = ResumePersistence.directory()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let files = try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "json" }

                for file in files {
                    let transferID = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                    guard transferID != nil else { continue }

                    let persistence = ResumePersistence(url: file)
                    guard let info = try await persistence.load() else {
                        // Métadonnée illisible : orpheline, on la retire
                        // plutôt que de la laisser s'accumuler.
                        try? await persistence.clear()
                        continue
                    }

                    guard let reconciledBytes =
                        Self.resolvedRestorationBytes(for: info) else {
                        // Le `.partial` n'existe plus : les octets reçus sont
                        // perdus, la métadonnée ne décrit plus rien de réel.
                        logger.info("Métadonnée orpheline (`.partial` absent) : \(info.transferID, privacy: .public)")
                        try? await persistence.clear()
                        continue
                    }

                    self.transferManager.restoreInterruptedTransfer(
                        info: info,
                        transferredBytes: reconciledBytes
                    )

                    logger.info("Reprise restaurée : \(info.transferID, privacy: .public) — \(reconciledBytes)/\(info.fileSize) octets")
                }
            } catch {
                logger.error("Erreur chargement reprises : \(error.localizedDescription, privacy: .public)")
            }
        }

        pendingApprovalCoordinator.onReadyChanged = { [weak self] in
            guard let self else {
                return
            }

            self.pendingTransferBatch =
                self.pendingApprovalCoordinator.presentableBatch
        }

        outgoingTransferQueue.onActivate = { [weak self] entry in
            self?.activateOutgoingTransfer(entry)
        }

        bonjourService.onIncomingConnection = { [weak connectionManager] connection in
            connectionManager?.accept(connection)
        }

        // Redécouverte Bonjour d'un pair : signal de reprise automatique.
        //
        // Une coupure Wi-Fi invalide l'adresse connue ; seule la
        // redécouverte fournit une endpoint fraîche. Quand des transferts
        // interrompus appartiennent au pair retrouvé, la connexion est
        // relancée ici : sans cet appel, la campagne attendait indéfiniment
        // une session que personne ne déclenchait (reprises « reportées »
        // en boucle observées sur le terrain). La tâche de backoff ne fait
        // qu'attendre la session — jamais une vieille adresse n'est rejetée
        // aveuglément, seule l'endpoint fraîche sert.
        bonjourService.onDeviceDiscovered = { [weak self] discovered in
            self?.handleDeviceDiscovered(discovered)
        }

        // Jeu de résultats Bonjour modifié (y compris passage à vide) :
        // mise à jour de la présence AVANT l'évaluation des connexions
        // automatiques par appareil. C'est ce callback — et lui seul —
        // qui observe les DÉPARTS : `onDeviceDiscovered` n'est jamais
        // invoqué pour un pair qui quitte le réseau, si bien que la
        /// suspension d'auto-connexion après déconnexion explicite n'était
        /// jamais levée à son retour (bug « plus de reconnexion »).
        bonjourService.onDiscoveryResultsChanged = { [weak self] currentIDs in
            self?.updateDiscoveredPeerPresence(current: currentIDs)
        }

        connectionManager.onSessionReady = { [weak self] connection in
            guard let self else { return }
            self.transferManager.outgoingManager.setConnection(connection)

            // Déterminer le rôle de ce pair dans le handshake.
            //
            // Sur un réseau local, les deux pairs se découvrent en
            // général mutuellement et **chacun accepte la connexion
            // entrante de l'autre**. Sans cette distinction, les deux
            // pairs lançaient leur propre `keyExchange` en parallèle,
            // chacun avec son propre `sessionId` LOCAL. Résultat : les
            // deux `keyExchange` se croisaient, chaque pair adoptait le
            // `sessionId` de l'autre, puis les `keyExchangeAck`
            // arrivaient avec un `sessionId` qui ne correspondait plus
            // au `activeSessionId` du moment → rejet (« sessionId
            // incohérent »), puis tous les chunks binaires v2 étaient
            // rejetés à la réception.
            //
            // Convention de rôle, calquée sur la direction TCP :
            //  - **Initiateur** : la session a été ouverte par un
            //    `connect()` (`.outgoing`). C'est ce pair qui génère
            //    le `sessionId` partagé et l'envoie dans son
            //    `keyExchange`. L'autre pair l'adopte puis renvoie un
            //    `keyExchangeAck` avec le même `sessionId`.
            //  - **Répondeur** : la session a été acceptée par le
            //    listener (`.incoming`). Ce pair NE doit PAS envoyer
            //    son propre `keyExchange` : il attend celui de
            //    l'initiateur, l'adopte, et répond par un
            //    `keyExchangeAck`.
            //
            // Si les deux pairs se considèrent comme initiateurs
            // (ex. connexions sortantes croisées), le perdant du
            // `guard session == nil` voit sa connexion annulée et ne
            // passe jamais par `onSessionReady` (cf.
            // `ConnectionManager.connect`).
            let isInitiator = self.connectionManager.session?.direction == .outgoing

            if isInitiator {
                // Générer un identifiant de session unique pour lier
                // les chunks binaires v2 à cette session. C'est cet
                // UUID qui sera partagé avec le pair via le
                // `keyExchange` sortant.
                let newSessionId = UUID()
                self.connectionManager.setActiveSessionId(newSessionId)
                self.transferManager.outgoingManager.setSessionId(newSessionId)

                // Initier le handshake ECDH P-256 : on envoie notre clé
                // publique éphémère et notre `sessionId` partagé via
                // `keyExchange`. Le pair répondra par `keyExchangeAck`
                // et les deux côtés installeront alors la clé
                // symétrique de session.
                self.initiateECDHHandshake()
            } else {
                // Côté répondeur : on NE génère PAS de `sessionId`
                // LOCAL et on N'envoie PAS de `keyExchange`. On attend
                // que l'initiateur nous envoie son `keyExchange` ; on
                // adoptera alors son `sessionId` (cf.
                // `handleKeyExchange`).
                logger.info("Session entrante — j'attends le keyExchange de l'initiateur")
            }

            if let device = self.connectionManager.connectedDevice {
                self.lastKnownPeerID = device.id
                self.connectionManager.rememberConnectedPeer(device)

                // Initier le pairage si le pair n'est pas encore de confiance
                if !self.pairingStore.isTrusted(device.id)
                    && !self.pairingStore.isBlocked(device.id) {
                    self.initiatePairing(with: device, on: connection)
                }
            }
            // La connexion TCP est `.ready`, mais les contrôles de
            // transfert restent volontairement bloqués jusqu'à la fin de
            // l'ECDH/HKDF. La campagne de reprise est déclenchée depuis
            // `installSessionKeyAndMarkReady`, après installation effective
            // de la clé dans les deux gestionnaires.
        }

        connectionManager.onSessionClosed = { [weak self] lostPeer in
            guard let self else {
                return
            }

            // 1. Identifier le pair associé à la session perdue.
            //
            // Le pair est reçu en paramètre (extrait avant la destruction de
            // la session), avec le dernier pair mémorisé en repli : une
            // session précédemment connectée ne doit jamais produire
            // « Déconnexion sans pair identifié ».
            let identifiedPeer =
                lostPeer ?? self.connectionManager.lastConnectedPeer

            guard !self.isCleaningUpSession else {
                logger.info("Nettoyage de session déjà effectué")
                return
            }

            self.isCleaningUpSession = true

            // La session vient de tomber : la campagne de reprise en cours
            // (s'il y en a une) est invalidée. Elle ne repartira que sur une
            // redécouverte Bonjour fraîche, jamais sur l'ancienne endpoint.
            self.endResumeCampaign()

            // Oublier le sessionId : un nouveau sera généré à la prochaine
            // reconnexion (les chunks de l'ancienne session ne doivent pas
            // pouvoir être acceptés par la suivante).
            self.connectionManager.setActiveSessionId(nil)
            self.transferManager.outgoingManager.setSessionId(nil)
            self.hasAdoptedSessionIdFromKeyExchange = false

            // Oublier aussi la clé de chiffrement : sur reconnexion, un
            // nouveau handshake ECDH générera une nouvelle clé
            // symétrique. Sans ce nettoyage, l'ancien chiffrement resterait
            // actif contre un nouveau `sessionId`, ce qui ferait rejeter
            // les chunks (l'AAD contient le sessionId).
            self.transferManager.outgoingManager.clearSessionKey()
            Task { @MainActor [weak self] in
                await self?.transferManager.incomingManager.clearSessionKeyAndWait()
            }
            self.pendingECDHHandshake = nil

            if let identifiedPeer {
                self.lastKnownPeerID = identifiedPeer.id
                logger.info("Déconnexion du pair : \(identifiedPeer.name, privacy: .public)")
            } else {
                logger.info("Déconnexion sans pair jamais identifié : rien à interrompre")
            }

            // Oublier les challenges de pairage en attente : un pair
            // déconnecté ne répondra jamais, et garder son challenge
            // en mémoire empêcherait un nouveau handshake propre plus
            // tard (ou accumulerait des entrées fantômes).
            self.pendingPairingChallenges.removeAll()

            // 2/3. Identifier puis interrompre les transferts actifs, avec
            // leur progression conservée et leurs métadonnées persistées.
            let interruptedIDs: [UUID]

            if let identifiedPeer {
                interruptedIDs = self.transferManager.interruptActiveTransfers(
                    peerID: identifiedPeer.id,
                    peerName: identifiedPeer.name,
                    protocolVersion: ProtocolCompatibility.currentVersion
                )
            } else {
                interruptedIDs = []
            }

            // 4. Arrêter proprement le pipeline sortant.
            self.startedOutgoingTransfers.removeAll()
            self.approvalRequestsSent.removeAll()
            self.approvedOutgoingTransfers.removeAll()
            self.transferTimeoutManager.cancelAll()
            self.pendingApprovalCoordinator.clear()

            let fileHandles = Array(
                self.outgoingFileHandles.values
            )
            self.outgoingFileHandles.removeAll()

            for fileHandle in fileHandles {
                try? fileHandle.close()
            }

            // Une déconnexion n'est pas un échec : les transferts actifs de
            // ce pair passent à `.interrupted` (non terminal), restent
            // reprisables, et conservent source et `.partial`.
            let queuedEntries = self.outgoingTransferQueue.cancelAll()

            for entry in queuedEntries {
                if interruptedIDs.contains(entry.id) {
                    // Source conservée pour une reprise ultérieure :
                    // la supprimer détruirait l'offset déjà envoyé.
                    continue
                }

                self.transferManager.cleanupOutgoingTransfer(
                    transferID: entry.id
                )
            }

            // 5. Les métadonnées sont déjà écrites par l'interruption. Côté
            // réception : fermer les writers en préservant les `.partial`.
            for transferID in interruptedIDs {
                if let transfer = self.transferManager.transfers.first(where: {
                    $0.id == transferID
                }), transfer.direction == .incoming {
                    self.transferManager.interruptIncomingTransfer(
                        transferID: transferID
                    )
                }
            }

            // Ce nettoyage préserve sources sortantes et `.partial` des
            // transferts visés.
            self.transferManager.finishSessionCleanup(
                preserving: interruptedIDs
            )

            // 6. Seulement maintenant : oublier le pair, la séquence de
            // déconnexion est terminée.
            self.connectionManager.clearLastConnectedPeer()

            // 7. La session tombée « consomme » la tentative de connexion
            // automatique associée au pair : la prochaine redécouverte
            // pourra reconnecter (pair de confiance ou reprises en attente)
            // sans attendre la fenêtre d'anti-rafale. Pour une déconnexion
            // explicite, la suspension posée par `disconnectFromPeer`
            // bloque de toute façon la reconnexion.
            //
            // Un échec (session n'ayant JAMAIS atteint la sécurité)
            // augmente le compteur de backoff du pair : les relances
            // s'écartent (15 s → 240 s) au lieu de marteler un pair
            // injoignable. Une session qui avait abouti remet le compteur
            // à zéro.
            if let identifiedPeer {
                self.lastAutoConnectAttempts.removeValue(
                    forKey: identifiedPeer.id
                )
                if self.currentSessionDidReachSecureReady {
                    self.autoConnectFailureCounts.removeValue(
                        forKey: identifiedPeer.id
                    )
                } else {
                    let previous = self.autoConnectFailureCounts[
                        identifiedPeer.id
                    ] ?? 0
                    self.autoConnectFailureCounts[identifiedPeer.id] =
                        previous + 1
                }
                // Partage de l'état avec l'extension Finder : le pair
                // reste le « dernier appareil connecté » (sessionClose),
                // mais la session est marquée fermée.
                AirBridgeSharedStateStore.publishSessionClosed(
                    peerID: identifiedPeer.id
                )
            }
            self.currentSessionDidReachSecureReady = false

            // Le drapeau est baissé ici plutôt qu'à `onSessionReady` :
            // une seconde déconnexion peut survenir avant toute
            // reconnexion (refus du pair, réseau instable), et il faut
            // alors pouvoir nettoyer à nouveau. Toute la séquence
            // ci-dessus est déjà idempotente — elle ne trouve plus rien à
            // interrompre si l'état a déjà été nettoyé.
            self.isCleaningUpSession = false
        }
        
        messageRouter.onEvent = { [weak self] event in
            guard let self else { return }
            
            switch event {
                
            case let .hello(message, connection):
                logger.info("Core : HELLO reçu de \(message.sender.name, privacy: .public), version protocole: \(message.protocolVersion)")

                // L'identification du pair est confirmée ici : mémoriser
                // l'identité dès maintenant, pas seulement à la fermeture,
                // pour qu'une coupure brutale trouve toujours un pair connu.
                if self.connectionManager.connectedDevice?.id == message.sender.id {
                    self.lastKnownPeerID = message.sender.id
                }

                // Négocier la version du protocole
                let negotiatedVersion = min(message.protocolVersion, ProtocolCompatibility.currentVersion)
                if negotiatedVersion >= 2 {
                    self.transferManager.outgoingManager.setProtocolVersion(negotiatedVersion)
                    self.connectionManager.setNegotiatedProtocolVersion(negotiatedVersion)
                    logger.info("Version du protocole négociée : v\(negotiatedVersion)")
                }

                guard self.connectionManager.sendAcknowledgement(
                    on: connection
                ) else {
                    self.logger.error("Impossible d'envoyer l'ACK : identité locale non signable")
                    self.connectionManager.disconnect()
                    return
                }

            case let .acknowledgement(message, _):
                logger.info("Core : ACK reçu de \(message.sender.name, privacy: .public), version protocole: \(message.protocolVersion)")

                // Pour l'initiateur de la connexion, c'est ici qu'on reçoit la version
                // du pair distant (le récepteur répond avec ack qui contient sa version)
                let negotiatedVersion = min(message.protocolVersion, ProtocolCompatibility.currentVersion)
                if negotiatedVersion >= 2 {
                    self.transferManager.outgoingManager.setProtocolVersion(negotiatedVersion)
                    self.connectionManager.setNegotiatedProtocolVersion(negotiatedVersion)
                    logger.info("Version du protocole négociée (via ACK) : v\(negotiatedVersion)")
                }

            case let .pairingRequest(message, connection):
                logger.info("Core : Demande de pairage reçue de \(message.sender.name, privacy: .public)")
                self.handlePairingRequest(message, connection: connection)

            case let .pairingResponse(message, connection):
                logger.info("Core : Réponse de pairage reçue de \(message.sender.name, privacy: .public)")
                self.handlePairingResponse(message, connection: connection)

            case let .keyExchange(message, connection):
                // Échange de clés ECDH P-256 : le pair nous envoie sa clé
                // publique éphémère. On génère la nôtre, on dérive la clé
                // symétrique de session, et on renvoie un `keyExchangeAck`
                // pour que le pair fasse de même.
                self.handleKeyExchange(message: message, connection: connection)

            case let .keyExchangeAck(message, connection):
                // Le pair a reçu notre `keyExchange` et nous renvoie sa clé
                // publique. On dérive la clé symétrique et on l'installe
                // dans les deux gestionnaires de chunks.
                self.handleKeyExchangeAck(
                    message: message,
                    connection: connection
                )


            case let .unknown(message, _):
                logger.warning("Message non pris en charge : \(message.type.rawValue, privacy: .public)")
                
           
            case let .transferRequest(message, connection):
                // Wrapper async : la création du transfert entrant est
                // `await` (le writer est préparé avant de répondre à
                // l'émetteur, pour respecter le contrat `.accepted` =
                // prêt à écrire). Le reste de la branche reste tel quel.
                Task { @MainActor in
                    self.logger.info(
                        "Core : demande de transfert reçue de \(message.sender.name, privacy: .public)"
                    )

                    guard self.connectionManager.isSecureSessionReady else {
                        self.logger.error("Demande de transfert ignorée : session sécurisée non prête")
                        return
                    }

                    guard let payloadData = message.payload else {
                        self.logger.error("La demande de transfert ne contient aucun payload")

                        return
                    }

                    do {
                        let request = try self.messageCodec.decodePayload(
                            TransferRequestPayload.self,
                            from: payloadData
                        )

                        self.logger.info("Fichier : \(request.fileName, privacy: .public)")
                        self.logger.info("Taille : \(request.fileSize) octets")
                        self.logger.info("Type : \(request.contentType ?? "inconnu", privacy: .public)")
                        self.logger.info("Transfert : \(request.transferID, privacy: .public)")

                        // Vérification du pair : les appareils de confiance sont
                        // acceptés automatiquement, les bloqués sont refusés,
                        // les inconnus déclenchent la demande utilisateur.
                        let peerID = message.sender.id
                        if self.pairingStore.isBlocked(peerID) {
                            self.logger.warning("Pair bloqué — transfert refusé : \(message.sender.name, privacy: .public)")
                            self.connectionManager.sendTransferRejected(
                                transferID: request.transferID,
                                reason: "pair bloqué",
                                on: connection
                            )
                            return
                        }

                        let isTrusted = self.pairingStore.isTrusted(peerID)
                        if isTrusted {
                            self.logger.info("Pair de confiance — acceptation automatique : \(message.sender.name, privacy: .public)")
                        }

                        let outcome: IncomingRequestOutcome
                        if isTrusted {
                            outcome = await self.transferManager.createIncomingTransferAutoAccepted(
                                request: request,
                                sender: message.sender
                            )
                            if outcome == .accepted {
                                // Auto-acceptation : on confirme immédiatement
                                // à l'émetteur, sans passer par la feuille.
                                // Un échec d'émission ne doit pas rester
                                // silencieux : sans confirmation, l'émetteur
                                // attend son acceptation indéfiniment.
                                if !self.connectionManager.sendTransferAccepted(
                                    transferID: request.transferID,
                                    on: connection
                                ) {
                                    self.logger.error("Auto-acceptation non transmise à l’émetteur : \(request.fileName, privacy: .public)")
                                    self.transferManager.markFailed(
                                        transferID: request.transferID,
                                        reason: "Acceptation non transmise à l’émetteur"
                                    )
                                    self.transferManager.cancelIncomingTransfer(
                                        transferID: request.transferID
                                    )
                                    return
                                }
                            }
                        } else {
                            outcome = await self.transferManager.createIncomingTransfer(
                                request: request,
                                sender: message.sender
                            )
                        }

                        switch outcome {
                        case .accepted:
                            // Notifier IMMÉDIATEMENT la demande de transfert entrante (AirDrop style)
                            // Avant la fenêtre de coalescence, pour que l'utilisateur voie la notif
                            // pendant qu'il décide d'accepter/refuser
                            self.notificationManager.notifyIncomingTransferRequest(
                                senderName: message.sender.name,
                                fileCount: 1,
                                fileName: request.fileName
                            )

                        case .rejected:
                            // Refusé avant toute question à l'utilisateur : une
                            // annonce hors plafond n'a pas à occuper l'écran, et
                            // l'émetteur doit l'apprendre tout de suite plutôt
                            // qu'au bout de son délai d'attente.
                            self.connectionManager.sendTransferRejected(
                                transferID: request.transferID,
                                reason: "annonce refusée par le récepteur",
                                on: connection
                            )

                            return

                        case .duplicate:
                            // Aucune réponse : un refus porterait l'identifiant
                            // du transfert déjà en cours, et l'avorterait.
                            return
                        }

                        let pendingRequest = PendingTransferRequest(
                            sender: message.sender,
                            request: request,
                            connection: connection
                        )
                        self.appendPendingTransferRequest(pendingRequest)

                        // Le protocole envoie une demande par fichier : le
                        // récepteur ne voit donc jamais la sélection. En
                        // revanche le coordinateur d'autorisation coalesce
                        // déjà les demandes d'une même rafale, et ce lot
                        // d'autorisation tient lieu de sélection ici.
                        if let batchID = self.pendingApprovalCoordinator.batch?.id {
                            self.transferManager.setBatchID(
                                transferID: request.transferID,
                                batchID: batchID
                            )
                        }


                    } catch {
                        self.logger.error("Payload de transfert invalide : \(error.localizedDescription, privacy: .public)")
                    }
                }
                
           
                
            case let .transferAccepted(message, _):
                guard let payloadData = message.payload else {
                    logger.error("Acceptation sans payload")
                    return
                }

                do {
                    let payload = try messageCodec.decodePayload(
                        TransferAcceptedPayload.self,
                        from: payloadData
                    )

                    guard transferManager.hasTransfer(
                        transferID: payload.transferID
                    ) else {
                        logger.error("Acceptation pour un transfert inconnu : \(payload.transferID, privacy: .public)")
                        return
                    }

                    guard senderOwnsTransfer(
                        payload.transferID,
                        sender: message.sender
                    ) else {
                        // Le transfert existe mais n’est pas attribué à ce
                        // pair : l’acceptation est écartée. Cause réelle de
                        // blocage « En attente » côté émetteur, elle est
                        // donc tracée avec le pair incriminé.
                        logger.error("Acceptation refusée : transfert non attribué à \(message.sender.name, privacy: .public)")
                        return
                    }

                    // Toute la sortie de l’état « En attente » est
                    // concentrée là : démarrage, mise en file, ou filet de
                    // sécurité si le démarrage est reporté.
                    markOutgoingTransferApproved(payload.transferID)

                } catch {
                    logger.error("Acceptation invalide : \(error.localizedDescription, privacy: .public)")
                }

                
            case let .transferRejected(message, _):
                guard let payloadData = message.payload else {
                    logger.error("Refus sans payload")
                    return
                }
                
                do {
                    let payload = try messageCodec.decodePayload(
                        TransferRejectedPayload.self,
                        from: payloadData
                    )
                    
                    guard senderOwnsTransfer(
                        payload.transferID,
                        sender: message.sender
                    ) else {
                        logger.error("transferRejected refusé : sender non propriétaire du transfert")
                        return
                    }

                    guard !transferManager.isTerminal(
                        transferID: payload.transferID
                    ) else {
                        logger.info("transferRejected déjà traité : \(payload.transferID, privacy: .public)")
                        return
                    }

                    transferTimeoutManager.cancel(
                        transferID: payload.transferID
                    )

                    transferManager.markRejected(
                        transferID: payload.transferID
                    )

                    finishOutgoingTransfer(
                        transferID: payload.transferID
                    )
                    
                    logger.error("Transfert refusé")
                    logger.info("Transfert : \(payload.transferID, privacy: .public)")
                    logger.info("Motif : \(payload.reason ?? "Aucun", privacy: .public)")

                } catch {
                    logger.error("Refus invalide : \(error.localizedDescription, privacy: .public)")
                }
                
                
            case let .fileChunk(message, _):
                Task {
                    await self.handleFileChunk(message: message)
                }

                
            case let .transferCompleted(message, connection):
                Task { @MainActor in
                    await self.handleTransferCompleted(
                        message: message,
                        connection: connection
                    )
                }

            case let .transferSucceeded(message, _):
                handleTransferSucceeded(message: message)

                
            case let .resumeRequest(message, connection):
                guard let payloadData = message.payload else {
                    logger.error("resumeRequest sans payload")
                    return
                }
                do {
                    let payload = try messageCodec.decodePayload(
                        ResumeRequestPayload.self,
                        from: payloadData
                    )
                    let transferID = payload.transferID
                    guard let transfer = transferManager.transfers.first(where: { $0.id == transferID }),
                          senderOwnsTransfer(transferID, sender: message.sender) else {
                        logger.error("resumeRequest refusé : sender non propriétaire du transfert")
                        return
                    }
                    if transfer.direction == .incoming {
                        let written = transferManager.incomingWriterWrittenBytes(transferID: transferID)
                        connectionManager.sendResumeAccepted(
                            transferID: transferID,
                            offset: written,
                            fileName: transfer.fileName,
                            sha256: "",
                            chunkSize: TransferChunkSizing.chunkSize(forFileSize: transfer.fileSize),
                            fileSize: transfer.fileSize,
                            on: connection
                        )
                    }
                } catch {
                    logger.error("resumeRequest invalide")
                }

            case let .resumeAccepted(message, _):
                // La connexion du message n'est pas utilisée ici : l'envoi
                // repart par le pipeline sortant courant, déjà rattaché à la
                // session active via `onSessionReady`.
                guard let payloadData = message.payload else {
                    logger.error("resumeAccepted sans payload")
                    return
                }
                do {
                    let payload = try messageCodec.decodePayload(
                        ResumeAcceptedPayload.self,
                        from: payloadData
                    )
                    let transferID = payload.transferID
                    guard transferManager.hasTransfer(transferID: transferID),
                          senderOwnsTransfer(transferID, sender: message.sender) else {
                        logger.error("resumeAccepted refusé : sender non propriétaire du transfert")
                        return
                    }
                    if let entry = outgoingTransferQueue.allEntries.first(where: { $0.id == transferID }) {
                        // reprendre à l'offset donné
                        // La source temporaire peut avoir disparu (nettoyage,
                        // redémarrage) : dans ce cas la reprise est simplement
                        // abandonnée plutôt que laissée en erreur.
                        guard let fileURL = try? transferManager.outgoingFileURL(
                            transferID: transferID
                        ), let fileHandle = try? FileHandle(
                            forReadingFrom: fileURL
                        ) else {
                            logger.error("Source introuvable pour la reprise : \(transferID, privacy: .public)")
                            return
                        }
                        // Un offset au-delà de la fin de fichier est
                        // impossible ici : il vient du récepteur, qui n'a
                        // accepté que les octets qu'il a réellement écrits.
                        fileHandle.seek(toFileOffset: UInt64(payload.offset))
                        outgoingFileHandles[transferID] = fileHandle

                        // AUCUN hachage ici : recalculer le SHA-256 complet
                        // de la source bloquerait le fil principal pendant
                        // toute une relecture du fichier avant le premier
                        // chunk repris. La empreinte calculée au premier
                        // envoi (`sendFileChunks`) est conservée dans le
                        // transfert ; si elle manque, elle reste vide et
                        // l'intégrité finale repose sur le contrôle du
                        // récepteur — inchangé.
                        let sourceSHA256 =
                            transferManager.transfers.first {
                                $0.id == transferID
                            }?.sha256 ?? ""
                        // La reprise est une continuation : la durée de
                        // transfert affichée repart de maintenant, sinon le
                        // temps d'interruption s'ajoute et écrase le débit
                        // mesuré (`recordHistory` divise par cette durée).
                        transferManager.resetStartedAt(transferID: transferID)
                        transferManager.markAccepted(transferID: transferID)
                        sendNextChunk(
                            transferID: transferID,
                            fileHandle: fileHandle,
                            fileSHA256: sourceSHA256,
                            offset: payload.offset,
                            chunkSize: TransferChunkSizing.chunkSize(forFileSize: entry.fileSize),
                            performanceMode: "RESUME",
                            expectedTotalSize: entry.fileSize
                        )
                    }
                } catch {
                    logger.error("resumeAccepted invalide")
                }

            case let .transferFailed(message, _):
                handleTransferFailed(message: message)
                
            case let .transferCancelled(message, _):
                handleTransferCancelled(
                    message: message
                )

            }
        }
    }

    // MARK: - Pairage

    /// Initie (ou relance) un pairage avec le pair actuellement connecté.
    ///
    /// Variante pratique pour l'UI : on lit la session active et le pair
    /// distant, et on lance le handshake si les conditions sont réunies.
    /// - Returns: `true` si une demande a effectivement été envoyée.
    @discardableResult
    func requestPairingIfNeeded() -> Bool {
        guard let peer = connectionManager.connectedDevice,
              let connection = connectionManager.session?.connection else {
            logger.info("Pas de session active, impossible de pairer")
            return false
        }
        initiatePairing(with: peer, on: connection)
        return true
    }

    /// Initie un pairage avec un pair : envoie une demande contenant
    /// notre clé publique signée avec un challenge.
    func initiatePairing(
        with peer: Device,
        on connection: NWConnection
    ) {
        // Ne pas ré-initier un pairage avec un pair déjà de confiance.
        if pairingStore.isTrusted(peer.id) {
            logger.info("Le pair \(peer.name, privacy: .public) est déjà de confiance, pas de pairage")
            return
        }
        if pairingStore.isBlocked(peer.id) {
            logger.warning("Le pair \(peer.name, privacy: .public) est bloqué, refus de pairage")
            return
        }

        let challenge = PairingHandshake.generateChallenge()
        pendingPairingChallenges[peer.id] = challenge

        connectionManager.sendPairingRequest(
            peerID: localDeviceForPairing().id,
            peerName: localDeviceForPairing().name,
            challenge: challenge,
            on: connection
        ) { [weak self] result in
            switch result {
            case .success:
                self?.logger.info("Demande de pairage envoyée à \(peer.name, privacy: .public)")
            case .failure(let error):
                self?.logger.error("Échec d'envoi de la demande de pairage : \(error.localizedDescription, privacy: .public)")
                self?.pendingPairingChallenges.removeValue(forKey: peer.id)
            }
        }
    }

    /// Traite une demande de pairage reçue : si on est l'initiateur en
    /// attente de la réponse, c'est la réponse qu'on reçoit. Sinon, c'est
    /// le pair qui initie : on lui renvoie un nouveau challenge signé.
    private func handlePairingRequest(
        _ message: AirBridgeMessage,
        connection: NWConnection
    ) {
        guard let payloadData = message.payload else {
            logger.error("Demande de pairage sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                PairingPayload.self,
                from: payloadData
            )

            let peerID = message.sender.id

            // Si on a déjà un challenge en attente pour ce pair, c'est sa
            // réponse à notre demande : on la vérifie avec ce challenge.
            if let ourChallenge = pendingPairingChallenges[peerID] {
                let result = pairingHandshake.verifyPairingPayload(
                    payload,
                    expectedChallenge: ourChallenge
                )
                pendingPairingChallenges.removeValue(forKey: peerID)

                switch result {
                case .success(let info):
                    logger.info("Pairage réussi avec \(info.peerName, privacy: .public)")
                    // Empreinte omise volontairement : matériel cryptographique
                    // sensible, jamais journalisé.
                    retryDeferredApprovalRequests()
                case .invalidSignature:
                    logger.error("Signature de pairage invalide de \(message.sender.name, privacy: .public)")
                case .challengeMismatch:
                    logger.error("Challenge de pairage incorrect de \(message.sender.name, privacy: .public)")
                case .protocolVersionMismatch:
                    logger.error("Version de protocole incompatible avec \(message.sender.name, privacy: .public)")
                case .selfPairingAttempt:
                    logger.warning("Tentative d'auto-pairage détectée")
                }
                return
            }

            // Sinon, c'est une demande entrante : on signe le challenge
            // reçu et on le renvoie dans notre réponse (le handshake est
            // un challenge-response : l'initiateur envoie un challenge, le
            // répondeur le signe avec sa clé privée et le renvoie tel quel).
            // Si le pair est bloqué, on ne répond pas.
            if pairingStore.isBlocked(peerID) {
                logger.warning("Demande de pairage ignorée d'un pair bloqué : \(message.sender.name, privacy: .public)")
                return
            }

            // On vérifie la signature du PairingPayload reçu AVANT d'y
            // répondre, et on enregistre le pair dans le PairingStore si
            // la vérification réussit. Sans cela, le répondeur reste
            // inconnu pour lui-même : il accepterait bien la réponse
            // (le MAC confirme qu'il a bien signé le challenge) mais
            // rejetterait ensuite tous les messages du pair (transferRequest
            // etc.) parce que ce pair ne serait pas dans son PairingStore.
            let verifyResult = pairingHandshake.verifyIncomingPairingRequest(payload)
            switch verifyResult {
            case .success(let info):
                logger.info("Pair \(info.peerName, privacy: .public) authentifié (signature ECDSA valide)")
                retryDeferredApprovalRequests()
            case .invalidSignature:
                logger.error("Signature de pairage invalide de \(message.sender.name, privacy: .public) — réponse non envoyée")
                return
            case .protocolVersionMismatch:
                logger.error("Version de protocole incompatible avec \(message.sender.name, privacy: .public) — réponse non envoyée")
                return
            case .selfPairingAttempt:
                logger.warning("Tentative d'auto-pairage détectée de \(message.sender.name, privacy: .public)")
                return
            case .challengeMismatch:
                // Pas applicable ici (pas de challenge en attente), mais
                // couvert par le compilateur : on ne devrait jamais le
                // voir. Au cas où, on refuse par sécurité.
                logger.error("Réponse de pairage refusée (challenge inattendu)")
                return
            }

            // On garde le même challenge en attente : c'est celui que
            // l'initiateur attend dans sa réponse pour confirmer qu'on a
            // bien signé ce qu'il a envoyé.
            pendingPairingChallenges[peerID] = payload.challenge

            connectionManager.sendPairingResponse(
                peerID: localDeviceForPairing().id,
                peerName: localDeviceForPairing().name,
                challenge: payload.challenge,
                on: connection
            ) { [weak self] result in
                if case .failure(let error) = result {
                    self?.logger.error("Échec d'envoi de la réponse de pairage : \(error.localizedDescription, privacy: .public)")
                    self?.pendingPairingChallenges.removeValue(forKey: peerID)
                }
            }
            logger.info("Réponse de pairage envoyée à \(message.sender.name, privacy: .public)")

        } catch {
            logger.error("Payload de pairage invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Traite une réponse de pairage reçue (notre challenge signé par le pair).
    private func handlePairingResponse(
        _ message: AirBridgeMessage,
        connection: NWConnection
    ) {
        guard let payloadData = message.payload else {
            logger.error("Réponse de pairage sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                PairingPayload.self,
                from: payloadData
            )

            guard let ourChallenge = pendingPairingChallenges[message.sender.id] else {
                logger.warning("Réponse de pairage inattendue de \(message.sender.name, privacy: .public)")
                return
            }

            let result = pairingHandshake.verifyPairingPayload(
                payload,
                expectedChallenge: ourChallenge
            )
            pendingPairingChallenges.removeValue(forKey: message.sender.id)

            switch result {
            case .success(let info):
                logger.info("Pairage confirmé avec \(info.peerName, privacy: .public)")
                // La clé long-terme du pair est désormais enregistrée : les
                // contrôles qu'il nous envoie (dont `transferAccepted`)
                // peuvent être authentifiés. Les annonces reportées par la
                // barrière de pairage sont rejouées immédiatement.
                retryDeferredApprovalRequests()
            case .invalidSignature:
                logger.error("Signature de pairage invalide de \(message.sender.name, privacy: .public)")
            case .challengeMismatch:
                logger.error("Challenge de pairage incorrect de \(message.sender.name, privacy: .public)")
            case .protocolVersionMismatch:
                logger.error("Version de protocole incompatible avec \(message.sender.name, privacy: .public)")
            case .selfPairingAttempt:
                logger.warning("Tentative d'auto-pairage détectée")
            }
        } catch {
            logger.error("Payload de réponse de pairage invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Vérifie qu'un contrôle de transfert concerne bien un transfert
    /// appartenant au sender authentifié de la session. La signature du
    /// message prouve l'identité du pair, mais ne lie pas à elle seule un
    /// `transferID` à ce pair : cette liaison métier est donc répétée ici.
    private func senderOwnsTransfer(
        _ transferID: UUID,
        sender: Device
    ) -> Bool {
        guard let transfer = transferManager.transfers.first(where: {
            $0.id == transferID
        }), transfer.peer.id == sender.id else {
            return false
        }

        if let expectedKey = transfer.peer.publicKeyData,
           expectedKey != sender.publicKeyData {
            return false
        }

        if let persistedKey = pairingStore.pairing(for: sender.id)?.peerPublicKeyData,
           persistedKey != sender.publicKeyData {
            return false
        }

        return true
    }

    /// Renvoie l'identité de l'appareil local (utilisée pour les payloads
    /// de pairage). On évite `connectionManager.connectedDevice` qui peut
    /// être nil selon le moment du cycle de connexion.
    private func localDeviceForPairing() -> Device {
        bonjourService.localDevice
    }

    // MARK: - Handshake ECDH P-256 (chiffrement de session)

    /// Clé éphémère générée à l'initiation du handshake ECDH.
    /// Conservée jusqu'à la réception du `keyExchangeAck` du pair, qui
    /// permet de dériver la clé symétrique de session.
    private var pendingECDHHandshake: SecureHandshake?

    /// Indique si le `sessionId` a déjà été adopté depuis un
    /// `keyExchange` reçu. Permet de distinguer le premier
    /// `keyExchange` (qui doit écraser l'UUID LOCAL généré à
    /// `onSessionReady`) des `keyExchange` ultérieurs (qui doivent
    /// être ignorés si leur `sessionId` diffère — replay ou injection).
    private var hasAdoptedSessionIdFromKeyExchange = false

    /// Reçoit un `keyExchange` du pair : on génère notre propre clé
    /// éphémère, on dérive la clé symétrique de session, et on renvoie
    /// notre clé publique via un `keyExchangeAck`.
    ///
    /// Correction architecturale : le `sessionId` partagé EST celui
    /// annoncé par l'initiator dans `payload.sessionId`. Auparavant,
    /// on lisait `connectionManager.getActiveSessionId()` (un UUID
    /// LOCAL généré à `onSessionReady` de chaque pair), ce qui
    /// produisait deux `sessionId` distincts sur les deux pairs →
    /// clés symétriques dérivées différentes, et tous les chunks
    /// rejetés à la réception ("FileChunk avec sessionId incorrect").
    ///
    /// La signature long-terme du `keyExchange` couvre le payload
    /// entier incluant `sessionId` (vérifié par
    /// `runSecureReceptionPipeline` en amont), donc
    /// `payload.sessionId` est authentifié.
    private func handleKeyExchange(
        message: AirBridgeMessage,
        connection: NWConnection
    ) {
        guard !connectionManager.isSecureSessionReady else {
            logger.error("keyExchange reçu après établissement de la session — connexion fermée")
            failSecureHandshake(on: connection)
            return
        }

        guard let payloadData = message.payload else {
            logger.error("keyExchange sans payload")
            failSecureHandshake(on: connection)
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                KeyExchangePayload.self,
                from: payloadData
            )

            // Anti-remplacement : si un `sessionId` a déjà été ADOPTÉ
            // depuis un précédent `keyExchange` (et non pas généré
            // localement à `onSessionReady`) et qu'il diffère de celui
            // annoncé, on ignore. C'est soit un replay, soit un second
            // `keyExchange` croisé. Un `sessionId` adopté ne se
            // remplace pas pour la durée de la connexion. Un rejeu du
            // même `keyExchange` (même `sessionId`) est déjà bloqué
            // par le `ReplayProtectionStore` (vérification antireplay
            // dans `runSecureReceptionPipeline`).
            //
            // Note : le premier `keyExchange` doit TOUJOURS adopter,
            // même si un UUID LOCAL a été généré à `onSessionReady`
            // (c'est précisément le bug architectural que ce correctif
            // résout : l'UUID LOCAL du responder est écrasé par le
            // `sessionId` de l'initiator).
            if hasAdoptedSessionIdFromKeyExchange {
                if connectionManager.getActiveSessionId() != payload.sessionId {
                    logger.error("keyExchange avec sessionId divergent — connexion fermée")
                    failSecureHandshake(on: connection)
                } else {
                    logger.warning("keyExchange reçu alors qu'un échange est déjà en cours — ignoré")
                }
                return
            }

            // Adoption du sessionId partagé (celui de l'initiator).
            let sharedSessionId = payload.sessionId
            connectionManager.setActiveSessionId(sharedSessionId)
            transferManager.outgoingManager.setSessionId(sharedSessionId)
            hasAdoptedSessionIdFromKeyExchange = true

            // 1. Génération de notre clé éphémère et dérivation de la clé
            //    symétrique de session, en utilisant le sessionId partagé.
            let handshake = SecureHandshake()
            let sessionKey = try handshake.deriveSessionKey(
                from: payload.publicKeyData,
                sessionId: sharedSessionId
            )

            // L'ack ne doit partir qu'après l'installation effective de
            // la clé dans le chiffreur entrant actoriel. Sinon le pair
            // pourrait considérer le handshake terminé et envoyer un
            // chunk pendant que `ChunkSink` est encore en mode transparent.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await self.installSessionKeyAndMarkReady(
                    sessionKey,
                    sessionId: sharedSessionId
                ) else {
                    self.logger.error("Impossible d'activer la session ECDH côté réception")
                    self.failSecureHandshake(on: connection)
                    return
                }

                // Envoi de notre `keyExchangeAck` avec notre clé publique
                // et le sessionId partagé : le pair pourra alors dériver
                // la même clé symétrique et l'installer de son côté.
                self.connectionManager.sendKeyExchangeAck(
                    publicKey: handshake.publicKey,
                    sessionId: sharedSessionId,
                    on: connection
                ) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch result {
                        case .success:
                            // L'ack est désormais en file après la mise en
                            // place de la clé. Les contrôles de transfert
                            // peuvent suivre dans l'ordre réseau.
                            self.activateTransfersAfterSecureSession()
                        case .failure(let error):
                            self.logger.error("Échec d'envoi du keyExchangeAck : \(error.localizedDescription, privacy: .public)")
                            self.failSecureHandshake(on: connection)
                        }
                    }
                }

                self.logger.info("Handshake ECDH terminé (côté réception, sessionId=\(sharedSessionId, privacy: .public))")
            }

        } catch {
            logger.error("keyExchange invalide : \(error.localizedDescription, privacy: .public)")
            failSecureHandshake(on: connection)
        }
    }

    /// Reçoit un `keyExchangeAck` du pair : on dérive la clé symétrique
    /// à partir de notre `SecureHandshake` en attente et de la clé
    /// publique du pair, puis on l'installe.
    private func handleKeyExchangeAck(
        message: AirBridgeMessage,
        connection: NWConnection
    ) {
        guard !connectionManager.isSecureSessionReady else {
            logger.error("keyExchangeAck reçu après établissement de la session — connexion fermée")
            failSecureHandshake(on: connection)
            return
        }

        guard let payloadData = message.payload else {
            logger.error("keyExchangeAck sans payload")
            failSecureHandshake(on: connection)
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                KeyExchangePayload.self,
                from: payloadData
            )
            guard let activeSession = connectionManager.getActiveSessionId() else {
                logger.error("keyExchangeAck sans session active")
                failSecureHandshake(on: connection)
                return
            }
            // Cohérence défensive : le responder doit renvoyer dans son
            // ack le MÊME `sessionId` que celui qu'il a adopté depuis
            // notre `keyExchange` (cf. `handleKeyExchange`). Si le
            // responder a adopté un autre `sessionId` (ou si on a
            // plusieurs sessions en parallèle), on le détecte ici et
            // on ignore l'ack plutôt que de dériver une clé
            // incompatible.
            if payload.sessionId != activeSession {
                logger.error("keyExchangeAck avec sessionId incohérent : \(payload.sessionId, privacy: .public) vs \(activeSession, privacy: .public) — connexion fermée")
                failSecureHandshake(on: connection)
                return
            }
            guard let handshake = pendingECDHHandshake else {
                logger.error("keyExchangeAck inattendu sans handshake en attente")
                failSecureHandshake(on: connection)
                return
            }

            let sessionKey = try handshake.deriveSessionKey(
                from: payload.publicKeyData,
                sessionId: activeSession
            )
            pendingECDHHandshake = nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await self.installSessionKeyAndMarkReady(
                    sessionKey,
                    sessionId: activeSession
                ) else {
                    self.logger.error("Impossible d'activer la session ECDH côté initiation")
                    self.failSecureHandshake(on: connection)
                    return
                }
                self.activateTransfersAfterSecureSession()
                self.logger.info("Handshake ECDH terminé (côté initiation)")
            }

        } catch {
            logger.error("keyExchangeAck invalide : \(error.localizedDescription, privacy: .public)")
            failSecureHandshake(on: connection)
        }
    }

    /// Initie un handshake ECDH P-256 : on génère une clé éphémère, on
    /// l'envoie via `keyExchange`, et on attend le `keyExchangeAck` du
    /// pair qui permettra la dérivation finale.
    func initiateECDHHandshake() {
        guard connectionManager.session != nil,
              let activeSession = connectionManager.getActiveSessionId(),
              let connection = connectionManager.session?.connection else {
            logger.info("Pas de session active pour le handshake ECDH")
            return
        }
        // Ne pas relancer un handshake si une clé est déjà installée.
        if transferManager.outgoingManager is OutgoingTransferManager,
           pendingECDHHandshake != nil {
            return
        }

        let handshake = SecureHandshake()
        pendingECDHHandshake = handshake

        do {
            let payload = KeyExchangePayload(
                publicKey: handshake.publicKey,
                sessionId: activeSession
            )
            let payloadData = try messageCodec.encodePayload(payload)
            let message = AirBridgeMessage(
                type: .keyExchange,
                sender: bonjourService.localDevice,
                payload: payloadData
            )
            guard connectionManager.send(
                message,
                on: connection
            ) else {
                pendingECDHHandshake = nil
                failSecureHandshake(on: connection)
                return
            }
            logger.info("Handshake ECDH initié")
        } catch {
            logger.error("Impossible d'initier le handshake ECDH : \(error.localizedDescription, privacy: .public)")
            pendingECDHHandshake = nil
            failSecureHandshake(on: connection)
        }
    }

    /// Invalide immédiatement une négociation ECDH incomplète. Aucun état
    /// de session ni aucune clé ne doit survivre à une erreur de décodage,
    /// de dérivation ou d'envoi : la reconnexion repartira d'un handshake
    /// neuf.
    private func failSecureHandshake(on connection: NWConnection) {
        guard connectionManager.session?.connection === connection else {
            return
        }

        pendingECDHHandshake = nil
        hasAdoptedSessionIdFromKeyExchange = false
        connectionManager.resetSecureSession()
        connectionManager.setActiveSessionId(nil)
        transferManager.outgoingManager.clearSessionKey()
        transferManager.outgoingManager.setSessionId(nil)
        transferManager.incomingManager.clearSessionKey()
        connectionManager.disconnect()
    }

    /// Installe la clé symétrique dans les deux gestionnaires puis lève la
    /// barrière `ConnectionManager.isSecureSessionReady`. L'`await` est
    /// indispensable : `ChunkSink` est un actor et une simple `Task {}`
    /// laisserait une fenêtre où le pair pourrait envoyer un chunk avant
    /// que le cipher entrant ne possède réellement sa clé.
    @discardableResult
    private func installSessionKeyAndMarkReady(
        _ key: SymmetricKey,
        sessionId: UUID
    ) async -> Bool {
        guard connectionManager.session != nil,
              connectionManager.getActiveSessionId() == sessionId else {
            return false
        }

        transferManager.outgoingManager.installSessionKey(key)
        await transferManager.incomingManager.installSessionKeyAndWait(key)

        guard connectionManager.session != nil,
              connectionManager.getActiveSessionId() == sessionId else {
            return false
        }

        connectionManager.markSecureSessionReady()
        guard connectionManager.isSecureSessionReady else {
            return false
        }

        currentSessionDidReachSecureReady = true

        // Session sécurisée établie : succès pour le pair concerné —
        // le backoff d'auto-connexion repart à zéro (prochaine coupure
        // pourra reconnecter après la fenêtre de base, pas après 240 s).
        if let peer = connectionManager.connectedDevice {
            lastConnectedDevice = peer
            autoConnectFailureCounts.removeValue(forKey: peer.id)
            lastAutoConnectAttempts.removeValue(forKey: peer.id)
            // État partagé avec l'extension Finder : « Envoyer à
            // <dernier appareil> » devient disponible une fois la
            // session sécurisée ouverte.
            AirBridgeSharedStateStore.publishSessionOpened(
                peerID: peer.id,
                name: peer.name,
                model: peer.model
            )
        }

        // Un envoi ciblé programmé vers ce pair peut partir maintenant.
        consumeScheduledTargetedSendIfReady()

        return true
    }

    /// Déclenche les contrôles applicatifs seulement après que la trame
    /// finale du handshake a été mise en file. Côté répondeur, l'appel est
    /// différé jusqu'à l'envoi du `keyExchangeAck`, afin que le pair ait
    /// installé sa propre clé avant de recevoir une annonce de transfert.
    private func activateTransfersAfterSecureSession() {
        guard connectionManager.isSecureSessionReady else { return }

        if let activeEntry = outgoingTransferQueue.activeEntry {
            activateOutgoingTransfer(activeEntry)
        }

        // Les entrées d'un lot dont l'annonce avait été reportée (session
        // non prête, pairage non enregistré) sont rejouées : seule l'entrée
        // active était retentée auparavant.
        retryDeferredApprovalRequests()

        scheduleAutomaticResumeOnReconnect()
    }

    private func handleTransferCancelled(
        message: AirBridgeMessage
    ) {
        guard let payloadData = message.payload else {
            logger.error("transferCancelled sans payload")
            return
        }

        
        do {
            
            
            let payload = try messageCodec.decodePayload(
                TransferCancelledPayload.self,
                from: payloadData
            )

            guard senderOwnsTransfer(
                payload.transferID,
                sender: message.sender
            ) else {
                logger.error("transferCancelled refusé : sender non propriétaire du transfert")
                return
            }

            guard !transferManager.isTerminal(
                transferID: payload.transferID
            ) else {
                logger.info("transferCancelled déjà traité : \(payload.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: payload.transferID
            )

            transferManager.markCancelled(
                transferID: payload.transferID
            )

            transferManager.cancelIncomingTransfer(
                transferID: payload.transferID
            )

            finishOutgoingTransfer(
                transferID: payload.transferID
            )

            let cancelledIDs = Set([payload.transferID])
            clearPendingTransferBatch(transferIDs: cancelledIDs)

            logger.warning(
                "Transfert annulé par l’appareil distant"
            )

            if let reason = payload.reason {
                logger.info("Motif : \(reason, privacy: .public)")
            }

        } catch {
            logger.error(
                "transferCancelled invalide : \(error.localizedDescription, privacy: .public)"
            )
        }

        // Notification: transfert annulé (par appareil distant)
        do {
            let payload = try messageCodec.decodePayload(
                TransferCancelledPayload.self,
                from: message.payload ?? Data()
            )
            if notificationManager.checkNotNotified(payload.transferID) {
                if let transfer = transferManager.transfers.first(where: { $0.id == payload.transferID }) {
                    notificationManager.notifyTransferCancelled(
                        fileName: transfer.fileName,
                        deviceName: message.sender.name,
                        cancelledBy: .remoteDevice
                    )
                }
            }
        } catch {
            logger.error("Impossible de décoder payload pour notification : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Traite un chunk binaire reçu : décode, vérifie le sessionId, puis
    /// délègue le travail lourd (déchiffrement + écriture disque) à
    /// `transferManager.appendReceivedChunk` qui s'exécute hors MainActor
    /// depuis la phase 2-bis. Méthode `async` car l'API publique du
    /// TransferManager est devenue asynchrone ; le call site du
    /// `MessageRouter` l'enveloppe dans une Task dédiée.
    private func handleFileChunk(
        message: AirBridgeMessage
    ) async {
        guard let payloadData = message.payload else {
            logger.error("FileChunk sans payload")
            return
        }

        do {
            // On évite le double décodage : si le `ConnectionManager`
            // a déjà décodé le chunk binaire v2 (cas de la réception
            // directe), on l'utilise tel quel. Sinon (chemin v1, ou
            // chemin non décodé en amont), on décode maintenant.
            let binaryChunk: BinaryFileChunkPayload?
            if let pre = message.decodedBinaryChunk {
                binaryChunk = pre
            } else if message.protocolVersion >= 2 {
                binaryChunk = try messageCodec.decodePayload(
                    BinaryFileChunkPayload.self,
                    from: payloadData,
                    protocolVersion: message.protocolVersion,
                    messageType: .fileChunk
                )
            } else {
                binaryChunk = nil
            }

            // Extraire les champs communs
            let transferID: UUID
            let offset: Int64
            let data: Data
            if let binaryChunk = binaryChunk {
                // Vérification du sessionId : un chunk binaire v2
                // DOIT appartenir à la session active. Un chunk d'une
                // autre session (ou d'un attaquant) est silencieusement
                // ignoré.
                if let activeId = self.connectionManager.getActiveSessionId(),
                   binaryChunk.sessionId != activeId {
                    logger.error("FileChunk avec sessionId incorrect : \(binaryChunk.sessionId, privacy: .public) vs \(activeId, privacy: .public)")
                    return
                }
                transferID = binaryChunk.transferID
                offset = binaryChunk.offset
                data = binaryChunk.data
            } else {
                let v1Chunk = try messageCodec.decodePayload(
                    FileChunkPayload.self,
                    from: payloadData
                )
                transferID = v1Chunk.transferID
                offset = v1Chunk.offset
                data = v1Chunk.data
            }

            // Le sessionId est désormais obligatoire (MAJEUR-3) :
            // l'appelant de appendReceivedChunk doit le fournir
            // explicitement. Pour les chunks v1, qui ne transportent pas
            // de sessionId, on exige que la session active soit déjà
            // établie — sinon on rejette le chunk.
            guard let activeSessionId = connectionManager.getActiveSessionId() else {
                logger.error("FileChunk reçu sans session active établie — chunk ignoré")
                return
            }

            guard senderOwnsTransfer(transferID, sender: message.sender) else {
                logger.error("FileChunk refusé : sender non propriétaire du transfert")
                return
            }

            let wasWritten = await transferManager.appendReceivedChunk(
                transferID: transferID,
                offset: offset,
                data: data,
                sessionId: activeSessionId
            )

            if wasWritten {
                restartTransferActivityTimeout(
                    transferID: transferID
                )
            }
        } catch {
            logger.error("FileChunk invalide : \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTransferCompleted(
        message: AirBridgeMessage,
        connection: NWConnection
    ) async {
        guard let payloadData = message.payload else {
            logger.error("transferCompleted sans payload")
            return
        }

        do {
            let completed = try messageCodec.decodePayload(
                TransferCompletedPayload.self,
                from: payloadData
            )
            
            guard senderOwnsTransfer(
                completed.transferID,
                sender: message.sender
            ) else {
                logger.error("transferCompleted refusé : sender non propriétaire du transfert")
                return
            }

            guard !transferManager.isTerminal(
                transferID: completed.transferID
            ) else {
                logger.info("transferCompleted déjà traité : \(completed.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: completed.transferID
            )

            let isValid = await transferManager.finalizeReceivedTransfer(
                transferID: completed.transferID,
                announcedTotalBytes: completed.totalBytes
            )

            guard isValid else {
                transferManager.markFailed(
                    transferID: completed.transferID
                )

                transferManager.cancelIncomingTransfer(
                    transferID: completed.transferID
                )

                connectionManager.sendTransferFailed(
                    transferID: completed.transferID,
                    reason: "Taille du fichier reçue invalide",
                    on: connection
                )

                return
            }

            do {
                let temporaryURL =
                    try transferManager.receivedTemporaryFileURL(
                        transferID: completed.transferID
                    )

                let receivedSHA256 = try FileHasher.sha256(
                    of: temporaryURL
                )

                guard receivedSHA256 == completed.sha256 else {
                    transferManager.markFailed(
                        transferID: completed.transferID
                    )

                    transferManager.cancelIncomingTransfer(
                        transferID: completed.transferID
                    )

                    connectionManager.sendTransferFailed(
                        transferID: completed.transferID,
                        reason: "L’intégrité du fichier est invalide",
                        on: connection
                    )

                    logger.error("Empreinte SHA-256 différente")
                    return
                }

                transferManager.setSHA256(
                    transferID: completed.transferID,
                    sha256: receivedSHA256
                )


                let savedURL = try transferManager.saveReceivedFile(
                    transferID: completed.transferID
                )

                transferManager.setLocalFileURL(
                    transferID: completed.transferID,
                    url: savedURL
                )

                transferManager.markCompleted(
                    transferID: completed.transferID,
                    transferredBytes: completed.totalBytes
                )

                // Notification: transfert reçu terminé avec succès
                if notificationManager.checkNotNotified(completed.transferID) {
                    notificationManager.notifyTransferCompleted(
                        direction: .received,
                        fileCount: 1,
                        deviceName: message.sender.name
                    )
                }


                connectionManager.sendTransferSucceeded(
                    transferID: completed.transferID,
                    receivedBytes: completed.totalBytes,
                    on: connection
                )

                logger.info("Transfert terminé")
                logger.info("Fichier disponible : \(savedURL.path, privacy: .public)")

            } catch {
                transferManager.markFailed(
                    transferID: completed.transferID
                )

                
                transferManager.cancelIncomingTransfer(
                    transferID: completed.transferID
                )
                
                connectionManager.sendTransferFailed(
                    transferID: completed.transferID,
                    reason: "Impossible d’enregistrer le fichier",
                    on: connection
                )

                logger.error(
                    "Impossible d’enregistrer le fichier : \(error.localizedDescription, privacy: .public)"
                )
            }

        } catch {
            logger.error(
                "transferCompleted invalide : \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    
    
    private func handleTransferSucceeded(
        message: AirBridgeMessage
    ) {
        guard let payloadData = message.payload else {
            logger.error("transferSucceeded sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                TransferSucceededPayload.self,
                from: payloadData
            )

            guard senderOwnsTransfer(
                payload.transferID,
                sender: message.sender
            ) else {
                logger.error("transferSucceeded refusé : sender non propriétaire du transfert")
                return
            }

            guard !transferManager.isTerminal(
                transferID: payload.transferID
            ) else {
                logger.info("transferSucceeded déjà traité : \(payload.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: payload.transferID
            )

            transferManager.markCompleted(
                transferID: payload.transferID,
                transferredBytes: payload.receivedBytes
            )

            // Notification: transfert envoyé terminé avec succès
            if notificationManager.checkNotNotified(payload.transferID) {
                notificationManager.notifyTransferCompleted(
                    direction: .sent,
                    fileCount: 1,
                    deviceName: message.sender.name
                )
            }

            finishOutgoingTransfer(
                transferID: payload.transferID
            )


            logger.info("Fichier reçu et enregistré par le destinataire")
            logger.info("Transfert : \(payload.transferID, privacy: .public)")

        } catch {
            logger.error(
                "transferSucceeded invalide : \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    

    
    
    private func handleTransferFailed(
        message: AirBridgeMessage
    ) {
        guard let payloadData = message.payload else {
            logger.error("transferFailed sans payload")
            return
        }

        do {
            let payload = try messageCodec.decodePayload(
                TransferFailedPayload.self,
                from: payloadData
            )

            guard senderOwnsTransfer(
                payload.transferID,
                sender: message.sender
            ) else {
                logger.error("transferFailed refusé : sender non propriétaire du transfert")
                return
            }

            guard !transferManager.isTerminal(
                transferID: payload.transferID
            ) else {
                logger.info("transferFailed déjà traité : \(payload.transferID, privacy: .public)")
                return
            }

            transferTimeoutManager.cancel(
                transferID: payload.transferID
            )
            transferManager.markFailed(
                transferID: payload.transferID
            )

            finishOutgoingTransfer(
                transferID: payload.transferID
            )

            logger.error("Le destinataire n’a pas pu finaliser le transfert")
            logger.info("Motif : \(payload.reason, privacy: .public)")

        } catch {
            logger.error(
                "transferFailed invalide : \(error.localizedDescription, privacy: .public)"
            )
        }

        // Notification: transfert échoué
        do {
            let payload = try messageCodec.decodePayload(
                TransferFailedPayload.self,
                from: payloadData
            )
            if notificationManager.checkNotNotified(payload.transferID) {
                if let transfer = transferManager.transfers.first(where: { $0.id == payload.transferID }) {
                    notificationManager.notifyTransferFailed(
                        fileName: transfer.fileName,
                        deviceName: message.sender.name,
                        reason: payload.reason
                    )
                }
            }
        } catch {
            logger.error("Impossible de décoder payload pour notification : \(error.localizedDescription, privacy: .public)")
        }
    }





    /// Accepte le lot de demandes en attente et en prévient l'émetteur.
    ///
    /// L'acceptation est **transmise avant** d'être affichée localement.
    /// Auparavant, `markAccepted` précédait un envoi dont le résultat était
    /// ignoré : quand l'émission échouait (session tombée entre la demande
    /// et le geste, connexion périmée, clé de session absente), le
    /// récepteur affichait « Accepté » pendant que l'émetteur restait
    /// « En attente » — les deux écrans se contredisaient et rien ne se
    /// terminait jamais. En cas d'échec d'émission, le transfert entrant
    /// passe en échec avec un motif explicite.
    func acceptPendingTransfer() {
        let requests = pendingRequests()

        guard !requests.isEmpty else {
            logger.info("Aucune demande de transfert à accepter")
            return
        }

        var acceptedCount = 0

        for request in requests {
            let transferID = request.request.transferID

            let sent = connectionManager.sendTransferAccepted(
                transferID: transferID,
                on: request.connection
            )

            guard sent else {
                logger.error("Acceptation non transmise à l’émetteur : \(request.request.fileName, privacy: .public)")

                transferManager.markFailed(
                    transferID: transferID,
                    reason: "Acceptation non transmise à l’émetteur"
                )
                transferManager.cancelIncomingTransfer(
                    transferID: transferID
                )
                continue
            }

            transferManager.markAccepted(
                transferID: transferID
            )
            acceptedCount += 1

            logger.info("Demande acceptée : \(request.request.fileName, privacy: .public)")
        }

        logger.info(
            "Autorisation groupée : \(acceptedCount)/\(requests.count) fichier(s) accepté(s)"
        )

        pendingApprovalCoordinator.clear()
    }

    func rejectPendingTransfer(
        reason: String? = nil
    ) {
        let requests = pendingRequests()

        guard !requests.isEmpty else {
            logger.info("Aucune demande de transfert à refuser")
            return
        }

        for request in requests {
            let transferID = request.request.transferID
            transferManager.markRejected(
                transferID: transferID,
                reason: reason
            )
            transferManager.cancelIncomingTransfer(
                transferID: transferID
            )

            // Le refus local est acquis (l'utilisateur a tranché) ; un échec
            // d'émission est tracé : l'émetteur retombera sur son propre
            // délai d'approbation plutôt que d'attendre indéfiniment.
            if !connectionManager.sendTransferRejected(
                transferID: transferID,
                reason: reason,
                on: request.connection
            ) {
                logger.error("Refus non transmis à l’émetteur : \(request.request.fileName, privacy: .public)")
            }

            logger.error("Demande refusée : \(request.request.fileName, privacy: .public)")
        }

        logger.error(
            "Autorisation groupée : \(requests.count) fichier(s) refusé(s)"
        )

        pendingApprovalCoordinator.clear()
    }
    
    
    func start() {
        bonjourService.startAdvertising()
        bonjourService.startDiscovery()
    }
    
    func stop() {
        connectionManager.disconnect()
        bonjourService.stopDiscovery()
        bonjourService.stopAdvertising()
    }

    // MARK: - Connexion automatique des pairs de confiance

    /// Redécouverte Bonjour d'un appareil : décide s'il faut ouvrir une
    /// connexion automatiquement.
    ///
    /// Deux motifs de connexion automatique :
    ///  1. des transferts interrompus attendent une reprise vers ce pair
    ///     (comportement historique : la redécouverte fournit la seule
    ///     endpoint fraîche après une coupure) ;
    ///  2. le pair est **de confiance** (pairage confirmé) : la connexion
    ///     s'établit toute seule, comme promis à l'utilisateur au moment
    ///     du pairage (« Faire confiance permettra à cet appareil de se
    ///     reconnecter automatiquement »).
    ///
    /// Garde-fous : aucune connexion si une session est déjà active, si le
    /// pair est bloqué, si l'utilisateur vient de se déconnecter
    /// explicitement de ce pair, et selon le backoff d'`AutoConnectPolicy`
    /// (fenêtre croissante : 15 s → 240 s ; Bonjour redéclenche cet
    /// événement très fréquemment). La préférence utilisateur
    /// « Connexion automatique » (Réglages) ne masque que le motif
    /// « pair de confiance » : les reprises de transfert restent actives.
    private func handleDeviceDiscovered(
        _ discovered: DiscoveredDevice
    ) {
        let device = discovered.device

        guard connectionManager.session == nil else { return }

        let hasInterruptedForPeer = transferManager.transfers.contains {
            $0.state == .interrupted && $0.peer.id == device.id
        }

        let isTrustedPeer = pairingStore.isTrusted(device.id)

        // Décision déléguée à la politique pure (réglage utilisateur,
        // blocage, déconnexion explicite, backoff exponentiel) — testable
        // en isolation via `AutoConnectPolicyTests`.
        let decision = AutoConnectPolicy.evaluate(
            hasSession: connectionManager.session != nil,
            hasPendingResume: hasInterruptedForPeer,
            isTrusted: isTrustedPeer,
            isBlocked: pairingStore.isBlocked(device.id),
            isUserDisconnected: autoConnectSuppressedPeers.contains(
                device.id
            ),
            autoConnectEnabled: AutoConnectPolicy.isEnabled(),
            lastAttempt: lastAutoConnectAttempts[device.id],
            failureCount: autoConnectFailureCounts[device.id] ?? 0
        )

        guard case .connect = decision else {
            if case let .skip(reason) = decision {
                logger.debug(
                    "Auto-connexion de \(device.name, privacy: .public) ignorée : \(String(describing: reason), privacy: .public)"
                )
            }
            return
        }

        if hasInterruptedForPeer {
            logger.info("Pair redécouvert avec reprises en attente : \(device.name, privacy: .public)")
        } else {
            logger.info("Pair de confiance redécouvert : connexion automatique vers \(device.name, privacy: .public)")
        }

        lastAutoConnectAttempts[device.id] = Date()
        lastKnownPeerID = device.id
        connectionManager.rememberConnectedPeer(device)
        // La redécouverte fournit une endpoint fraîche : c'est la seule
        // porte de sortie après une campagne invalidée par un échec. La
        // campagne elle-même ne s'ouvrira qu'à la confirmation `.ready`
        // (via `onSessionReady`), avec une seule tâche par transfert.
        connectionManager.connect(to: discovered)

        // Un envoi ciblé programmé vers CE pair peut démarrer d'ici :
        // la session ouverte par `connect` déclenchera la consommation
        // à `installSessionKeyAndMarkReady`.
        expireScheduledTargetedSendIfStale()
    }

    /// Met à jour l'ensemble des pairs actuellement découverts et lève la
    /// suspension de connexion automatique des pairs qui avaient quitté le
    /// réseau (absents du nouveau jeu de résultats).
    ///
    /// Appelé depuis `BonjourService.onDiscoveryResultsChanged` à chaque
    /// changement du jeu — y compris quand le jeu devient vide : c'est le
    /// cas que l'ancien point d'appui (boucle par appareil dans
    /// `handleDeviceDiscovered`) ne pouvait jamais observer, ce qui
    /// laissait la suspension « déconnexion explicite » collée même après
    /// un aller-retour du pair hors réseau.
    private func updateDiscoveredPeerPresence(current: Set<UUID>) {
        let disappeared = previouslyDiscoveredPeerIDs.subtracting(current)

        if !disappeared.isEmpty {
            autoConnectSuppressedPeers.subtract(disappeared)
            for peerID in disappeared {
                lastAutoConnectAttempts.removeValue(forKey: peerID)
                autoConnectFailureCounts.removeValue(forKey: peerID)
            }
        }

        previouslyDiscoveredPeerIDs = current
    }

    /// Connexion demandée explicitement par l'utilisateur (radar, liste
    /// d'appareils).
    ///
    /// Lève la suspension de connexion automatique vers ce pair : une
    /// reconnexion manuelle après une déconnexion volontaire rétablit le
    /// comportement automatique pour la suite.
    func connect(to discovered: DiscoveredDevice) {
        autoConnectSuppressedPeers.remove(discovered.device.id)
        connectionManager.connect(to: discovered)
    }

    /// Déconnexion demandée explicitement par l'utilisateur.
    ///
    /// Suspend la connexion automatique vers le pair concerné : sans cela,
    /// le prochain événement Bonjour (ils sont fréquents) reconnecterait
    /// immédiatement l'appareil que l'utilisateur vient juste de
    /// déconnecter. La suspension est levée au retour du pair sur le
    /// réseau ou à la prochaine connexion manuelle.
    func disconnectFromPeer() {
        if let peer = connectionManager.connectedDevice
            ?? connectionManager.lastConnectedPeer {
            autoConnectSuppressedPeers.insert(peer.id)
        }
        connectionManager.disconnect()
    }

    // MARK: - Envoi ciblé programmé (« Envoyer à <dernier appareil> »)

    /// Programme l'envoi d'`urls` vers `peer` :
    ///  - si la session avec CE pair est déjà sécurisée → envoi
    ///    immédiat (`onTargetedSendFinished` émis) ;
    ///  - sinon → mémorisation de l'intention + déclenchement d'une
    ///    connexion vers ce pair s'il est découvert (la découverte
    ///    alimente aussi l'auto-connexion), l'envoi partant à la
    ///    confirmation de la session sécurisée, dans la limite de
    ///    `targetedSendLifetime`.
    ///
    /// Point d'appui de la feuille de partage (macOS : bouton
    /// « Envoyer à <X> » de l'extension Finder via directive, puis
    /// sélection d'un destinataire non connecté dans `ShareView`).
    ///
    /// - Returns: `true` si l'envoi est parti ou bien programmé.
    @discardableResult
    func scheduleTargetedSend(
        urls: [URL],
        to peer: Device
    ) -> Bool {
        guard !urls.isEmpty else { return false }

        expireScheduledTargetedSendIfStale()

        // Envoi immédiat si la bonne session est déjà sécurisée.
        if connectionManager.isSecureSessionReady,
           connectionManager.connectedDevice?.id == peer.id {
            let accepted = importAndRequestItems(urls: urls)
            onTargetedSendFinished?(peer.id, accepted)
            return accepted
        }

        // Programmation : un seul envoi ciblé à la fois.
        scheduledTargetedSend = ScheduledTargetedSend(
            recipientID: peer.id,
            urls: urls,
            issuedAt: Date()
        )
        scheduledTargetedSendPeerName = peer.name
        logger.info(
            "Envoi ciblé programmé vers \(peer.name, privacy: .public) (\(urls.count) fichier(s)) — en attente de session sécurisée"
        )

        // Lever une éventuelle suspension « déconnexion explicite » :
        // l'utilisateur demande explicitement une connexion à CE pair.
        autoConnectSuppressedPeers.remove(peer.id)

        // Tenter la connexion tout de suite si le pair est découvert.
        if let discovered = bonjourService.discoveredDevices.first(
            where: { $0.device.id == peer.id }
        ) {
            lastAutoConnectAttempts[peer.id] = Date()
            lastKnownPeerID = peer.id
            connectionManager.rememberConnectedPeer(peer)
            connectionManager.connect(to: discovered)
        }

        return true
    }

    /// Abandonne l'envoi ciblé programmé (annulation utilisateur).
    func cancelScheduledTargetedSend() {
        guard scheduledTargetedSend != nil else { return }
        scheduledTargetedSend = nil
        scheduledTargetedSendPeerName = nil
        logger.info("Envoi ciblé programmé annulé")
    }

    /// Abandon l'envoi programmé s'il est expiré (appel de propreté à
    /// chaque redécouverte — la consommation vérifie aussi sa propre
    /// validité au moment de partir).
    private func expireScheduledTargetedSendIfStale() {
        guard let pending = scheduledTargetedSend else { return }
        guard Date().timeIntervalSince(pending.issuedAt)
                > Self.targetedSendLifetime else { return }

        scheduledTargetedSend = nil
        scheduledTargetedSendPeerName = nil
        logger.warning(
            "Envoi ciblé programmé expiré (aucune session sécurisée avec le destinataire)"
        )
        onTargetedSendFinished?(pending.recipientID, false)
    }

    /// Consomme l'envoi ciblé programmé quand la session sécurisée avec
    /// le BON pair est établie. Appelé à chaque installation de clé de
    /// session — idempotent : sans envoi programmé ou sans
    /// correspondance d'identifiant, c'est un no-op.
    private func consumeScheduledTargetedSendIfReady() {
        expireScheduledTargetedSendIfStale()
        guard let pending = scheduledTargetedSend else { return }
        guard connectionManager.isSecureSessionReady,
              connectionManager.connectedDevice?.id == pending.recipientID
        else { return }

        scheduledTargetedSend = nil
        scheduledTargetedSendPeerName = nil

        logger.info(
            "Session sécurisée avec le destinataire — envoi ciblé déclenché"
        )
        let accepted = importAndRequestItems(urls: pending.urls)
        onTargetedSendFinished?(pending.recipientID, accepted)
    }

    /// Relance complètement la pile Bonjour (navigateur + écouteur) —
    /// utilisé par « Relancer la recherche » et les bandeaux d'incident,
    /// en particulier quand macOS cesse de détecter un appareil déjà
    /// vu (réveil, bascule réseau, état `.failed` non traité avant).
    func forceRestartDiscovery() {
        bonjourService.restartMonitoring()
    }

    /// Retour au premier plan de l'application (appelé par
    /// `AirBridgeApp` sur `scenePhase == .active`).
    ///
    /// Laisse la pile Bonjour se resynchroniser si elle est dégradée :
    /// c'est le seul moyen de capter une autorisation « Réseau local »
    /// accordée dans Réglages pendant que l'app était en arrière-plan
    /// — iOS laisse sinon le navigateur `.waiting(PolicyDenied)` sans
    /// jamais réessayer.
    func refreshDiscoveryIfNeeded() {
        bonjourService.handleApplicationDidBecomeActive()
    }

    func cancelTransfer(
        transferID: UUID
    ) {
        // Une reprise automatique en cours ne doit pas survivre à une
        // annulation explicite de l'utilisateur.
        cancelAutomaticResumeTask(for: transferID)

        guard outgoingTransferQueue.contains(transferID) else {
            return
        }

        let wasActive = outgoingTransferQueue.isActive(transferID)

        // Récupérer le nom du fichier avant le nettoyage pour la notification
        let transfer = transferManager.transfers.first(where: { $0.id == transferID })

        if !wasActive {
            _ = outgoingTransferQueue.cancel(transferID: transferID)
            transferManager.markCancelled(
                transferID: transferID
            )
            transferManager.cleanupOutgoingTransfer(
                transferID: transferID
            )

            // Notification: transfert en attente annulé par l'utilisateur local
            if let transfer,
               notificationManager.checkNotNotified(transferID) {
                notificationManager.notifyTransferCancelled(
                    fileName: transfer.fileName,
                    deviceName: transfer.peer.name,
                    cancelledBy: .localUser
                )
            }
            return
        }

        transferTimeoutManager.cancel(
            transferID: transferID
        )

        connectionManager.sendTransferCancelled(
            transferID: transferID,
            reason: "Annulé par l’utilisateur"
        )

        transferManager.markCancelled(
            transferID: transferID
        )

        finishOutgoingTransfer(
            transferID: transferID
        )

        // Notification: transfert actif annulé par l'utilisateur local
        if let transfer,
           notificationManager.checkNotNotified(transferID) {
            notificationManager.notifyTransferCancelled(
                fileName: transfer.fileName,
                deviceName: transfer.peer.name,
                cancelledBy: .localUser
            )
        }
    }

    /// Annule un transfert interrompu : terminal, nettoyage complet des
    /// ressources de reprise (source sortante, `.partial`, métadonnées).
    func cancelInterruptedTransfer(transferID: UUID) {
        cancelAutomaticResumeTask(for: transferID)

        guard let transfer = transferManager.transfers.first(where: {
            $0.id == transferID
        }), transfer.state == .interrupted else {
            return
        }

        transferManager.markCancelled(
            transferID: transferID
        )
        transferManager.cleanupTransfer(transferID: transferID)

        _ = outgoingTransferQueue.cancel(transferID: transferID)
        startedOutgoingTransfers.remove(transferID)

        if notificationManager.checkNotNotified(transferID) {
            notificationManager.notifyTransferCancelled(
                fileName: transfer.fileName,
                deviceName: transfer.peer.name,
                cancelledBy: .localUser
            )
        }
    }

    /// Tente de reprendre un transfert interrompu, dans le sens qui convient.
    ///
    /// Réception : rouvre le `.partial` à l'offset disque et demande au pair
    /// de repartir de là. Envoi : annonce au pair l'offset déjà reçu pour que
    /// la source locale reprenne son envoi. Sans session active avec le peer,
    /// l'appel est sans effet : le transfert reste `.interrupted` et pourra
    /// être repris plus tard (manuellement ou à la reconnexion).
    func resumeTransfer(_ id: UUID) {
        guard let transfer = transferManager.transfers.first(where: {
            $0.id == id
        }), transfer.state == .interrupted else {
            logger.info("Reprise demandée sur un transfert non interrompu : \(id, privacy: .public)")
            return
        }

        // Garde anti-double-reprise : jamais deux tentatives simultanées
        // pour un même transfert.
        guard resumeTasks[id] == nil else {
            logger.info("Une reprise est déjà en cours : \(id, privacy: .public)")
            return
        }

        switch transfer.direction {
        case .incoming:
            startIncomingResume(transferID: id)

        case .outgoing:
            startOutgoingResume(transferID: id)
        }
    }

    private func startIncomingResume(transferID: UUID) {
        // Rouvrir le writer et installer son contexte de chunk avant
        // d'annoncer l'offset au pair. Le transfert reste bloqué si la
        // session ECDH n'est pas prête.
        guard connectionManager.isSecureSessionReady,
              let transfer = transferManager.transfers.first(where: {
                  $0.id == transferID
              }),
              transfer.direction == .incoming,
              transfer.peer.id == connectionManager.connectedDevice?.id else {
            logger.info("Reprise entrante reportée : session sécurisée ou pair non correspondant")
            return
        }

        let offset = transferManager.incomingPartialFileBytes(
            transferID: transferID
        )

        guard offset > 0 else {
            logger.error("Reprise impossible : aucun octet déjà reçu (\(transferID, privacy: .public))")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.transferManager.reopenIncomingWriterAndWait(
                transferID: transferID,
                atOffset: offset
            ) else {
                self.logger.error("Reprise impossible : fichier partiel inaccessible")
                return
            }

            guard self.transferManager.resumeIncomingTransfer(
                transferID: transferID,
                connectionManager: self.connectionManager
            ) else {
                return
            }

            self.logger.info("Reprise entrante demandée : \(transferID, privacy: .public) à \(offset)")
        }
    }

    private func startOutgoingResume(transferID: UUID) {
        // Garde stricte : la session doit être confirmée `.ready`. Une
        // session en préparation existe déjà mais ne peut rien transporter ;
        // le resumeRequest partirait dans la file d'une connexion qui
        // expirera peut-être sans jamais l'émettre.
        guard connectionManager.isSessionReady,
              connectionManager.isSecureSessionReady,
              connectionManager.connectedDevice?.id == transferManager.transfers
                  .first(where: { $0.id == transferID })?.peer.id else {
            logger.info("Pair non connecté : reprise reportée (\(transferID, privacy: .public))")
            return
        }

        let resumedTransfer = transferManager.transfers.first {
            $0.id == transferID
        }

        let transferredBytes = resumedTransfer?
            .transferredBytes ?? 0

        guard transferredBytes > 0 else {
            logger.info("Rien n'a encore été envoyé : relance classique plutôt que reprise")
            return
        }

        // Le SHA-256 de la source, s'il a été calculé au premier envoi,
        // accompagne la demande ; sinon il reste vide et le récepteur
        // ignore ce champ (l'intégrité finale repose sur le SHA-256
        // complet du transfert terminé).
        connectionManager.sendResumeRequest(
            transferID: transferID,
            receivedBytes: transferredBytes,
            fileSize: resumedTransfer?.fileSize ?? 0,
            fileName: resumedTransfer?.fileName ?? "",
            chunkSize: TransferChunkSizing.chunkSize(
                forFileSize: resumedTransfer?.fileSize ?? 0
            ),
            sha256: resumedTransfer?.sha256 ?? ""
        )

        logger.info("Reprise sortante demandée : \(transferID, privacy: .public) à \(transferredBytes)")
    }

    // MARK: - Reprise automatique après reconnexion

    /// Au rétablissement de la session avec un pair : tente une reprise
    /// automatique des transferts interrompus de ce pair.
    ///
    /// Bornée : une seule campagne à la fois, au plus quatre tentatives par
    /// transfert selon le backoff `automaticResumeBackoffs` (2 s / 5 s /
    /// 10 s / 20 s), tâches annulables (annulation utilisateur ou reprise
    /// effective). Après épuisement le transfert reste `.interrupted`, la
    /// reprise manuelle reste possible.
    private func scheduleAutomaticResumeOnReconnect() {
        // Unicité de campagne : si une campagne tourne déjà, ne rien
        // rouvrir. Les tâches existantes sont les seules à décider.
        guard !isResumeCampaignActive else { return }
        isResumeCampaignActive = true

        // La session fraîchement établie identifie le pair fiable : c'est
        // lui qui décide des transferts à relancer, pas un souvenir obsolète.
        guard let peerID = connectionManager.connectedDevice?.id
                ?? lastKnownPeerID else {
            isResumeCampaignActive = false
            return
        }

        let interrupted = transferManager.transfers.filter {
            $0.state == .interrupted && $0.peer.id == peerID
        }

        guard !interrupted.isEmpty else {
            isResumeCampaignActive = false
            return
        }

        logger.info("Reprise automatique candidate pour \(interrupted.count) transfert(s)")

        for transfer in interrupted {
            startAutomaticResumeTask(for: transfer.id)
        }
    }

    /// Reprise déclenchée depuis la tâche automatique : la garde
    /// anti-double-reprise est déjà tenue par `resumeTasks` (une seule
    /// tâche par identifiant), on court-circuite donc la vérification de
    /// `resumeTransfer` qui sinon verrait sa propre tâche.
    private func attemptResumeIgnoringRunningTask(_ id: UUID) {
        guard let transfer = transferManager.transfers.first(where: {
            $0.id == id
        }), transfer.state == .interrupted else {
            return
        }

        switch transfer.direction {
        case .incoming:
            startIncomingResume(transferID: id)
        case .outgoing:
            startOutgoingResume(transferID: id)
        }
    }

    /// Backoff de la reprise automatique : croissance douce pour laisser le
    /// réseau se reformer, plafonnée à vingt secondes.
    private static let automaticResumeBackoffs: [UInt64] = [2, 5, 10, 20]

    private func startAutomaticResumeTask(for transferID: UUID) {
        guard resumeTasks[transferID] == nil else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            for seconds in Self.automaticResumeBackoffs {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)

                if Task.isCancelled {
                    // La campagne peut avoir été invalidée (échec de
                    // connexion) : ne rien relancer, attendre une
                    // redécouverte fraîche.
                    return
                }

                guard let transfer = self.transferManager.transfers.first(
                    where: { $0.id == transferID }
                ), transfer.state == .interrupted else {
                    // Repris ou annulé entre-temps : cette tâche s'achève,
                    // les autres continuent leur propre campagne.
                    self.finishResumeTask(for: transferID)
                    return
                }

                // Garde stricte : seule une session confirmée `.ready` et
                // visant le pair du transfert autorise une tentative. Une
                // session en préparation ou en attente ne consomme pas de
                // créneau — on patiente jusqu'au prochain délai.
                guard self.connectionManager.isSessionReady,
                      self.connectionManager.connectedDevice?.id == transfer.peer.id else {
                    continue
                }

                self.attemptResumeIgnoringRunningTask(transferID)

                // Si la reprise a pris (état quitté `.interrupted`),
                // cette tâche s'achève ; sinon retenter au prochain délai.
                if self.transferManager.transfers.first(where: {
                    $0.id == transferID
                })?.state != .interrupted {
                    self.finishResumeTask(for: transferID)
                    return
                }
            }

            // Tentatives épuisées : reste `.interrupted`.
            self.finishResumeTask(for: transferID)
            logger.info("Reprise automatique abandonnée : \(transferID, privacy: .public)")
        }

        resumeTasks[transferID] = task
    }

    /// Achève la tâche de reprise d'un transfert. Quand la dernière tâche
    /// d'une campagne se termine, la campagne entière est close : le verrou
    /// est levé pour qu'une prochaine session puisse en rouvrir une.
    private func finishResumeTask(for transferID: UUID) {
        resumeTasks[transferID] = nil

        guard resumeTasks.isEmpty else { return }

        isResumeCampaignActive = false
    }

    /// Invalide toute la campagne : la session est tombée, l'endpoint sur
    /// laquelle elle s'appuyait n'a plus de sens. Les tâches sont annulées
    /// et seule une redécouverte fraîche pourra rouvrir une campagne.
    private func endResumeCampaign() {
        isResumeCampaignActive = false

        for (id, task) in resumeTasks {
            task.cancel()
            resumeTasks[id] = nil
        }
    }

    /// Annulation utilisateur (du transfert ou de sa reprise) : la tâche
    /// est annulée puis retirée comme toute fin de tâche. Passer par
    /// `finishResumeTask` évite de laisser le verrou de campagne levé quand
    /// le dernier transfert interrompu disparaît — sans quoi plus aucune
    /// campagne automatique ne pourrait s'ouvrir pour ce pair.
    ///
    /// `Task.cancel` est idempotent : l'appel redondant avec celui du bloc
    /// de la tâche (qui passe aussi par `finishResumeTask`) est sans effet.
    private func cancelAutomaticResumeTask(for transferID: UUID) {
        resumeTasks[transferID]?.cancel()
        finishResumeTask(for: transferID)
    }

    /// Taille réelle d'un fichier sur disque, `0` si illisible.
    private static func onDiskBytes(of url: URL) -> Int64 {
        guard let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return 0
        }
        return Int64(size)
    }

    /// Décision de restauration pour une métadonnée de reprise : renvoie
    /// les octets réconciliés à restaurer, ou `nil` si la métadonnée est
    /// orpheline (le `.partial` n'existe plus, rien à reprendre).
    ///
    /// Côté réception, le fichier local est le `.partial`. Côté émission,
    /// c'est la copie de travail — et si elle a disparu (purge du dossier
    /// temporaire au redémarrage), l'original référencé par
    /// `sourceFileURL` suffit : un envoi repart de zéro plutôt que d'être
    /// purgé comme orphelin.
    ///
    /// Extraite de la boucle de démarrage pour rester testable isolément.
    static func resolvedRestorationBytes(
        for info: ResumeTransferInfo
    ) -> Int64? {
        let localDataURL = info.partialFileURL

        let onDisk = FileManager.default.fileExists(atPath: localDataURL.path)
            ? onDiskBytes(of: localDataURL)
            : 0

        if onDisk > 0 {
            // La taille réelle sur disque fait foi : un `.partial`
            // tronqué est repris à sa taille, jamais au-delà des
            // métadonnées.
            return ResumeTransferInfo.reconciledTransferredBytes(
                metadataBytes: info.transferredBytes,
                onDiskBytes: onDisk
            )
        }

        // Pas de fichier local exploitable : seul un envoi dont la source
        // originale existe encore reste restaurable (reprise à zéro).
        let isOutgoing = info.direction == "outgoing"
        let hasLivingSource = info.sourceFileURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false

        guard isOutgoing, hasLivingSource else {
            return nil
        }

        return 0
    }
}

/// Erreur levée par le pipeline d'envoi (`runChunkPipeline`) quand la
/// somme des octets effectivement envoyés ne correspond pas à la taille
/// de fichier annoncée. Indique une perte de chunks dans le pipeline
/// (historiquement causée par une politique de buffering qui écrasait
/// les chunks les plus récents) et provoque l'échec du transfert
/// plutôt qu'un `transferCompleted` mensonger.
struct PipelineIntegrityError: Error, CustomStringConvertible {
    let expected: Int64
    let sent: Int64
    let chunks: Int

    var description: String {
        "PipelineIntegrityError: attendu \(expected) octets, envoyé \(sent) (\(chunks) chunks)"
    }
}

