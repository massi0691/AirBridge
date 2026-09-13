import XCTest
@testable import AirBridge

/// Vérifie la répartition d'une sélection en lots à envoyer.
///
/// Les tests travaillent sur de vrais dossiers temporaires : le planificateur
/// interroge le système de fichiers, et le simuler cacherait justement ce qui
/// peut mal tourner (liens symboliques, dossier vide, fichier illisible).
final class OutgoingSelectionPlannerTests: XCTestCase {

    // MARK: - Fichiers isolés

    func testSingleFileFormsAPlanThatAnnouncesNoBatch() throws {

        let directory = try makeTemporaryDirectory()
        let fileURL = try makeFile(named: "photo.jpg", in: directory)

        let plans = OutgoingSelectionPlanner.plans(for: [fileURL])

        XCTAssertEqual(plans.count, 1)
        XCTAssertNil(plans.first?.folderName)
        XCTAssertNil(plans.first?.folderURL)
        XCTAssertEqual(plans.first?.files.count, 1)
        XCTAssertNil(plans.first?.files.first?.relativePath)

        // Un fichier isolé reste à plat dans le dossier de réception.
        XCTAssertEqual(plans.first?.announcesBatch, false)
    }

    func testSeveralFilesFormASinglePlanThatAnnouncesABatch() throws {

        let directory = try makeTemporaryDirectory()

        let first = try makeFile(named: "a.txt", in: directory)
        let second = try makeFile(named: "b.txt", in: directory)
        let third = try makeFile(named: "c.txt", in: directory)

        let plans = OutgoingSelectionPlanner.plans(
            for: [first, second, third]
        )

        // Les avoir choisis d'un même geste est ce qui en fait un lot.
        XCTAssertEqual(plans.count, 1)
        XCTAssertNil(plans.first?.folderName)
        XCTAssertEqual(plans.first?.files.count, 3)
        XCTAssertEqual(plans.first?.announcesBatch, true)

        // Sans dossier d'origine, aucun chemin interne à préserver.
        XCTAssertEqual(
            plans.first?.files.compactMap(\.relativePath),
            []
        )
    }

    func testFileSelectionPreservesTheChosenOrder() throws {

        let directory = try makeTemporaryDirectory()

        let first = try makeFile(named: "z.txt", in: directory)
        let second = try makeFile(named: "a.txt", in: directory)

        let plans = OutgoingSelectionPlanner.plans(
            for: [first, second]
        )

        XCTAssertEqual(
            plans.first?.files.map(\.url.lastPathComponent),
            ["z.txt", "a.txt"]
        )
    }

    func testEmptySelectionProducesNoPlan() {

        XCTAssertTrue(
            OutgoingSelectionPlanner.plans(for: []).isEmpty
        )
    }

    // MARK: - Dossier

    func testFolderFormsItsOwnPlanNamedAfterTheFolder() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Vacances", in: parent)

        _ = try makeFile(named: "plage.jpg", in: folder)

