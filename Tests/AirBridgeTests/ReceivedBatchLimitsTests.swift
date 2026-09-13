//
//  ReceivedBatchLimitsTests.swift
//  AirBridgeTests
//

import XCTest
@testable import AirBridge

final class ReceivedBatchLimitsTests: XCTestCase {

    // MARK: - Taille d'un fichier

    func testAnOrdinaryVideoIsAccepted() {
        XCTAssertTrue(
            ReceivedBatchLimits.isAcceptableFileSize(
                772 * 1024 * 1024
            )
        )
    }

    func testAnEmptyFileIsAccepted() {
        XCTAssertTrue(
            ReceivedBatchLimits.isAcceptableFileSize(0)
        )
    }

    func testTheCeilingItselfIsAccepted() {
        XCTAssertTrue(
            ReceivedBatchLimits.isAcceptableFileSize(
                ReceivedBatchLimits.maximumFileSize
            )
        )
    }

    func testOneByteAboveTheCeilingIsRejected() {
        XCTAssertFalse(
            ReceivedBatchLimits.isAcceptableFileSize(
                ReceivedBatchLimits.maximumFileSize + 1
            )
        )
    }

    /// Une taille négative ne décrit aucun fichier : elle trahit un
    /// débordement chez l'émetteur, ou une annonce forgée.
    func testANegativeSizeIsRejected() {
        XCTAssertFalse(
            ReceivedBatchLimits.isAcceptableFileSize(-1)
        )

        XCTAssertFalse(
            ReceivedBatchLimits.isAcceptableFileSize(Int64.min)
        )
    }

    func testAnAbsurdlyLargeSizeIsRejected() {
        XCTAssertFalse(
            ReceivedBatchLimits.isAcceptableFileSize(Int64.max)
        )
    }

    // MARK: - Nombre de fichiers

    func testAFileIsAcceptedInAnEmptyBatch() {
        XCTAssertTrue(
            ReceivedBatchLimits.canAccept(
                fileSize: 1_024,
                inBatchOf: 0,
                totalBytes: 0
            )
        )
    }

    func testTheLastAllowedFileOfABatchIsAccepted() {
        XCTAssertTrue(
            ReceivedBatchLimits.canAccept(
                fileSize: 1_024,
                inBatchOf: ReceivedBatchLimits.maximumFilesPerBatch - 1,
                totalBytes: 0
            )
        )
    }

    func testAFileBeyondTheBatchCountIsRejected() {
        XCTAssertFalse(
            ReceivedBatchLimits.canAccept(
                fileSize: 1_024,
                inBatchOf: ReceivedBatchLimits.maximumFilesPerBatch,
                totalBytes: 0
            )
        )
    }

    // MARK: - Volume d'un lot

    func testTheFileThatExactlyFillsTheBatchIsAccepted() {
        XCTAssertTrue(
            ReceivedBatchLimits.canAccept(
                fileSize: 1_024,
                inBatchOf: 1,
                totalBytes: ReceivedBatchLimits.maximumBatchSize - 1_024
            )
        )
    }

    /// Le fichier est valide seul, mais fait dépasser le lot : c'est lui
    /// qu'on refuse, faute de connaître le total avant la fin.
    func testTheFileThatOverflowsTheBatchIsRejected() {
        XCTAssertFalse(
            ReceivedBatchLimits.canAccept(
                fileSize: 2_048,
                inBatchOf: 1,
                totalBytes: ReceivedBatchLimits.maximumBatchSize - 1_024
            )
        )
    }

    /// Deux tailles acceptables peuvent dépasser `Int64` une fois
    /// additionnées : le cumul doit refuser, pas déborder.
    func testCumulativeOverflowIsRejectedRatherThanWrapping() {
        XCTAssertFalse(
            ReceivedBatchLimits.canAccept(
                fileSize: ReceivedBatchLimits.maximumFileSize,
                inBatchOf: 1,
                totalBytes: Int64.max - 1
            )
        )
    }

