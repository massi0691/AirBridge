//
//  ProtocolCompatibilityTests.swift
//  AirBridgeTests
//

import XCTest
@testable import AirBridge

final class ProtocolCompatibilityTests: XCTestCase {

    // MARK: - Versions acceptées

    func testCurrentVersionIsSupported() {
        XCTAssertTrue(
            ProtocolCompatibility.isSupported(
                ProtocolCompatibility.currentVersion
            )
        )
    }

    func testMinimumVersionIsSupported() {
        XCTAssertTrue(
            ProtocolCompatibility.isSupported(
                ProtocolCompatibility.minimumSupportedVersion
            )
        )
    }

    /// Ce que cette application émet doit être ce qu'elle sait relire :
    /// sinon deux copies identiques se refuseraient l'une l'autre.
    func testAnApplicationOfThisVersionAcceptsItsOwnMessages() {
        let emitted = ProtocolCompatibility.currentVersion

        XCTAssertTrue(
            ProtocolCompatibility.isSupported(emitted)
        )
    }

    // MARK: - Versions refusées

    func testAVersionNewerThanCurrentIsRejected() {
        XCTAssertFalse(
            ProtocolCompatibility.isSupported(
                ProtocolCompatibility.currentVersion + 1
            )
        )
    }

    func testAVersionOlderThanMinimumIsRejected() {
        XCTAssertFalse(
            ProtocolCompatibility.isSupported(
                ProtocolCompatibility.minimumSupportedVersion - 1
            )
        )
    }

    /// Un `protocolVersion` à zéro ou négatif ne vient pas d'un émetteur
    /// légitime : c'est un champ absent, mal décodé, ou forgé.
    func testZeroAndNegativeVersionsAreRejected() {
        XCTAssertFalse(ProtocolCompatibility.isSupported(0))
        XCTAssertFalse(ProtocolCompatibility.isSupported(-1))
        XCTAssertFalse(ProtocolCompatibility.isSupported(Int.min))
    }

    func testAnAbsurdlyLargeVersionIsRejected() {
        XCTAssertFalse(
            ProtocolCompatibility.isSupported(Int.max)
        )
    }

    // MARK: - Cohérence des bornes

    func testMinimumIsNotAboveCurrent() {
        XCTAssertLessThanOrEqual(
            ProtocolCompatibility.minimumSupportedVersion,
            ProtocolCompatibility.currentVersion
        )
    }

    // MARK: - Explications

    func testRejectionReasonForANewerVersionMentionsUpdating() {
        let reason = ProtocolCompatibility.rejectionReason(
            for: ProtocolCompatibility.currentVersion + 1
        )

        XCTAssertTrue(reason.contains("mettez à jour"))
    }

    func testRejectionReasonForAnOlderVersionMentionsTheMinimum() {
        let reason = ProtocolCompatibility.rejectionReason(
            for: ProtocolCompatibility.minimumSupportedVersion - 1
        )

        XCTAssertTrue(
            reason.contains(
                "\(ProtocolCompatibility.minimumSupportedVersion)"
            )
        )
    }

    func testEveryRejectionReasonNamesTheOffendingVersion() {
        for version in [-3, 0, 7, 42] {
            let reason = ProtocolCompatibility.rejectionReason(
                for: version
            )

            XCTAssertTrue(
                reason.contains("\(version)"),
                "La trace pour \(version) ne cite pas la version"
            )
        }
    }

    func testRejectionReasonIsNeverEmpty() {
        for version in [Int.min, -1, 0, 2, Int.max] {
            XCTAssertFalse(
                ProtocolCompatibility.rejectionReason(for: version)
                    .isEmpty
            )
        }
    }

    // MARK: - Message porteur

    /// Le champ existait depuis l'origine ; ce test fixe la valeur émise
    /// pour qu'un changement de format ne passe pas inaperçu.
    func testANewMessageCarriesTheCurrentVersion() {
        let message = AirBridgeMessage(
            type: .hello,
            sender: Device(
                id: UUID(),
                name: "Mac de test",
                model: "Mac",
                systemVersion: "26.5"
            )
        )

        XCTAssertEqual(
            message.protocolVersion,
            ProtocolCompatibility.currentVersion
        )

        XCTAssertTrue(
            ProtocolCompatibility.isSupported(
                message.protocolVersion
            )
        )
    }
}
