//
//  BonjourLocalNetworkPolicyTests.swift
//  AirBridgeTests
//
//  Détection du refus d'accès au réseau local.
//
//  Le symptôme réel (iPhone, iOS 26/27) :
//
//      nw_browser_fail_on_dns_error_locked [B1] … PolicyDenied(-65570)
//      -[_NWAdvertiser …] advertising denied by policy
//      La recherche Bonjour attend : Network.NWError error -65570 - PolicyDenied
//
//  `-65570` (`kDNSServiceErr_PolicyDenied`) manquait à la liste des
//  codes reconnus : le refus le plus fréquent n'était donc jamais
//  détecté — radar vide, aucun bandeau, et un panneau de diagnostic
//  annonçant « aucun refus d'autorisation signalé ».
//
//  Ces tests verrouillent la liste : y ajouter un code ou en retirer
//  un doit être un choix explicite, pas un oubli.
//

import XCTest
import Network
@testable import AirBridge

final class BonjourLocalNetworkPolicyTests: XCTestCase {

    // MARK: - Le code réellement remonté par iOS

    func testPolicyDenied65570IsAnAuthorizationRefusal() {
        XCTAssertTrue(
            BonjourService.isAuthorizationDenied(dnsCode: -65570),
            "kDNSServiceErr_PolicyDenied (-65570) est le refus « Réseau local » "
                + "remonté par iOS 14+ : il doit être reconnu, sinon le radar "
                + "reste vide sans explication."
        )
    }

    func testPolicyDeniedIsDetectedThroughNWError() {
        XCTAssertTrue(
            BonjourService.isAuthorizationError(.dns(-65570)),
            "L'erreur NWError remontée par NWBrowser (.waiting) doit être "
                + "reconnue comme un refus d'autorisation."
        )
    }

    // MARK: - Codes historiques

    func testLegacyAuthorizationCodesAreStillDetected() {
        XCTAssertTrue(
            BonjourService.isAuthorizationDenied(dnsCode: -65555),
            "kDNSServiceErr_NoAuth reste un refus d'autorisation."
        )
        XCTAssertTrue(
            BonjourService.isAuthorizationDenied(dnsCode: -72008),
            "Le même refus exprimé dans le domaine NSNetServices reste valide."
        )
    }

    // MARK: - Une panne réseau n'est pas un refus

    func testTransientDNSErrorsAreNotAuthorizationRefusals() {
        // -65540 kDNSServiceErr_BadParam, -65537 Unknown, 0 succès.
        for code in [-65540, -65537, 0, -65568] {
            XCTAssertFalse(
                BonjourService.isAuthorizationDenied(dnsCode: code),
                "Le code \(code) est une erreur réseau, pas un refus : il ne "
                    + "doit pas déclencher le bandeau « Réseau local refusé »."
            )
        }
    }

    func testNonDNSErrorsAreNotAuthorizationRefusals() {
        XCTAssertFalse(
            BonjourService.isAuthorizationError(.posix(.ECONNREFUSED)),
            "Une connexion refusée par le pair n'est pas un refus "
                + "d'autorisation système : le bandeau ne doit pas "
                + "apparaître à chaque liaison rompue."
        )
    }

    // MARK: - Message utilisateur

    func testLocalNetworkHintPointsToTheLocalNetworkSetting() {
        struct Sample: LocalizedError {
            var errorDescription: String? { "PolicyDenied" }
        }

        let hint = BonjourService.localNetworkHint(
            stage: "La recherche d'appareils est bloquée",
            error: Sample()
        )

        XCTAssertTrue(
            hint.contains("Réseau local"),
            "Le message doit nommer le réglage à activer : \(hint)"
        )
        XCTAssertTrue(
            hint.contains("PolicyDenied"),
            "Le message doit reporter l'erreur d'origine : \(hint)"
        )
    }
}
