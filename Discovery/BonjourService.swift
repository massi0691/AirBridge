//
//  BonjourService.swift
//  AirBridge
//
//  Created by massi9106 on 19/07/2026.
//

import Foundation
import Network
import OSLog

#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class BonjourService {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "discovery.bonjour"
    )

    /// Logger statique utilisé depuis les closures NWListener / NWBrowser
    /// où `self` n'est pas capturé (évite de dupliquer les logs).
    /// `nonisolated` car les callbacks Network ne sont pas `@MainActor`
    /// et ne peuvent pas capturer une propriété isolée.
    nonisolated private static let staticLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Massinissa.AirBridge",
        category: "discovery.bonjour"
    )

    private var listener: NWListener?
    private var browser: NWBrowser?

    // MARK: - Résilience de la pile Bonjour (issue « iPhone parfois
    // non détecté »)

    /// Surveillance du chemin réseau. Un basculement d'interface
    /// (Wi-Fi ↔ Ethernet, VPN, réveil, réassociation peer-to-peer)
    /// laisse `NWBrowser`/`NWListener` mordus sur d'anciennes
    /// adresses : sans redémarrage, la recherche reste « ready »
    /// silencieusement et le radar ne voit plus jamais l'iPhone.
    private var pathMonitor: NWPathMonitor?

    /// Signature (noms d'interfaces) du dernier chemin réseau observé.
    private var lastInterfaceSignature: String = ""

    /// Compteurs de repli après `.failed` (backoff borné) — un
    /// échec terminal ne laisse plus jamais le service inerte jusqu'au
    /// redémarrage de l'app.
    private var browserFailureCount: Int = 0
    private var listenerFailureCount: Int = 0
    private var browserRetryTask: Task<Void, Never>?
    private var listenerRetryTask: Task<Void, Never>?

    /// Observateur macOS du réveil système (token non retiré : le
    /// `BonjourService` vit aussi longtemps que l'app).
    private var wakeObserver: NSObjectProtocol?

    /// Backoff de repli Bonjour : 3 s, 6 s, 12 s, 24 s, 48 s, plafonné
    /// à 60 s. Exposé `nonisolated` pour les tests unitaires.
    nonisolated static let retryBaseDelay: TimeInterval = 3
    nonisolated static let retryMaxDelay: TimeInterval = 60

    nonisolated static func retryDelay(afterFailureCount failureCount: Int) -> TimeInterval {
        let clamped = max(0, failureCount)
        let multiplier = clamped >= 60
            ? TimeInterval.greatestFiniteMagnitude
            : pow(2.0, Double(clamped))
        return min(retryBaseDelay * multiplier, retryMaxDelay)
    }

    // MARK: - État Bonjour observable (diagnostic)

    /// Le service `_airbridge._tcp` est publié et le port d'écoute est
    /// ouvert : l'appareil peut **recevoir** des connexions.
    private(set) var isAdvertisingReady = false

    /// La recherche Bonjour est active : l'appareil peut **découvrir** les
    /// pairs à proximité.
    private(set) var isBrowsingReady = false

    /// L'accès au réseau local a été refusé par le système (iOS 14+ /
    /// macOS 15+). Cause la plus fréquente d'un radar vide et d'un
    /// transfert qui ne démarre jamais : sans cette autorisation, ni la
    /// découverte ni la publication ne fonctionnent, et aucun pair ne peut
    /// répondre à une annonce.
    private(set) var isLocalNetworkAuthorizationDenied = false

    let localDevice: Device

    private(set) var discoveredDevices: [DiscoveredDevice]  = []

    /// Dernier incident de la publication Bonjour (`NWListener`).
    private var advertisingIssue: String?

    /// Dernier incident de la recherche Bonjour (`NWBrowser`).
    private var browsingIssue: String?

    /// Message destiné à l'UI quand la couche Bonjour ne peut pas
    /// fonctionner normalement : autorisation « Réseau local » refusée
    /// (macOS 15+ / iOS 14+), réseau indisponible, publication
    /// impossible… `nil` quand tout va bien.
    ///
    /// Sans cet état, un refus d'autorisation se traduisait par un radar
    /// vide à l'infini, sans cause visible : les erreurs de `NWBrowser`
    /// et `NWListener` n'existaient que dans les logs, et l'utilisateur
    /// n'avait aucune action à sa disposition.
    ///
    /// La recherche est prioritaire dans le message : c'est elle qui
    /// conditionne l'apparition des appareils dans l'interface.
    var localNetworkIssue: String? {
        browsingIssue ?? advertisingIssue
    }


    var onIncomingConnection: ((NWConnection) -> Void)?

    /// Signalé à chaque (re)découverte d'un appareil : permet au cœur de
    /// rattacher une reprise en attente à un pair qui redevient visible.
    /// La résultat complet (`DiscoveredDevice`) est transmis pour que la
    /// connexion reparte d'une endpoint fraîche plutôt que d'une adresse
    /// périmée.
    var onDeviceDiscovered: ((DiscoveredDevice) -> Void)?

    /// Signalé à CHAQUE changement du jeu de résultats Bonjour, avec
    /// l'ensemble complet des identifiants encore présents (même vide).
    ///
    /// C'est la seule source qui voit réellement les DÉPARTS : le
    /// `onDeviceDiscovered` ci-dessus n'est invoqué que pour les
    /// appareils présents — quand le dernier pair quitte le réseau, la
    /// boucle est vide et la levée de suspension d'auto-connexion n'aurait
    /// jamais lieu. Le cœur consomme ce callback pour mettre à jour la
    /// présence avant d'évaluer les connexions automatiques.
    var onDiscoveryResultsChanged: ((Set<UUID>) -> Void)?

    init(localDevice: Device){
        self.localDevice = localDevice
        startPathMonitor()
        observeSystemWake()
    }
   
    
    func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
         
         let parameters = NWParameters(
             tls: nil,
             tcp: tcpOptions
         )
         
         parameters.includePeerToPeer = true
         
      return parameters
    }

    // MARK: - Diagnostic réseau local

    /// `kDNSServiceErr_PolicyDenied` — le code que remontent
    /// réellement iOS 14+ / macOS 15+ quand l'application n'a pas
    /// l'accès au réseau local. C'est lui qui apparaît dans les
    /// journaux système :
    /// `nw_browser_fail_on_dns_error_locked [B1] … PolicyDenied(-65570)`
    /// et `-[_NWAdvertiser …] advertising denied by policy`.
    ///
    /// Il était absent de la détection : le refus le plus fréquent
    /// n'était donc **jamais** identifié — radar vide sans bandeau,
    /// diagnostic annonçant « aucun refus signalé ».
    nonisolated static let policyDeniedCode = -65570

    /// `kDNSServiceErr_NoAuth` — variante documentée historiquement.
    nonisolated static let noAuthCode = -65555

    /// Même refus exprimé dans le domaine d'erreurs `NSNetServices`
    /// (remonté notamment par `NetService` et les API de plus haut
    /// niveau).
    nonisolated static let netServicesPolicyDeniedCode = -72008

    /// Vrai pour un code DNS qui trahit un REFUS d'autorisation du
    /// réseau local (et non une panne réseau transitoire) : le
    /// navigateur n'émet alors aucun résultat tant que l'autorisation
    /// n'est pas accordée.
    ///
    /// Exposé `nonisolated static` (et non `private`) : les tests
    /// verrouillent la liste des codes, seul endroit où un oubli se
    /// paie d'un radar vide inexpliqué.
    nonisolated static func isAuthorizationDenied(dnsCode: Int) -> Bool {
        dnsCode == policyDeniedCode
            || dnsCode == noAuthCode
            || dnsCode == netServicesPolicyDeniedCode
    }

    /// Vrai pour les erreurs Bonjour qui signalent un refus
    /// d'autorisation plutôt qu'un incident réseau transitoire.
    nonisolated static func isAuthorizationError(
        _ error: NWError
    ) -> Bool {
        guard case let .dns(code) = error else { return false }
        return Self.isAuthorizationDenied(dnsCode: Int(code))
    }

    /// Consigne d'accès au réglage « Réseau local », par plateforme :
    /// macOS ouvre les Réglages Système, iOS la page de l'application
    /// dans Réglages (qui porte l'interrupteur une fois l'accès
    /// demandé au moins une fois).
    nonisolated static var localNetworkRemediation: String {
        #if os(macOS)
        return "Vérifiez que « Réseau local » est autorisé pour AirBridge "
            + "(Réglages Système → Confidentialité et sécurité → "
            + "Réseau local)."
        #else
        return "Vérifiez que « Réseau local » est autorisé pour AirBridge "
            + "(Réglages → AirBridge → Réseau local)."
        #endif
    }

    /// Message affiché par l'UI pour expliquer qu'une étape Bonjour a
    /// échoué et indiquer l'action à effectuer. Le texte est construit
    /// ici (et non dans les vues) pour rester identique quel que soit
    /// l'écran qui l'affiche.
    nonisolated static func localNetworkHint(
        stage: String,
        error: Error
    ) -> String {
        "\(stage) : \(error.localizedDescription). \(Self.localNetworkRemediation)"
    }

    /// Consigne un refus d'accès au réseau local détecté par l'une ou
    /// l'autre moitié de la pile.
    ///
    /// Le refus est **global** à l'application : quand la recherche est
    /// bloquée, la publication l'est aussi — même si `NWListener`
    /// rapporte `.ready`. Sur iOS, la publication refusée
    /// (`-[_NWAdvertiser …] advertising denied by policy`) ne remonte
    /// aucun `.failed` : sans cette propagation, le diagnostic
    /// continuait d'annoncer « publication active » alors que personne
    /// ne pouvait nous joindre.
    ///
    /// Le message n'est journalisé qu'une fois : un refus durable
    /// n'arrose pas le journal à chaque changement d'état réseau.
    private func registerLocalNetworkDenial(issue: String, source: String) {
        if isLocalNetworkAuthorizationDenied {
            logger.debug(
                "Refus d'accès au réseau local toujours actif (signalé par \(source, privacy: .public))"
            )
        } else {
            logger.error(
                "Accès au réseau local refusé (signalé par \(source, privacy: .public)) : découverte et publication bloquées"
            )
        }

        isLocalNetworkAuthorizationDenied = true
        isBrowsingReady = false
        isAdvertisingReady = false
        if browsingIssue == nil { browsingIssue = issue }
        if advertisingIssue == nil { advertisingIssue = issue }
    }

    
    
    private func extractTXTRecord(from metadata: NWBrowser.Result.Metadata?) ->(
        id: UUID?, model:String?, systemVersion: String?
    ) {
        
        guard let metadata else {
            return (nil,nil,nil)
        }
        guard case let .bonjour(txtRecord) = metadata else {
              return (nil, nil, nil)
          }

          let idString = txtRecord["id"]
          let id = idString.flatMap { UUID(uuidString: $0) }

          let model = txtRecord["model"]
          let systemVersion = txtRecord["systemVersion"]

          return (id, model, systemVersion)
        
    }
    
    
    
    func startAdvertising() {

        guard listener == nil else {
            logger.info("La publication Bonjour est déjà active")
            return
        }

        let parameters = makeParameters()

        do {

            let newListener = try NWListener(
                using: parameters,
                on: .any
            )

            listener = newListener

            logger.info("Listener Bonjour créé")

            var txtRecord = NWTXTRecord()

            txtRecord["id"] = localDevice.id.uuidString
            txtRecord["model"] = localDevice.model
            txtRecord["systemVersion"] = localDevice.systemVersion

            logger.debug("Version système publiée : \(self.localDevice.systemVersion, privacy: .public)")

            newListener.service = NWListener.Service(
                name: localDevice.name,
                type: "_airbridge._tcp",
                txtRecord: txtRecord
            )

            logger.info("Service Bonjour publié")

            newListener.stateUpdateHandler = { state in

                switch state {

                case .ready:

                    if let port = newListener.port {
                        Self.staticLogger.info("Le service Bonjour est prêt sur le port \(port.rawValue)")
                    }

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.advertisingIssue = nil
                        self.isAdvertisingReady = true
                        // Succès : le compteur de repli repart à zéro.
                        self.listenerFailureCount = 0
                        self.listenerRetryTask?.cancel()
                        self.listenerRetryTask = nil
                    }

                case .failed(let error):

                    Self.staticLogger.error("Le listener a échoué : \(error.localizedDescription, privacy: .public)")

                    let issue = Self.localNetworkHint(
                        stage: "La publication d'AirBridge sur le réseau local a échoué",
                        error: error
                    )
                    let authorizationDenied = Self.isAuthorizationError(error)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isAdvertisingReady = false
                        if authorizationDenied {
                            self.registerLocalNetworkDenial(
                                issue: issue,
                                source: "la publication"
                            )
                        } else {
                            self.advertisingIssue = issue
                        }
                        // Repli symétrique au navigateur : sans relance,
                        // l'app devenait invisible pour les pairs après
                        // un échec terminal (changement de réseau, etc.).
                        self.scheduleListenerRestart()
                    }

                case .cancelled:

                    Self.staticLogger.info("Le listener a été arrêté")

                    Task { @MainActor [weak self] in
                        self?.advertisingIssue = nil
                        self?.isAdvertisingReady = false
                    }

                default:

                    Self.staticLogger.debug("État du listener : \(String(describing: state), privacy: .public)")
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in

                Task { @MainActor [weak self] in

                    guard let self else { return }

                    self.logger.info("Connexion entrante reçue")

                    self.onIncomingConnection?(connection)

                }

            }

            newListener.start(queue: .main)

        } catch {

            logger.error("Impossible de créer le listener : \(error.localizedDescription, privacy: .public)")

        }

    }
    
    func startDiscovery() {

        guard browser == nil else {
            logger.info("La recherche Bonjour est déjà active")
            return
        }

        let parameters = makeParameters()

        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: "_airbridge._tcp",
                domain: "local."
            ),
            using: parameters
        )

        browser = newBrowser

        newBrowser.stateUpdateHandler = { state in

            switch state {

            case .ready:
                Self.staticLogger.info("La recherche Bonjour est prête")

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.browsingIssue = nil
                    self.isBrowsingReady = true
                    self.isLocalNetworkAuthorizationDenied = false
                    // Succès : le compteur de repli repart à zéro.
                    self.browserFailureCount = 0
                    self.browserRetryTask?.cancel()
                    self.browserRetryTask = nil
                }

            case .failed(let error):
                Self.staticLogger.error("La recherche Bonjour a échoué : \(error.localizedDescription, privacy: .public)")

                let issue = Self.localNetworkHint(
                    stage: "La recherche d'appareils a échoué",
                    error: error
                )
                let authorizationDenied = Self.isAuthorizationError(error)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isBrowsingReady = false
                    if authorizationDenied {
                        self.registerLocalNetworkDenial(
                            issue: issue,
                            source: "la recherche"
                        )
                    } else {
                        self.browsingIssue = issue
                    }
                    // Repli : un `.failed` terminal laissait le
                    // navigateur inerte jusqu'au redémarrage de l'app
                    // (« l'iPhone n'est plus détecté »). On relance
                    // avec un backoff borné — y compris après un refus
                    // d'autorisation : la reprise suivante capte la
                    // permission accordée entre-temps dans Réglages.
                    self.scheduleBrowserRestart()
                }

            case .cancelled:
                Self.staticLogger.info("La recherche Bonjour a été arrêtée")

                Task { @MainActor [weak self] in
                    self?.browsingIssue = nil
                    self?.isBrowsingReady = false
                }

            case .setup:
                Self.staticLogger.debug("Le navigateur est configuré")

            case .waiting(let error):
                // Le refus d'accès au réseau local arrive LE PLUS
                // SOUVENT ici — et non dans `.failed` : le navigateur
                // passe `.ready` puis retombe `.waiting(PolicyDenied)`
                // (`nw_browser_fail_on_dns_error_locked … -65570`).
                // C'est ce chemin qui produisait un radar vide sans
                // bandeau tant que `-65570` n'était pas reconnu.
                let authorizationDenied = Self.isAuthorizationError(error)

                if authorizationDenied {
                    Self.staticLogger.error(
                        "Recherche bloquée : \(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    Self.staticLogger.debug("La recherche Bonjour attend : \(error.localizedDescription, privacy: .public)")
                }

                // Une attente n'est pas forcément une panne : on ne la
                // remonte à l'UI que lorsqu'elle trahit un refus
                // d'autorisation, sinon le bandeau clignoterait à chaque
                // reconfiguration réseau.
                if authorizationDenied {
                    let issue = Self.localNetworkHint(
                        stage: "La recherche d'appareils est bloquée",
                        error: error
                    )
                    Task { @MainActor [weak self] in
                        self?.registerLocalNetworkDenial(
                            issue: issue,
                            source: "la recherche"
                        )
                    }
                }

            @unknown default:
                Self.staticLogger.debug("État inconnu")
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in

            Task { @MainActor [weak self] in

                guard let self else { return }

                var devices: [DiscoveredDevice] = []

                for result in results {

                    guard case let .service(name, _, _, _) = result.endpoint else {
                        continue
                    }

                    let metadata = self.extractTXTRecord(
                        from: result.metadata
                    )

                    guard let deviceID = metadata.id else {
                        continue
                    }

                    guard deviceID != self.localDevice.id else {
                        continue
                    }

                    let device = Device(
                        id: deviceID,
                        name: name,
                        model: metadata.model ?? "Appareil inconnu",
                        systemVersion: metadata.systemVersion ?? "Système inconnu"
                    )

                    let discovered = DiscoveredDevice(
                        device: device,
                        endpoint: result.endpoint,
                        // NWBrowser.Result.metadata n'expose pas de
                        // signal exploitable côté Network.framework
                        // (seulement les TXT records Bonjour) : on
                        // passe nil plutôt que d'inventer une valeur.
                        // La vue radar marque alors visuellement la
                        // bulle pour signaler l'absence de métrique.
                        rssi: nil
                    )

                    devices.append(discovered)

                }

                self.discoveredDevices = devices

                // Présence AVANT les rappels par appareil : le cœur
                // observe les départs (y compris jeu vide) pour lever
                // les suspensions d'auto-connexion — cf. documentation
                // de `onDiscoveryResultsChanged`.
                self.onDiscoveryResultsChanged?(
                    Set(devices.map { $0.device.id })
                )

                for device in devices {
                    self.onDeviceDiscovered?(device)
                }

                self.logger.debug("\(devices.count) appareil(s) découvert(s)")

            }

        }

        newBrowser.start(queue: .main)

    }
    
    func stopAdvertising() {

        listenerRetryTask?.cancel()
        listenerRetryTask = nil

        guard listener != nil else {
            logger.info("Aucun service Bonjour à arrêter")
            return
        }

        listener?.cancel()
        listener = nil
        isAdvertisingReady = false

        logger.info("Publication Bonjour arrêtée")

    }

    func stopDiscovery() {

        browserRetryTask?.cancel()
        browserRetryTask = nil

        guard browser != nil else {
            logger.info("Aucune recherche Bonjour à arrêter")
            return
        }

        browser?.cancel()
        browser = nil
        isBrowsingReady = false

        discoveredDevices.removeAll()

        logger.info("Recherche Bonjour arrêtée")

    }

    // MARK: - Résilience

    /// Relance complète de la pile (navigateur + écouteur) sans vider
    /// la liste des appareils découverts : le radar conserve ses
    /// entrées le temps du nouveau browse, qui les remplace.
    ///
    /// Point d'appui de l'UI (« Relancer la recherche ») et des
    /// événements système (changement d'interface, réveil).
    func restartMonitoring() {
        logger.info("Redémarrage de la pile Bonjour")

        browserRetryTask?.cancel()
        browserRetryTask = nil
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        browserFailureCount = 0
        listenerFailureCount = 0

        browser?.cancel()
        browser = nil
        isBrowsingReady = false

        listener?.cancel()
        listener = nil
        isAdvertisingReady = false

        // Les deux redémarrages sont asynchrones (état `.ready`) mais
        // `start*` peut être rappelé immédiatement : le NWListener /
        // NWBrowser sont des objets neufs, aucun état résiduel.
        startDiscovery()
        startAdvertising()
    }

    /// Délai minimal entre deux relances déclenchées par un retour au
    /// premier plan : sans garde-fou, un va-et-vient rapide
    /// Réglages ⇄ AirBridge recréerait la pile à chaque aller-retour.
    nonisolated static let activationRestartThrottle: TimeInterval = 10

    /// Horodatage de la dernière relance automatique (retour au premier
    /// plan). `.distantPast` au démarrage : la première est immédiate.
    private var lastActivationRestartDate: Date = .distantPast

    /// Retour au premier plan de l'application.
    ///
    /// Cas couvert : l'utilisateur refusait l'accès au réseau local
    /// (`PolicyDenied`), va l'activer dans Réglages et revient. iOS ne
    /// réveille NI le navigateur NI l'écouteur dans ce cas — ils
    /// restent `.waiting(-65570)` indéfiniment. Seule une relance
    /// complète de la pile rétablit la découverte ; elle redéclenche
    /// aussi la demande d'autorisation si elle n'a jamais été
    /// présentée à l'utilisateur.
    ///
    /// Sans appel à cette méthode, l'application restait muette après
    /// un retour de Réglages jusqu'à son redémarrage manuel.
    func handleApplicationDidBecomeActive() {
        // Rien à relancer si la pile n'a jamais démarré.
        guard browser != nil || listener != nil else { return }

        guard isLocalNetworkAuthorizationDenied
                || !isBrowsingReady
                || !isAdvertisingReady else { return }

        let now = Date()
        guard now.timeIntervalSince(lastActivationRestartDate)
                >= Self.activationRestartThrottle else { return }
        lastActivationRestartDate = now

        logger.info(
            "Retour au premier plan — relance de la pile Bonjour (pile dégradée)"
        )
        restartMonitoring()
    }

    /// Planifie un redémarrage du navigateur après un `.failed`, avec
    /// backoff borné. Une seule tâche à la fois.
    private func scheduleBrowserRestart() {
        browserRetryTask?.cancel()

        let delay = Self.retryDelay(
            afterFailureCount: browserFailureCount
        )
        browserFailureCount += 1

        logger.warning(
            "Reprise de la recherche dans \(Int(delay)) s (échec #\(self.browserFailureCount))"
        )

        browserRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            self.browser?.cancel()
            self.browser = nil
            self.isBrowsingReady = false
            self.startDiscovery()
        }
    }

    /// Planifie un redémarrage de l'écouteur après un `.failed`.
    private func scheduleListenerRestart() {
        listenerRetryTask?.cancel()

        let delay = Self.retryDelay(
            afterFailureCount: listenerFailureCount
        )
        listenerFailureCount += 1

        logger.warning(
            "Reprise de la publication dans \(Int(delay)) s (échec #\(self.listenerFailureCount))"
        )

        listenerRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.isAdvertisingReady = false
            self.startAdvertising()
        }
    }

    // MARK: - Chemin réseau + réveil

    /// Démarre la surveillance du chemin réseau (une seule fois).
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = path.availableInterfaces
                .map { String(describing: $0) }
                .sorted()
                .joined(separator: ",")

            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.lastInterfaceSignature
                self.lastInterfaceSignature = signature

                // Premier état : aucune reprise à déclencher (le
                // démarrage initial arrive juste après).
                guard !previous.isEmpty, previous != signature else {
                    return
                }

                self.logger.info(
                    "Chemin réseau modifié — relance de la découverte"
                )
                self.restartMonitoring()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    #if os(macOS)
    /// Observer le réveil système : après un veille/réveil, les mises
    /// en cache mDNS peuvent être périmées alors que l'état reste
    /// `.ready` — un redémarrage forcé re-synchronise la publication
    /// et la recherche (cause classique de « l'iPhone n'est plus
    /// détecté » au réveil).
    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.info(
                    "Réveil système — relance de la découverte"
                )
                self.restartMonitoring()
            }
        }
    }
    #else
    private func observeSystemWake() {
        // iOS : pas de réveil système comparable ; le moniteur de
        // chemin réseau couvre les bascules d'association (Wi-Fi
        // coupé/rétabli).
    }
    #endif

}
