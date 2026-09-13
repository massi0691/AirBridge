import XCTest
@testable import AirBridge

/// Vérifie le nommage et le confinement des lots reçus.
///
/// Les noms et chemins traités ici viennent du réseau : la moitié de ces
/// tests décrit donc ce que l'application doit *refuser*, pas seulement ce
/// qu'elle accepte.
final class ReceivedBatchLayoutTests: XCTestCase {

    // MARK: - Assainissement d'un composant

    func testOrdinaryNameIsKeptAsIs() {

        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedComponent("photo.jpg"),
            "photo.jpg"
        )
    }

    func testSeparatorsAreNeutralized() {

        // Un nom ne doit jamais devenir plusieurs composants de chemin.
        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedComponent("dossier/photo.jpg"),
            "dossier_photo.jpg"
        )

        // « \ » n'est pas un séparateur sur Apple, mais un pair d'une
        // autre plateforme peut l'employer.
        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedComponent("dossier\\photo.jpg"),
            "dossier_photo.jpg"
        )
    }

    func testTraversalAttemptWithSeparatorsBecomesHarmless() {

        // « ../../etc/passwd » ne doit pas rester un chemin remontant.
        let sanitized = ReceivedBatchLayout.sanitizedComponent(
            "../../etc/passwd"
        )

        XCTAssertEqual(sanitized, ".._.._etc_passwd")
        XCTAssertFalse(sanitized?.contains("/") ?? true)
    }

    func testNullByteIsRemoved() {

        // L'octet nul tronquerait le chemin au niveau des appels système.
        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedComponent("photo\0.jpg"),
            "photo.jpg"
        )
    }

    func testDotComponentsAreRejected() {

        XCTAssertNil(ReceivedBatchLayout.sanitizedComponent("."))
        XCTAssertNil(ReceivedBatchLayout.sanitizedComponent(".."))
    }

    func testEmptyAndWhitespaceOnlyNamesAreRejected() {

        XCTAssertNil(ReceivedBatchLayout.sanitizedComponent(""))
        XCTAssertNil(ReceivedBatchLayout.sanitizedComponent("   "))
        XCTAssertNil(ReceivedBatchLayout.sanitizedComponent("\n\t"))
    }

    func testSurroundingWhitespaceIsTrimmed() {

        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedComponent("  photo.jpg  "),
            "photo.jpg"
        )
    }

    // MARK: - Troncature

    func testLongNameIsTruncatedToAWritableLength() throws {

        let longName = String(repeating: "a", count: 400) + ".jpg"

        let sanitized = try XCTUnwrap(
            ReceivedBatchLayout.sanitizedComponent(longName)
        )

        XCTAssertLessThanOrEqual(
            sanitized.utf8.count,
            ReceivedBatchLayout.maximumComponentLength
        )

        // L'extension survit à la troncature : un fichier tronqué reste
        // ouvrable par l'application qui lui correspond.
        XCTAssertTrue(sanitized.hasSuffix(".jpg"))
    }

    func testTruncationDoesNotSplitAMultiByteCharacter() throws {

        // « é » occupe deux octets : tronquer à l'octet près pourrait
        // produire une chaîne invalide.
        let longName = String(repeating: "é", count: 300) + ".txt"

        let sanitized = try XCTUnwrap(
            ReceivedBatchLayout.sanitizedComponent(longName)
        )

        XCTAssertLessThanOrEqual(
            sanitized.utf8.count,
            ReceivedBatchLayout.maximumComponentLength
        )

        // Reconstruire la chaîne depuis ses octets doit redonner la même
        // valeur, ce qui n'est vrai que si aucun caractère n'est coupé.
        XCTAssertEqual(
            String(decoding: Array(sanitized.utf8), as: UTF8.self),
            sanitized
        )
    }

    // MARK: - Chemin relatif

    func testMissingRelativePathStaysMissing() {

        XCTAssertNil(
            ReceivedBatchLayout.sanitizedRelativeComponents(nil)
        )
    }

    func testRelativePathIsSplitIntoComponents() {

        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedRelativeComponents(
                "sous/dossier/photo.jpg"
            ),
            ["sous", "dossier", "photo.jpg"]
        )
    }

    func testBackslashSeparatedPathIsAlsoSplit() {

        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedRelativeComponents(
                "sous\\dossier\\photo.jpg"
            ),
            ["sous", "dossier", "photo.jpg"]
        )
    }

    func testEmptyAndCurrentDirectoryComponentsAreSkipped() {

        XCTAssertEqual(
            ReceivedBatchLayout.sanitizedRelativeComponents(
                "sous//./dossier/photo.jpg"
            ),
            ["sous", "dossier", "photo.jpg"]
        )
    }

    func testParentDirectoryComponentRejectsTheWholePath() {

        // Le chemin entier est refusé plutôt que « réparé » : réparer une
        // tentative de traversée revient à en deviner l'intention.
        XCTAssertNil(
            ReceivedBatchLayout.sanitizedRelativeComponents(
                "sous/../../etc/passwd"
            )
        )

        XCTAssertNil(
            ReceivedBatchLayout.sanitizedRelativeComponents("..")
        )

        XCTAssertNil(
            ReceivedBatchLayout.sanitizedRelativeComponents(
                "..\\windows"
            )
        )
    }

    func testPathWithoutUsableComponentIsRejected() {

        XCTAssertNil(
            ReceivedBatchLayout.sanitizedRelativeComponents("")
        )

        XCTAssertNil(
            ReceivedBatchLayout.sanitizedRelativeComponents("/")
        )

        XCTAssertNil(
            ReceivedBatchLayout.sanitizedRelativeComponents("./.")
        )
    }

    // MARK: - Nommage du lot

    func testDefaultFolderNameIsStableAcrossLocalesAndZones() {

        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let name = ReceivedBatchLayout.defaultFolderName(
            receivedAt: date,
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )

        XCTAssertEqual(name, "Réception_2023-11-14_221320")
    }

    func testProposedFolderNameIsPreferredWhenSafe() {

        let name = ReceivedBatchLayout.folderName(
            proposed: "Vacances 2026",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )

        XCTAssertEqual(name, "Vacances 2026")
    }

    func testProposedFolderNameIsSanitizedRatherThanTrusted() {

        let name = ReceivedBatchLayout.folderName(
            proposed: "../../secrets",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )

        XCTAssertEqual(name, ".._.._secrets")
        XCTAssertFalse(name.contains("/"))
    }

    func testUnusableProposedNameFallsBackToTheReceptionDate() {

        for proposed in ["", "   ", ".", ".."] {

            let name = ReceivedBatchLayout.folderName(
                proposed: proposed,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                timeZone: TimeZone(identifier: "UTC") ?? .gmt
            )

            XCTAssertEqual(
                name,
                "Réception_2023-11-14_221320",
                "Nom proposé « \(proposed) » aurait dû être écarté"
            )
        }
    }

    func testMissingProposedNameFallsBackToTheReceptionDate() {

        let name = ReceivedBatchLayout.folderName(
            proposed: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )

        XCTAssertEqual(name, "Réception_2023-11-14_221320")
    }

    // MARK: - Unicité

    func testFreeNameIsUsedUnchanged() throws {

        let directory = try makeTemporaryDirectory()

        let url = ReceivedBatchLayout.uniqueURL(
            name: "photo.jpg",
            in: directory
        )

        XCTAssertEqual(url.lastPathComponent, "photo.jpg")
    }

    func testTakenNameIsSuffixedKeepingTheExtension() throws {

        let directory = try makeTemporaryDirectory()

        try Data().write(
            to: directory.appendingPathComponent("photo.jpg")
        )

        let url = ReceivedBatchLayout.uniqueURL(
            name: "photo.jpg",
            in: directory
        )

        // « photo 2.jpg » et non « photo.jpg 2 » : le fichier doit rester
        // ouvrable.
        XCTAssertEqual(url.lastPathComponent, "photo 2.jpg")
    }

    func testSuffixKeepsIncrementingWhileNamesAreTaken() throws {

        let directory = try makeTemporaryDirectory()

        for name in ["photo.jpg", "photo 2.jpg", "photo 3.jpg"] {
            try Data().write(
                to: directory.appendingPathComponent(name)
            )
        }

        let url = ReceivedBatchLayout.uniqueURL(
            name: "photo.jpg",
            in: directory
        )

        XCTAssertEqual(url.lastPathComponent, "photo 4.jpg")
    }

    func testExtensionlessNameIsSuffixedWithoutADot() throws {

        let directory = try makeTemporaryDirectory()

        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Vacances"),
            withIntermediateDirectories: false
        )

        let url = ReceivedBatchLayout.uniqueURL(
            name: "Vacances",
            in: directory
        )

        XCTAssertEqual(url.lastPathComponent, "Vacances 2")
    }

    // MARK: - Confinement

    func testFileInsideTheDirectoryIsContained() throws {

        let directory = try makeTemporaryDirectory()

        XCTAssertTrue(
            ReceivedBatchLayout.isContained(
                directory.appendingPathComponent("photo.jpg"),
                in: directory
            )
        )
    }

    func testFileInASubdirectoryIsContained() throws {

        let directory = try makeTemporaryDirectory()

        XCTAssertTrue(
            ReceivedBatchLayout.isContained(
                directory
                    .appendingPathComponent("sous")
                    .appendingPathComponent("photo.jpg"),
                in: directory
            )
        )
    }

    func testDirectoryItselfIsNotContained() throws {

        let directory = try makeTemporaryDirectory()

        // Écrire « sur » le dossier n'est pas écrire dedans.
        XCTAssertFalse(
            ReceivedBatchLayout.isContained(
                directory,
                in: directory
            )
        )
    }

    func testTraversalOutOfTheDirectoryIsNotContained() throws {

        let directory = try makeTemporaryDirectory()

        XCTAssertFalse(
            ReceivedBatchLayout.isContained(
                directory
                    .appendingPathComponent("..")
                    .appendingPathComponent("evil.txt"),
                in: directory
            )
        )
    }

    func testSiblingDirectorySharingANamePrefixIsNotContained() throws {

        let parent = try makeTemporaryDirectory()

        let directory = parent.appendingPathComponent("Reception")
        let sibling = parent.appendingPathComponent("ReceptionEvil")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try FileManager.default.createDirectory(
            at: sibling,
            withIntermediateDirectories: true
        )

        // Une comparaison de préfixe sans séparateur laisserait passer
        // « ReceptionEvil » comme s'il était dans « Reception ».
        XCTAssertFalse(
            ReceivedBatchLayout.isContained(
                sibling.appendingPathComponent("photo.jpg"),
                in: directory
            )
        )
    }

    func testSymlinkInsideTheDirectoryCannotRedirectOutside() throws {

        let parent = try makeTemporaryDirectory()

        let directory = parent.appendingPathComponent("Reception")
        let outside = parent.appendingPathComponent("Dehors")

        for url in [directory, outside] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }

        // Un lien posé *dans* le dossier de réception mais pointant
        // ailleurs : le chemin garde le bon préfixe, alors que l'écriture
        // atterrirait dehors. Ne résoudre que le dossier laisserait passer.
        let link = directory.appendingPathComponent("lien")

        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        XCTAssertFalse(
            ReceivedBatchLayout.isContained(
                link.appendingPathComponent("volé.txt"),
                in: directory
            )
        )
    }

    func testSymlinkStayingInsideTheDirectoryIsStillContained() throws {
        let directory = try makeTemporaryDirectory()

        let sub = directory.appendingPathComponent("sous")

        try FileManager.default.createDirectory(
            at: sub,
            withIntermediateDirectories: true
        )

        // Résoudre les liens ne doit pas refuser ce qui reste dedans :
        // la protection viserait alors trop large.
        let link = directory.appendingPathComponent("raccourci")

        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: sub
        )

        XCTAssertTrue(
            ReceivedBatchLayout.isContained(
                link.appendingPathComponent("photo.jpg"),
                in: directory
            )
        )
    }

    func testBrokenSymlinkIsNotEscaped() throws {

        let directory = try makeTemporaryDirectory()

        // Lien vers une cible qui n'existe pas : la cible n'est pas un
        // lien, elle n'existe pas, donc on suit le lien cassé jusqu'à ce
        // qu'un ancêtre présent soit résolu. La résolution doit rejeter
        // ce qui sort par ce biais.
        let link = directory.appendingPathComponent("cassé")

        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: directory
                .appendingPathComponent("..")
                .appendingPathComponent("Dehors")
        )

        XCTAssertFalse(
            ReceivedBatchLayout.isContained(
                link.appendingPathComponent("volé.txt"),
                in: directory
            )
        )
    }

    // MARK: - Outils

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ReceivedBatchLayoutTests-\(UUID().uuidString)"
            )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        return directory
    }
}
