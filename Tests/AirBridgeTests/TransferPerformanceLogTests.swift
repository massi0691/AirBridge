//
//  TransferPerformanceLogTests.swift
//  AirBridgeTests
//
//  Tests de l'instrumentation de débit.
//
//  `isEnabled` est `false` en livraison : les compteurs sont alors
//  désactivés à la compilation et l'API est un no-op. Les tests
//  vérifient que cette désactivation tient (aucun effet observable
//  via l'API publique) et que la structure de fenêtre est saine.
//

import XCTest
@testable import AirBridge

final class TransferPerformanceLogTests: XCTestCase {

    // MARK: - Fenêtre de mesure

    func testWindowDefaultsAreZeroed() {
        let window = TransferPerformanceLog.Window(mode: "NORMAL", chunkSize: 64 * 1024)

        XCTAssertEqual(window.mode, "NORMAL")
        XCTAssertEqual(window.chunkSize, 64 * 1024)
        XCTAssertEqual(window.chunkCount, 0)
        XCTAssertEqual(window.bytes, 0)
        XCTAssertEqual(window.maxInFlight, 0)
        XCTAssertEqual(window.maxInFlightReceive, 0)
        XCTAssertEqual(window.sendTotal, 0)
        XCTAssertEqual(window.readTotal, 0)
        XCTAssertEqual(window.encodeTotal, 0)
        XCTAssertEqual(window.receiveTotal, 0)
        XCTAssertEqual(window.decryptTotal, 0)
        XCTAssertEqual(window.writeTotal, 0)
    }

    // MARK: - Désactivation à la livraison

    func testInstrumentationIsDisabledInProductionBuilds() {
        // L'instrumentation est conçue pour un coût nul : vérifier le
        // drapeau évite qu'une mesure active ne fuie en production.
        XCTAssertFalse(TransferPerformanceLog.isEnabled)
    }

    // MARK: - Sécurité d'appel

    /// Avec `isEnabled == false`, l'API publique ne doit rien faire —
    /// notamment pas crasher ni bloquer, y compris sous concurrence.
    func testPublicAPIIsSafeToCallWhenDisabled() async {
        let ids = (0..<50).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    TransferPerformanceLog.begin(
                        transferID: id,
                        mode: "NORMAL",
                        chunkSize: 64 * 1024
                    )
                    TransferPerformanceLog.recordSend(
                        transferID: id,
                        bytes: 64 * 1024,
                        encodeTime: 0.001,
                        sendTime: 0.002
                    )
                    TransferPerformanceLog.recordReceive(
                        transferID: id,
                        bytes: 64 * 1024,
                        decryptTime: 0.001,
                        writeTime: 0.002,
                        inFlight: 4
                    )
                    TransferPerformanceLog.record(
                        transferID: id,
                        bytes: 64 * 1024,
                        inFlight: 4,
                        readTime: 0.001,
                        encodeTime: 0.001,
                        sendTime: 0.002
                    )
                    TransferPerformanceLog.finish(transferID: id)
                }
            }
        }

        // Terminer un transfert inconnu ne doit pas non plus lever.
        TransferPerformanceLog.finish(transferID: UUID())
    }
}