    // MARK: - Cohérence des plafonds

    /// Un lot doit pouvoir contenir au moins un fichier de taille
    /// maximale, sinon les deux plafonds se contredisent.
    func testABatchCanHoldAtLeastOneMaximalFile() {
        XCTAssertGreaterThanOrEqual(
            ReceivedBatchLimits.maximumBatchSize,
            ReceivedBatchLimits.maximumFileSize
        )
    }

    func testCeilingsArePositive() {
        XCTAssertGreaterThan(ReceivedBatchLimits.maximumFileSize, 0)
        XCTAssertGreaterThan(ReceivedBatchLimits.maximumBatchSize, 0)
        XCTAssertGreaterThan(ReceivedBatchLimits.maximumFilesPerBatch, 0)
    }

    /// Les plafonds visent l'absurde, pas l'inhabituel : un lot de mille
    /// photos ne doit jamais les rencontrer.
    func testAThousandPhotosPassWithoutTouchingAnyCeiling() {
        var count = 0
        var bytes: Int64 = 0
        let photoSize: Int64 = 8 * 1024 * 1024

        for _ in 0..<1_000 {
            XCTAssertTrue(
                ReceivedBatchLimits.canAccept(
                    fileSize: photoSize,
                    inBatchOf: count,
                    totalBytes: bytes
                )
            )

            count += 1
            bytes += photoSize
        }
    }

    // MARK: - Explications

    func testTheReasonForANegativeSizeSaysSo() {
        let reason = ReceivedBatchLimits.rejectionReason(
            fileSize: -5,
            inBatchOf: 0,
            totalBytes: 0
        )

        XCTAssertTrue(reason.contains("négative"))
    }

    func testTheReasonForAnOversizedFileCitesTheCeiling() {
        let reason = ReceivedBatchLimits.rejectionReason(
            fileSize: ReceivedBatchLimits.maximumFileSize + 1,
            inBatchOf: 0,
            totalBytes: 0
        )

        XCTAssertTrue(
            reason.contains("\(ReceivedBatchLimits.maximumFileSize)")
        )
    }

    func testTheReasonForAFullBatchCitesTheCount() {
        let reason = ReceivedBatchLimits.rejectionReason(
            fileSize: 1_024,
            inBatchOf: ReceivedBatchLimits.maximumFilesPerBatch,
            totalBytes: 0
        )

        XCTAssertTrue(
            reason.contains(
                "\(ReceivedBatchLimits.maximumFilesPerBatch)"
            )
        )
    }

    func testTheReasonForAnOverflowingBatchMentionsVolume() {
        let reason = ReceivedBatchLimits.rejectionReason(
            fileSize: 2_048,
            inBatchOf: 1,
            totalBytes: ReceivedBatchLimits.maximumBatchSize - 1_024
        )

        XCTAssertTrue(reason.contains("volume"))
    }

    /// Toute annonce refusée doit produire une explication : une trace
    /// vide ne dit pas pourquoi le transfert n'a pas eu lieu.
    func testEveryRejectedAnnouncementHasANonEmptyReason() {
        let cases: [(Int64, Int, Int64)] = [
            (-1, 0, 0),
            (ReceivedBatchLimits.maximumFileSize + 1, 0, 0),
            (1_024, ReceivedBatchLimits.maximumFilesPerBatch, 0),
            (
                2_048,
                1,
                ReceivedBatchLimits.maximumBatchSize - 1_024
            )
        ]

        for (size, count, bytes) in cases {
            XCTAssertFalse(
                ReceivedBatchLimits.canAccept(
                    fileSize: size,
                    inBatchOf: count,
                    totalBytes: bytes
                ),
                "Ce cas devrait être refusé : \(size), \(count), \(bytes)"
            )

            XCTAssertFalse(
                ReceivedBatchLimits.rejectionReason(
                    fileSize: size,
                    inBatchOf: count,
                    totalBytes: bytes
                ).isEmpty
            )
        }
    }
}
