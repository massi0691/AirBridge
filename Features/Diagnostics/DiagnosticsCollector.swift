//
//  DiagnosticsCollector.swift
//  AirBridge
//
//  Collecte de l'état réel (réseau, Bonjour, session, pairage, partage)
//  pour le panneau de diagnostic. La mise en forme et les règles
//  d'affichage vivent dans `SharingDiagnosticsBuilder` (fonction pure).
//

import Foundation
import Network
import Observation

/// État du chemin réseau, réduit à ce dont le diagnostic a besoin.
///
/// `nonisolated` : valeur pure recueillie hors MainActor par
/// `NWPathMonitor` puis lue par l'interface.
nonisolated struct NetworkPathSnapshot: Equatable, Sendable {

    /// Chemin réseau utilisable (`.satisfied`).
    let isSatisfied: Bool

    /// Chemin coûteux (cellulaire, partage de connexion) : trahit souvent
    /// deux appareils qui ne sont plus sur le même réseau local.
    let isExpensive: Bool

    /// Le chemin permet la résolution DNS — nécessaire à mDNS/Bonjour.
    let supportsDNS: Bool

    /// Interfaces disponibles (`wi-fi`, `wiredEthernet`, `cellular`…).
    let interfaceNames: [String]

    static let unknown = NetworkPathSnapshot(
        isSatisfied: false,
        isExpensive: false,
        supportsDNS: false,
        interfaceNames: []
    )

    init(
        isSatisfied: Bool,
        isExpensive: Bool,
        supportsDNS: Bool,
        interfaceNames: [String]
    ) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.supportsDNS = supportsDNS
        self.interfaceNames = interfaceNames
    }

    /// Construit la photographie à partir d'un `NWPath`. Appelé depuis la
    /// file de `NWPathMonitor` (hors MainActor) : le type entier est
    /// `nonisolated`.
    static func make(
        from path: NWPath
    ) -> NetworkPathSnapshot {
        let names = path.availableInterfaces
            .map { interface in
                interface.name.isEmpty
                    ? Self.name(of: interface.type)
                    : interface.name
            }

        return NetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            isExpensive: path.isExpensive,
            supportsDNS: path.supportsDNS,
            interfaceNames: names
        )
    }

    private static func name(
        of type: NWInterface.InterfaceType
    ) -> String {
        switch type {
        case .wifi: return "wi-fi"
        case .cellular: return "cellulaire"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        case .other: return "autre"
        @unknown default: return "inconnue"
        }
    }
}

/// Surveillance du chemin réseau, démarrée uniquement pendant que le
/// panneau de diagnostic est visible.
@MainActor
@Observable
final class LocalNetworkPathMonitor {

    private let monitor = NWPathMonitor()

    private let queue = DispatchQueue(
        label: "com.airbridge.diagnostics.path",
        qos: .utility
    )

    private(set) var snapshot: NetworkPathSnapshot = .unknown

    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        monitor.pathUpdateHandler = { [weak self] path in
            let updated = NetworkPathSnapshot.make(from: path)

            Task { @MainActor [weak self] in
                self?.snapshot = updated
            }
        }

        // La valeur courante est lue immédiatement : sans cela, le panneau
        // afficherait « aucun chemin réseau » jusqu'au premier callback.
        snapshot = NetworkPathSnapshot.make(from: monitor.currentPath)
        monitor.start(queue: queue)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        monitor.cancel()
    }
}

/// Collecte les valeurs réelles depuis le Core et les réduit en
/// `DiagnosticsInput`, l'entrée du constructeur pur.
@MainActor
enum DiagnosticsCollector {

    static var platform: DiagnosticPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return .iOS
        #else
        return .other
        #endif
    }

    static func input(
        core: AirBridgeCore,
        path: NetworkPathSnapshot
    ) -> DiagnosticsInput {
        let connectionManager = core.connectionManager
        let bonjourService = core.bonjourService

        // Le pair connecté d'abord, puis le dernier pair connu : une
        // session qui vient de tomber ne doit pas faire disparaître la
        // ligne de pairage du diagnostic.
        let peer = connectionManager.connectedDevice
            ?? connectionManager.lastConnectedPeer

        let peerID = peer?.id

        return DiagnosticsInput(
            platform: platform,
            isPathSatisfied: path.isSatisfied,
            isPathExpensive: path.isExpensive,
            pathSupportsDNS: path.supportsDNS,
            interfaceNames: path.interfaceNames,
            isLocalNetworkAuthorizationDenied:
                bonjourService.isLocalNetworkAuthorizationDenied,
            isAdvertisingReady: bonjourService.isAdvertisingReady,
            isBrowsingReady: bonjourService.isBrowsingReady,
            bonjourIssue: bonjourService.localNetworkIssue,
            discoveredPeerCount: bonjourService.discoveredDevices.count,
            peerName: peer?.name,
            sessionStateDescription: connectionManager.stateDescription,
            isSessionReady: connectionManager.isSessionReady,
            isSecureSessionReady: connectionManager.isSecureSessionReady,
            isPeerRecorded: peerID.map {
                core.pairingStore.pairing(for: $0) != nil
            } ?? false,
            peerTrustState: peerID.map {
                core.pairingStore.trustState(for: $0)
            } ?? .unknown,
            lastReceptionRejection: connectionManager.lastReceptionRejection,
            embeddedPluginNames: embeddedPluginNames(),
            isAppGroupContainerAvailable: isAppGroupContainerAvailable()
        )
    }

    /// Extensions embarquées dans l'application (`Contents/PlugIns` sur
    /// macOS, `PlugIns/` sur iOS) : c'est leur présence qui conditionne
    /// l'apparition d'AirBridge dans le menu Partager.
    static func embeddedPluginNames() -> [String] {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
            return []
        }

        let contents = try? FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil
        )

        return (contents ?? [])
            .filter { $0.pathExtension == "appex" }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Le conteneur App Group est le canal de remise des fichiers entre le
    /// menu Partager (processus d'extension) et l'application.
    static func isAppGroupContainerAvailable() -> Bool {
        // Passe par `AirBridgeAppGroup` : sa résolution est mémorisée,
        // ce qui évite d'ajouter au journal système une ligne
        // « client is not entitled » à chaque ouverture du panneau
        // quand la capacité App Groups n'est pas provisionnée.
        AirBridgeAppGroup.containerURL() != nil
    }
}
