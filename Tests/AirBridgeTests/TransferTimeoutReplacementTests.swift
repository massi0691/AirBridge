//
//  TransferTimeoutReplacementTests.swift
//  AirBridge
//
//  Sémantique de réarmement du gestionnaire de délais de transfert.
//
//  Toute la garantie « jamais d'attente infinie » d'AirBridge repose sur
//  une propriété précise de `TransferTimeoutManager.start` : réarmer un
//  délai pour un transfert **annule** le délai précédent du même
//  transfert. C'est ce qui permet au Core d'enchaîner les phases sans
//  laisser un vieux délai déclencher une interruption périmée :
//
//    - `armApprovalTimeout` (300 s) pendant l'attente utilisateur,
//    - puis `armAnnouncementTimeout` (30 s) si l'annonce est reportée,
//    - puis `armAcceptedStartTimeout` (20 s) une fois le pair d'accord,
//    - puis `restartTransferActivityTimeout` (30 s) à chaque morceau.
//
//  Si `start` n'annulait pas le délai précédent, le délai d'approbation
//  de 300 s tirerait encore après un démarrage réussi — ou, pire, un
//  délai expiré interromprait un transfert en cours de reprise. Ces tests
//  verrouillent aussi l'indépendance entre transferts et `cancelAll`.
//

import XCTest
@testable import AirBridge

@MainActor
final class TransferTimeoutReplacementTests: XCTestCase {

    /// Compteur d'appels du callback. Classe (et non `var` capturée) :
    /// le callback est `@escaping @MainActor`, il ne peut pas muter une
    /// variable locale du test.
    private final class CallbackCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    /// Marge largement supérieure aux durées utilisées ici, pour absorber
    /// l'ordonnancement sans rendre la suite de tests lente.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - Réarmement

    /// Le second `start` pour un même `transferID` remplace le premier :
    /// seul le nouveau délai doit tirer.
    func testStartReplacesThePreviousTimeoutOfTheSameTransfer() async {
        let manager = TransferTimeoutManager()
        let superseded = CallbackCounter()
        let rearmed = CallbackCounter()
        let transferID = UUID()

        manager.start(
            transferID: transferID,
            kind: .approval,
            duration: .milliseconds(20)
        ) {
            superseded.increment()
        }

        // Réarmement immédiat, comme le fait le Core quand la phase
        // d'approbation laisse place à la phase de démarrage accepté.
        manager.start(
            transferID: transferID,
            kind: .transferActivity,
            duration: .milliseconds(120)
        ) {
            rearmed.increment()
        }

        await settle()

        XCTAssertEqual(
            superseded.count, 0,
            "Le délai remplacé ne doit jamais tirer : il interromprait une phase déjà dépassée"
        )
        XCTAssertEqual(
            rearmed.count, 1,
            "Le nouveau délai doit tirer exactement une fois"
        )
    }

    /// Un délai expiré tire une seule fois : aucune répétition périodique,
    /// sinon une interruption serait rejouée sur un transfert déjà repris.
    func testTimeoutFiresExactlyOnce() async {
        let manager = TransferTimeoutManager()
        let counter = CallbackCounter()

        manager.start(
            transferID: UUID(),
            kind: .completionConfirmation,
            duration: .milliseconds(20)
        ) {
            counter.increment()
        }

        await settle()

        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - Annulation

    func testCancelPreventsTheCallback() async {
        let manager = TransferTimeoutManager()
        let counter = CallbackCounter()
        let transferID = UUID()

        manager.start(
            transferID: transferID,
            kind: .transferActivity,
            duration: .milliseconds(20)
        ) {
            counter.increment()
        }

        manager.cancel(transferID: transferID)

        await settle()

        XCTAssertEqual(
            counter.count, 0,
            "Un délai annulé ne doit pas tirer (transfert terminé, repris ou interrompu)"
        )
    }

    func testCancelIsIdempotentAndSafeForUnknownTransfer() {
        let manager = TransferTimeoutManager()
        let transferID = UUID()

        manager.cancel(transferID: transferID)
        manager.cancel(transferID: transferID)

        manager.start(
            transferID: transferID,
            kind: .approval,
            duration: .seconds(60)
        ) {}
        manager.cancel(transferID: transferID)
        manager.cancel(transferID: transferID)
    }

    func testCancelAllPreventsEveryPendingTimeout() async {
        let manager = TransferTimeoutManager()
        let first = CallbackCounter()
        let second = CallbackCounter()

        manager.start(
            transferID: UUID(),
            kind: .approval,
            duration: .milliseconds(20)
        ) {
            first.increment()
        }
        manager.start(
            transferID: UUID(),
            kind: .transferActivity,
            duration: .milliseconds(30)
        ) {
            second.increment()
        }

        manager.cancelAll()

        await settle()

        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.count, 0)
    }

    // MARK: - Indépendance entre transferts

    /// Annuler le délai d'un transfert ne doit pas toucher celui d'un
    /// autre : plusieurs envois peuvent coexister dans la file FIFO.
    func testTimeoutsAreIndependentPerTransfer() async {
        let manager = TransferTimeoutManager()
        let cancelledTransfer = CallbackCounter()
        let untouchedTransfer = CallbackCounter()
        let cancelledID = UUID()
        let untouchedID = UUID()

        manager.start(
            transferID: cancelledID,
            kind: .approval,
            duration: .milliseconds(20)
        ) {
            cancelledTransfer.increment()
        }
        manager.start(
            transferID: untouchedID,
            kind: .approval,
            duration: .milliseconds(40)
        ) {
            untouchedTransfer.increment()
        }

        manager.cancel(transferID: cancelledID)

        await settle()

        XCTAssertEqual(cancelledTransfer.count, 0)
        XCTAssertEqual(
            untouchedTransfer.count, 1,
            "Le délai de l'autre transfert doit survivre à l'annulation du premier"
        )
    }

    /// Un réarmement pour un transfert ne doit pas annuler les délais des
    /// autres transferts (cas d'un lot : plusieurs `transferID` actifs).
    func testRearmingOneTransferDoesNotAffectOthers() async {
        let manager = TransferTimeoutManager()
        let rearmedSuperseded = CallbackCounter()
        let rearmedCurrent = CallbackCounter()
        let otherTransfer = CallbackCounter()
        let rearmedID = UUID()

        manager.start(
            transferID: rearmedID,
            kind: .approval,
            duration: .milliseconds(20)
        ) {
            rearmedSuperseded.increment()
        }
        manager.start(
            transferID: UUID(),
            kind: .transferActivity,
            duration: .milliseconds(60)
        ) {
            otherTransfer.increment()
        }

        manager.start(
            transferID: rearmedID,
            kind: .transferActivity,
            duration: .milliseconds(80)
        ) {
            rearmedCurrent.increment()
        }

        await settle()

        XCTAssertEqual(rearmedSuperseded.count, 0)
        XCTAssertEqual(rearmedCurrent.count, 1)
        XCTAssertEqual(otherTransfer.count, 1)
    }
}
