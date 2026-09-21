//
//  BonjourService.swift
//  AirBridge
//
//  Created by massi9106 on 19/07/2026.
//

import Foundation
import Network
import OSLog

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

    
    init(localDevice: Device){
        self.localDevice = localDevice
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

    /// Vrai pour les erreurs Bonjour qui signalent un refus
    /// d'autorisation plutôt qu'un incident réseau transitoire.
    ///
    /// `kDNSServiceErr_NoAuth` (-65555) est le code remonté quand
    /// l'accès au réseau local n'est pas accordé à l'application
    /// (macOS 15+ / iOS 14+) ; `kDNSServiceErr_PolicyDenied` (-72008)
    /// apparaît quand la navigation sur ce type de service est
    /// interdite. Dans les deux cas, le navigateur n'émet aucun
    /// résultat tant que l'autorisation n'est pas accordée.
    nonisolated private static func isAuthorizationError(
        _ error: NWError
    ) -> Bool {
        guard case let .dns(code) = error else { return false }
        return code == -65555 || code == -72008
    }

    /// Message affiché par l'UI pour expliquer qu'une étape Bonjour a
    /// échoué et indiquer l'action à effectuer. Le texte est construit
    /// ici (et non dans les vues) pour rester identique quel que soit
    /// l'écran qui l'affiche.
    nonisolated private static func localNetworkHint(
        stage: String,
        error: Error
    ) -> String {
        "\(stage) : \(error.localizedDescription). Vérifiez que « Réseau "
        + "local » est autorisé pour AirBridge (Réglages Système → "
        + "Confidentialité et sécurité → Réseau local)."
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
                        self?.advertisingIssue = nil
                    }

                case .failed(let error):

                    Self.staticLogger.error("Le listener a échoué : \(error.localizedDescription, privacy: .public)")

                    let issue = Self.localNetworkHint(
                        stage: "La publication d'AirBridge sur le réseau local a échoué",
                        error: error
                    )
                    Task { @MainActor [weak self] in
                        self?.advertisingIssue = issue
                    }

                case .cancelled:

                    Self.staticLogger.info("Le listener a été arrêté")

                    Task { @MainActor [weak self] in
                        self?.advertisingIssue = nil
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
                    self?.browsingIssue = nil
                }

            case .failed(let error):
                Self.staticLogger.error("La recherche Bonjour a échoué : \(error.localizedDescription, privacy: .public)")

                let issue = Self.localNetworkHint(
                    stage: "La recherche d'appareils a échoué",
                    error: error
                )
                Task { @MainActor [weak self] in
                    self?.browsingIssue = issue
                }

            case .cancelled:
                Self.staticLogger.info("La recherche Bonjour a été arrêtée")

                Task { @MainActor [weak self] in
                    self?.browsingIssue = nil
                }

            case .setup:
                Self.staticLogger.debug("Le navigateur est configuré")

            case .waiting(let error):
                Self.staticLogger.debug("La recherche Bonjour attend : \(error.localizedDescription, privacy: .public)")

                // Une attente n'est pas forcément une panne : on ne la
                // remonte à l'UI que lorsqu'elle trahit un refus
                // d'autorisation, sinon le bandeau clignoterait à chaque
                // reconfiguration réseau.
                if Self.isAuthorizationError(error) {
                    let issue = Self.localNetworkHint(
                        stage: "La recherche d'appareils est bloquée",
                        error: error
                    )
                    Task { @MainActor [weak self] in
                        self?.browsingIssue = issue
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

                for device in devices {
                    self.onDeviceDiscovered?(device)
                }

                self.logger.debug("\(devices.count) appareil(s) découvert(s)")

            }

        }

        newBrowser.start(queue: .main)

    }
    
    func stopAdvertising() {

        guard listener != nil else {
            logger.info("Aucun service Bonjour à arrêter")
            return
        }

        listener?.cancel()
        listener = nil

        logger.info("Publication Bonjour arrêtée")

    }

    func stopDiscovery() {

        guard browser != nil else {
            logger.info("Aucune recherche Bonjour à arrêter")
            return
        }

        browser?.cancel()
        browser = nil

        discoveredDevices.removeAll()

        logger.info("Recherche Bonjour arrêtée")

    }
    
}