        let plans = OutgoingSelectionPlanner.plans(for: [folder])

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.folderName, "Vacances")
        XCTAssertEqual(plans.first?.folderURL, folder)
        XCTAssertEqual(
            plans.first?.files.map(\.relativePath),
            ["plage.jpg"]
        )
    }

    func testFolderWithASingleFileStillAnnouncesABatch() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Solo", in: parent)

        _ = try makeFile(named: "unique.txt", in: folder)

        let plans = OutgoingSelectionPlanner.plans(for: [folder])

        // L'utilisateur a choisi un dossier : il doit en retrouver un,
        // même s'il ne contient qu'un fichier.
        XCTAssertEqual(plans.first?.files.count, 1)
        XCTAssertEqual(plans.first?.announcesBatch, true)
    }

    func testNestedStructureIsPreservedAsRelativePaths() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Projet", in: parent)

        let sub = try makeDirectory(named: "images", in: folder)
        let deep = try makeDirectory(named: "icônes", in: sub)

        _ = try makeFile(named: "readme.md", in: folder)
        _ = try makeFile(named: "logo.png", in: sub)
        _ = try makeFile(named: "petit.png", in: deep)

        let plans = OutgoingSelectionPlanner.plans(for: [folder])

        // Le chemin relatif ne répète pas le nom du dossier : celui-ci
        // voyage dans folderName, et le récepteur compose les deux.
        XCTAssertEqual(
            plans.first?.files.map(\.relativePath),
            [
                "images/icônes/petit.png",
                "images/logo.png",
                "readme.md"
            ]
        )
    }

    func testFolderEnumerationOrderIsStableAndAlphabetical() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Ordre", in: parent)

        for name in ["c.txt", "a.txt", "b.txt"] {
            _ = try makeFile(named: name, in: folder)
        }

        // La file est FIFO : un ordre reproductible rend l'envoi observable.
        let first = OutgoingSelectionPlanner.plans(for: [folder])
        let second = OutgoingSelectionPlanner.plans(for: [folder])

        XCTAssertEqual(
            first.first?.files.map(\.relativePath),
            ["a.txt", "b.txt", "c.txt"]
        )

        XCTAssertEqual(
            first.first?.files,
            second.first?.files
        )
    }

    func testIntermediateDirectoriesAreNotSentThemselves() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Arbre", in: parent)

        let sub = try makeDirectory(named: "vide", in: folder)
        _ = try makeDirectory(named: "encoreVide", in: sub)

        _ = try makeFile(named: "seul.txt", in: folder)

        let plans = OutgoingSelectionPlanner.plans(for: [folder])

        // Le récepteur recrée l'arborescence depuis les chemins relatifs :
        // envoyer les dossiers eux-mêmes n'aurait aucun sens.
        XCTAssertEqual(
            plans.first?.files.map(\.relativePath),
            ["seul.txt"]
        )
    }

    func testEmptyFolderProducesNoPlan() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Vide", in: parent)

        // Annoncer un lot sans fichier laisserait un dossier vide chez le
        // récepteur.
        XCTAssertTrue(
            OutgoingSelectionPlanner.plans(for: [folder]).isEmpty
        )
    }

    func testFolderContainingOnlyEmptySubfoldersProducesNoPlan() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Coquille", in: parent)

        _ = try makeDirectory(named: "rien", in: folder)

        XCTAssertTrue(
            OutgoingSelectionPlanner.plans(for: [folder]).isEmpty
        )
    }

    func testHiddenFilesAreNotSent() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Caché", in: parent)

        _ = try makeFile(named: "visible.txt", in: folder)
        _ = try makeFile(named: ".DS_Store", in: folder)

        let plans = OutgoingSelectionPlanner.plans(for: [folder])

        XCTAssertEqual(
            plans.first?.files.map(\.relativePath),
            ["visible.txt"]
        )
    }

    // MARK: - Sélections mélangées

    func testEachFolderFormsItsOwnPlan() throws {

        let parent = try makeTemporaryDirectory()

        let first = try makeDirectory(named: "Un", in: parent)
        let second = try makeDirectory(named: "Deux", in: parent)

        _ = try makeFile(named: "a.txt", in: first)
        _ = try makeFile(named: "b.txt", in: second)

        let plans = OutgoingSelectionPlanner.plans(
            for: [first, second]
        )

        // Deux dossiers déposés donnent deux lots, donc deux sous-dossiers
        // distincts à l'arrivée.
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(
            plans.map(\.folderName),
            ["Un", "Deux"]
        )
    }

    func testFilesAndFoldersAreSeparatedIntoDistinctPlans() throws {

        let parent = try makeTemporaryDirectory()

        let looseFile = try makeFile(named: "libre.txt", in: parent)
        let folder = try makeDirectory(named: "Groupe", in: parent)

        _ = try makeFile(named: "dedans.txt", in: folder)

        let plans = OutgoingSelectionPlanner.plans(
            for: [folder, looseFile]
        )

        XCTAssertEqual(plans.count, 2)

        // Les fichiers isolés passent devant : ils sont immédiatement
        // envoyables, là où un dossier demande d'abord d'être parcouru.
        XCTAssertNil(plans.first?.folderName)
        XCTAssertEqual(
            plans.first?.files.map(\.url.lastPathComponent),
            ["libre.txt"]
        )

        XCTAssertEqual(plans.last?.folderName, "Groupe")
        XCTAssertEqual(
            plans.last?.files.map(\.relativePath),
            ["dedans.txt"]
        )
    }

    func testEmptyFolderMixedWithFilesLeavesTheFilePlanIntact() throws {

        let parent = try makeTemporaryDirectory()

        let looseFile = try makeFile(named: "libre.txt", in: parent)
        let emptyFolder = try makeDirectory(named: "Vide", in: parent)

        let plans = OutgoingSelectionPlanner.plans(
            for: [looseFile, emptyFolder]
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertNil(plans.first?.folderName)
    }

    // MARK: - Classification

    func testDirectoryAndFileAreToldApart() throws {

        let parent = try makeTemporaryDirectory()

        let folder = try makeDirectory(named: "Dossier", in: parent)
        let file = try makeFile(named: "fichier.txt", in: parent)

        XCTAssertTrue(OutgoingSelectionPlanner.isDirectory(folder))
        XCTAssertFalse(OutgoingSelectionPlanner.isDirectory(file))
    }

    func testMissingURLIsNotReportedAsADirectory() throws {

        let parent = try makeTemporaryDirectory()

        XCTAssertFalse(
            OutgoingSelectionPlanner.isDirectory(
                parent.appendingPathComponent("absent")
            )
        )
    }

    // MARK: - Chemin relatif

    func testRelativePathIsNilWhenTheFileIsOutsideTheFolder() throws {

        let parent = try makeTemporaryDirectory()

        let folder = try makeDirectory(named: "Dedans", in: parent)
        let outside = try makeFile(named: "dehors.txt", in: parent)

        XCTAssertNil(
            OutgoingSelectionPlanner.relativePath(
                of: outside,
                under: folder
            )
        )
    }

    func testRelativePathIsNilForTheFolderItself() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Lui", in: parent)

        XCTAssertNil(
            OutgoingSelectionPlanner.relativePath(
                of: folder,
                under: folder
            )
        )
    }

    func testRelativePathToleratesUnresolvedSymlinkForms() throws {

        let parent = try makeTemporaryDirectory()
        let folder = try makeDirectory(named: "Lien", in: parent)

        let file = try makeFile(named: "cible.txt", in: folder)

        // Un dossier temporaire arrive volontiers en « /var/… » alors que
        // le parcours renvoie « /private/var/… » : comparer les formes
        // brutes ferait échouer tous les chemins.
        let resolvedFolder = folder.resolvingSymlinksInPath()

        XCTAssertEqual(
            OutgoingSelectionPlanner.relativePath(
                of: file,
                under: resolvedFolder
            ),
            "cible.txt"
        )

        XCTAssertEqual(
            OutgoingSelectionPlanner.relativePath(
                of: file.resolvingSymlinksInPath(),
                under: folder
            ),
            "cible.txt"
        )
    }

    // MARK: - Outils

    private func makeTemporaryDirectory() throws -> URL {

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OutgoingSelectionPlannerTests-\(UUID().uuidString)"
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

    private func makeDirectory(
        named name: String,
        in parent: URL
    ) throws -> URL {

        let directory = parent.appendingPathComponent(name)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return directory
    }

    private func makeFile(
        named name: String,
        in directory: URL
    ) throws -> URL {

        let fileURL = directory.appendingPathComponent(name)

        try Data("contenu de \(name)".utf8).write(to: fileURL)

        return fileURL
    }
}
