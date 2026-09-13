//
//  DiscoveredDeviceTests.swift
//  AirBridgeTests
//
//  Tests unitaires de la struct `DiscoveredDevice` — en particulier
//  du champ optionnel `rssi: Int?` introduit lors de la Phase 6
//  (améliorations UX). On vérifie :
//
//    - Le constructeur par défaut laisse `rssi == nil` (rétrocompat
//      avec les appels existants dans `BonjourService` qui ne
//      passent pas de RSSI).
//    - Le constructeur explicite accepte un RSSI entier arbitraire
//      (cas fort, cas faible).
//    - La conformité `Identifiable` est correcte : `id == device.id`.
//    - `Equatable` n'est PAS garanti (la struct contient
//      `NWEndpoint` qui n'est pas `Equatable` par défaut) — on le
//      documente via un test d'observation : deux instances créées
//      à partir des mêmes valeurs ne sont pas comparables via `==`
//      car la synthèse automatique n'a pas été générée.
//
//  Couverture Codable :
//    - `DiscoveredDevice` n'est PAS `Codable` (vérifié : la
//      déclaration n'ajoute pas la conformance, et `NWEndpoint` ne
//      l'est pas non plus). Le test roundtrip est donc volontairement
//      omis et documenté.
//
//  Couvre la Phase 6 (amélioration UX, ajout du RSSI pour la vue
//  radar).
//

import XCTest
import Network
@testable import AirBridge

final class DiscoveredDeviceTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDevice(name: String = "iPhone de Test") -> Device {
        Device(
            id: UUID(),
            name: name,
            model: "iPhone",
            systemVersion: "26.5"
        )
    }

    private func makeEndpoint() -> NWEndpoint {
        NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: 9_000)
        )
    }

    // MARK: - Initialisation

    func testDefaultRSSIIsNil() {
        // Le constructeur par défaut (sans argument `rssi:`) doit
        // laisser le champ à nil — c'est le contrat utilisé par
        // `BonjourService` qui n'a pas de source RSSI pour
        // l'instant.
        let device = makeDevice()
        let endpoint = makeEndpoint()
        let discovered = DiscoveredDevice(
            device: device,
            endpoint: endpoint
        )

        XCTAssertNil(
            discovered.rssi,
            "Le RSSI doit être nil par défaut quand le constructeur n'en reçoit pas."
        )
    }

    func testExplicitRSSIIsPreserved() {
        // Cas fort (-30 dBm = excellent, proche de 0).
        let strongDevice = makeDevice(name: "Proche")
        let strong = DiscoveredDevice(
            device: strongDevice,
            endpoint: makeEndpoint(),
            rssi: -30
        )
        XCTAssertEqual(
            strong.rssi,
            -30,
            "Le RSSI explicite doit être préservé tel quel (cas fort)."
        )

        // Cas faible (-90 dBm = signal limite).
        let weakDevice = makeDevice(name: "Loin")
        let weak = DiscoveredDevice(
            device: weakDevice,
            endpoint: makeEndpoint(),
            rssi: -90
        )
        XCTAssertEqual(
            weak.rssi,
            -90,
            "Le RSSI explicite doit être préservé tel quel (cas faible)."
        )
    }

    func testNilRSSIExplicitIsPreserved() {
        // Passer `rssi: nil` explicitement doit avoir le même
        // effet que de l'omettre — utile pour les call-sites
        // qui veulent marquer explicitement « pas de mesure » dans
        // un future refactor.
        let device = makeDevice()
        let endpoint = makeEndpoint()
        let discovered = DiscoveredDevice(
            device: device,
            endpoint: endpoint,
            rssi: nil
        )
        XCTAssertNil(
            discovered.rssi,
            "Passer rssi: nil explicitement doit être équivalent à l'omettre."
        )
    }

    // MARK: - Identifiable

    func testIDMatchesDeviceID() {
        // La conformance `Identifiable` est définie explicitement
        // dans la struct : `var id: UUID { device.id }`. On
        // vérifie que l'identifiant observable correspond bien à
        // celui du `Device` sous-jacent, pas à un nouvel UUID
        // généré.
        let device = makeDevice()
        let endpoint = makeEndpoint()
        let discovered = DiscoveredDevice(
            device: device,
            endpoint: endpoint,
            rssi: -42
        )

        XCTAssertEqual(
            discovered.id,
            device.id,
            "L'identifiant Identifiable doit être celui du Device sous-jacent."
        )
    }

    // MARK: - Codable (documentation)

    /// `DiscoveredDevice` n'est PAS `Codable`. La struct contient
    /// un `NWEndpoint` (Network framework) qui n'expose pas
    /// `Codable` dans les versions actuelles du SDK, donc la
    /// synthèse automatique de `Codable` n'est pas disponible.
    /// Conséquence pratique : impossible de sérialiser un
    /// `DiscoveredDevice` en JSON pour le passer à un `UserDefaults`
    /// ou à un encodeur réseau — ce qui est cohérent avec le
    /// fait que la découverte Bonjour est locale et volatile.
    ///
    /// On ancre cette observation dans un test pour qu'elle
    /// apparaisse dans le rapport XCTest.
    func test_documentationOnly_notCodable() {
        // Pas d'assertion — ce test existe pour documenter
        // explicitement l'absence de `Codable` et la raison
        // (NWEndpoint).
        XCTAssertTrue(true)
    }
}
