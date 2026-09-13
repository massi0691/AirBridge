import XCTest
@testable import AirBridge

/// Vérifie le choix de la taille des morceaux.
///
/// Deux exigences opposées se rencontrent ici : accélérer les gros fichiers
/// sans rien changer aux petits, déjà validés physiquement. Les tests
/// décrivent donc autant ce qui doit bouger que ce qui doit rester figé.
final class TransferChunkSizingTests: XCTestCase {

    // MARK: - Petits fichiers

    func testSmallFileKeepsTheOriginalChunkSize() {

        // 64 Kio est la taille avec laquelle les transferts ont été validés :
        // un petit fichier ne doit pas changer de comportement.
        XCTAssertEqual(
            TransferChunkSizing.chunkSize(forFileSize: 20 * 1024),
            64 * 1024
        )
    }

    func testFileSmallerThanOneChunkKeepsTheOriginalChunkSize() {

        XCTAssertEqual(
            TransferChunkSizing.chunkSize(forFileSize: 100),
            64 * 1024
        )
    }

    func testUnknownSizeFallsBackToTheSmallestChunk() {

        // Une taille illisible vaut zéro : se tromper vers le bas ne coûte
        // que du débit, se tromper vers le haut coûterait de la mémoire.
        XCTAssertEqual(
            TransferChunkSizing.chunkSize(forFileSize: 0),
            64 * 1024
        )

        XCTAssertEqual(
            TransferChunkSizing.chunkSize(forFileSize: -1),
            64 * 1024
        )
    }

    // MARK: - Seuils

    func testJustBelowTheMediumThresholdStaysSmall() {

        XCTAssertEqual(
            TransferChunkSizing.chunkSize(
                forFileSize: TransferChunkSizing.mediumFileThreshold - 1
            ),
            TransferChunkSizing.smallFileChunkSize
        )
    }

    func testTheMediumThresholdItselfGrowsTheChunk() {

        XCTAssertEqual(
            TransferChunkSizing.chunkSize(
                forFileSize: TransferChunkSizing.mediumFileThreshold
            ),
            TransferChunkSizing.mediumFileChunkSize
        )
    }

    func testJustBelowTheLargeThresholdStaysMedium() {

        XCTAssertEqual(
            TransferChunkSizing.chunkSize(
                forFileSize: TransferChunkSizing.largeFileThreshold - 1
            ),
            TransferChunkSizing.mediumFileChunkSize
        )
    }

    func testTheLargeThresholdItselfReachesTheLargestChunk() {

        XCTAssertEqual(
            TransferChunkSizing.chunkSize(
                forFileSize: TransferChunkSizing.largeFileThreshold
            ),
            TransferChunkSizing.largeFileChunkSize
        )
    }

    // MARK: - Gros fichiers

    func testVideoSizedFileUsesTheLargestChunk() {

        // Une vidéo de 700 Mio, le cas qui motive tout ceci.
        // Taille augmentée à 2 Mio pour réduire l'overhead base64/JSON.
        XCTAssertEqual(
            TransferChunkSizing.chunkSize(
                forFileSize: 700 * 1024 * 1024
            ),
            2 * 1024 * 1024
        )
    }

    func testVeryLargeFileDoesNotGrowTheChunkFurther() {

        // Le plafond est volontaire : au-delà, le gain de débit se paierait
        // en pression mémoire sur l'appareil le plus contraint.
        XCTAssertEqual(
            TransferChunkSizing.chunkSize(
                forFileSize: 8 * 1024 * 1024 * 1024
            ),
            TransferChunkSizing.largeFileChunkSize
        )
    }

    // MARK: - Cohérence

    func testChunkSizeNeverDecreasesWithFileSize() {

        let sizes: [Int64] = [
            0,
            1,
            64 * 1024,
            1 * 1024 * 1024,
            10 * 1024 * 1024,
            64 * 1024 * 1024,
            1024 * 1024 * 1024
        ]

        let chunks = sizes.map {
            TransferChunkSizing.chunkSize(forFileSize: $0)
        }

        XCTAssertEqual(
            chunks,
            chunks.sorted(),
            "Un fichier plus gros ne doit jamais recevoir un morceau plus petit"
        )
    }

    func testEveryChunkFitsWellWithinTheMaximumFrame() {

        // Un morceau gonfle d'environ 78 % à l'encodage — deux base64
        // successifs. Même le plus grand doit rester loin de la trame
        // maximale, sinon un transfert échouerait à l'envoi.
        let largest = TransferChunkSizing.largeFileChunkSize
        let encoded = Double(largest) * 1.8

        XCTAssertLessThan(
            Int(encoded),
            FrameCodec.maximumFrameSize
        )
    }

    func testChunkSizesAreMultiplesOfTheSmallestOne() {

        // Des tailles alignées gardent les lectures disque alignées, et
        // rendent les offsets prévisibles pour une reprise future.
        for chunk in [
            TransferChunkSizing.mediumFileChunkSize,
            TransferChunkSizing.largeFileChunkSize
        ] {
            XCTAssertEqual(
                chunk % TransferChunkSizing.smallFileChunkSize,
                0
            )
        }
    }
}
