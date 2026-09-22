//
//  BonjourRetryDelayTests.swift
//  AirBridgeTests
//
//  Backoff de reprise de la pile Bonjour (navigateur / écouteur) :
//  après un `.failed`, `BonjourService` redémarre avec un délai
//  croissant 3 s → 60 s borné. C'est le mécanisme qui évite qu'un
//  échec terminal laisse l'app « muette » jusqu'à un redémarrage
//  manuel (« macOS ne détecte plus mon iPhone »).
//

import XCTest
@testable import AirBridge

final class BonjourRetryDelayTests: XCTestCase {

    func testDelayGrowsExponentially() {
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: 0),
            3,
            "Première reprise rapide (3 s)."
        )
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: 1),
            6
        )
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: 2),
            12
        )
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: 3),
            24
        )
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: 4),
            48
        )
    }

    func testDelayIsCappedAt60Seconds() {
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: 5),
            60,
            "Le backoff plafonne à 60 s (5 → 96 borné à 60)."
        )
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: 50),
            60
        )
    }

    func testNegativeFailureCountClampsToBase() {
        XCTAssertEqual(
            BonjourService.retryDelay(afterFailureCount: -1),
            3
        )
    }
}
