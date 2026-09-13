//
//  PendingShareControllerTests.swift
//  AirBridgeTests
//
//  Tests unitaires du `PendingShareController` (lot stationné par une
//  extension de partage dans l'App Group, présenté sans envoi
//  automatique).
//
//  Couvre le correctif de partage système (macOS Finder / iOS Share
//  Extension) :
//  - présentation unique (dédup par signature), jamais de suppression à
//    la présentation / fermeture / fin d'un envoi ;
//  - purge par fichier : un fichier de lot n'est retiré QUE s'il est
//    livré (sourceFileURL d'un transfert sortant `completed`) ; lot
//    partiellement envoyé conservé ; répertoire + manifeste retirés
//    uniquement quand plus aucun fichier nécessaire ne s'y trouve ;
//  - appartenance réelle au dossier `PendingShares` (chemin canonique,
//    UUID), jamais par substring ;
//  - erreurs de suppression remontées (et non avalées par `try?`).
//

import XCTest
@testable import AirBridge

@MainActor
final class PendingShareControllerTests: XCTestCase {

    // MARK: - Fixtures

    /// Conteneur App Group simulé (répertoire temporaire).
    private var containerURL: URL!

    /// Racine `PendingShares/<batchID>` du conteneur simulé.
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingShareTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        rootURL = PendingShareController.pendingSharesRoot(in: containerURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: containerURL)
        containerURL = nil
        rootURL = nil
        super.tearDown()
    }

    /// Crée un lot UUID avec `count` fichiers (`prefix-i.txt`) et un
    /// manifeste.
    private func makeBatch(
        count: Int = 2,
        prefix: String = "file"
    ) -> (batchID: String, directory: URL, files: [URL]) {
        let batchID = UUID().uuidString
        let directory = rootURL.appendingPathComponent(batchID)
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var files: [URL] = []
        for index in 0..<count {
            let file = directory.appendingPathComponent("\(prefix)-\(index).txt")
            try! "contenu-\(index)".write(to: file, atomically: true, encoding: .utf8)
            files.append(file)
        }
        try! "{}".write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        return (batchID, directory, files)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func controller() -> PendingShareController {
        PendingShareController()
    }

    // MARK: - Signature

    func test_signature_isOrderIndependent() {
        let a = URL(fileURLWithPath: "/tmp/zz.txt")
        let b = URL(fileURLWithPath: "/tmp/aa.txt")
        XCTAssertEqual(
            PendingShareController.signature(for: [a, b]),
            PendingShareController.signature(for: [b, a])
        )
    }

    // MARK: - Présentation (aucune suppression)

    func test_present_showsItemOnce() {
        let controller = controller()
        let batch = makeBatch(count: 2)

        controller.present(urls: batch.files)
        XCTAssertNotNil(controller.item)
        XCTAssertEqual(controller.item?.urls, batch.files)
    }

    func test_present_sameSignature_neverRepresentsTwice() {
        let controller = controller()
        let batch = makeBatch(count: 1)

        controller.present(urls: batch.files)
        controller.dismissed()
        XCTAssertNil(controller.item)

        // Même sélection, même signature : ne doit JAMAIS être re-présentée
        // (deux chemins de remise du même lot ne déclenchent pas d'envoi double).
        controller.present(urls: batch.files)
        XCTAssertNil(controller.item)
    }

    func test_present_isSingleFile_atATime() {
        let controller = controller()
        let first = makeBatch(prefix: "first")
        let second = makeBatch(prefix: "second")

        controller.present(urls: first.files)
        // Un second lot pendant que la feuille est ouverte : ignoré.
        controller.present(urls: second.files)
        XCTAssertEqual(controller.item?.urls, first.files)
    }

    func test_present_filtersNonFileURLs_andEmpty() {
        let controller = controller()
        controller.present(urls: [URL(string: "https://example.com/fichier.pdf")!])
        XCTAssertNil(controller.item)

        controller.present(urls: [])
        XCTAssertNil(controller.item)
    }

    func test_dismissed_clearsItem_keepsFiles() {
        let controller = controller()
        let batch = makeBatch(count: 2)

        controller.present(urls: batch.files)
        controller.dismissed()
        XCTAssertNil(controller.item)
        // Simple fermeture : AUCUNE suppression.
        for file in batch.files {
            XCTAssertTrue(exists(file), "La fermeture ne doit jamais supprimer un fichier.")
        }
        XCTAssertTrue(exists(batch.directory.appendingPathComponent("manifest.json")))
    }

    func test_finish_keepsFiles_whetherOrNotImported() {
        for imported in [true, false] {
            let controller = controller()
            let batch = makeBatch(count: 2)
            controller.present(urls: batch.files)
            controller.finish(imported: imported)
            XCTAssertNil(controller.item)
            for file in batch.files {
                XCTAssertTrue(exists(file), "finish(imported: \(imported)) ne doit rien supprimer.")
            }
        }
    }

    // MARK: - Appartenance au dossier PendingShares

    func test_batchFileMatch_acceptsDirectChildUnderUUID() {
        let batch = makeBatch(count: 1)
        let match = PendingShareController.batchFileMatch(
            batch.files[0],
            rootPath: rootURL.path
        )
        XCTAssertEqual(match?.batchID, batch.batchID)
        XCTAssertEqual(match?.fileName, batch.files[0].lastPathComponent)
    }

    func test_batchFileMatch_rejectsSubstringPendingShares() {
        // Une URL qui contient « /PendingShares/ » mais dans un AUTRE
        // conteneur ne doit jamais être rattachée à notre racine.
        let other = URL(
            fileURLWithPath: "/tmp/Autre/PendingShares/\(UUID().uuidString)/fichier.txt"
        )
        let match = PendingShareController.batchFileMatch(other, rootPath: rootURL.path)
        XCTAssertNil(match)
    }

    func test_batchFileMatch_rejectsSiblingWithSamePrefix() {
        // Racine /<container>/PendingShares ; un dossier « PendingSharesXX »
        // voisin ne doit pas passer le test de préfixe.
        let batchID = UUID().uuidString
        let sibling = URL(
            fileURLWithPath: "\(containerURL.path)PendingSharesX/\(batchID)/fichier.txt"
        )
        let match = PendingShareController.batchFileMatch(sibling, rootPath: rootURL.path)
        XCTAssertNil(match)
    }

    func test_batchFileMatch_rejectsNonUUIDBatchName() {
        let url = URL(
            fileURLWithPath: "\(rootURL.path)/not-a-uuid/fichier.txt"
        )
        let match = PendingShareController.batchFileMatch(url, rootPath: rootURL.path)
        XCTAssertNil(match)
    }

    func test_batchFileMatch_rejectsNestedFile() {
        let batchID = UUID().uuidString
        // Trois composants (sous-dossier) : hors structure de lot.
        let nested = URL(
            fileURLWithPath: "\(rootURL.path)/\(batchID)/sousdossier/fichier.txt"
        )
        let match = PendingShareController.batchFileMatch(nested, rootPath: rootURL.path)
        XCTAssertNil(match)
    }

    func test_batchFileMatch_rejectsNonFileURL() {
        let match = PendingShareController.batchFileMatch(
            URL(string: "https://example.com/PendingShares/\(UUID().uuidString)/f.txt")!,
            rootPath: rootURL.path
        )
        XCTAssertNil(match)
    }

    // MARK: - Purge (unique point de suppression)

    func test_prune_deletesOnlyDeliveredFiles_partialSend() {
        let controller = controller()
        let batch = makeBatch(count: 3)
        let delivered = Set(batch.files.prefix(2).map(\.standardizedFileURL))

        let result = controller.pruneDeliveredBatches(
            deliveredSourceURLs: delivered,
            containerURL: containerURL
        )

        XCTAssertEqual(result.deletedFiles, 2)
        XCTAssertEqual(result.removedBatchDirectories, 0)
        XCTAssertTrue(result.errors.isEmpty)
        // Les deux fichiers livrés sont retirés…
        XCTAssertFalse(exists(batch.files[0]))
        XCTAssertFalse(exists(batch.files[1]))
        // … le troisième (transfert en cours / échec / jamais importé)
        // est conservé pour une nouvelle tentative, ainsi que le manifeste.
        XCTAssertTrue(exists(batch.files[2]))
        XCTAssertTrue(exists(batch.directory.appendingPathComponent("manifest.json")))
        XCTAssertTrue(exists(batch.directory))
    }

    func test_prune_doesNotDeleteUndeliveredFiles() {
        let controller = controller()
        let batch = makeBatch(count: 2)

        let result = controller.pruneDeliveredBatches(
            deliveredSourceURLs: [],
            containerURL: containerURL
        )

        XCTAssertEqual(result.deletedFiles, 0)
        XCTAssertEqual(result.removedBatchDirectories, 0)
        for file in batch.files {
            XCTAssertTrue(exists(file))
        }
        XCTAssertTrue(exists(batch.directory))
    }

    func test_prune_removesBatchOnlyWhenNoLiveFiles() {
        let controller = controller()
        let batch = makeBatch(count: 2)
        let delivered = Set(batch.files.map(\.standardizedFileURL))

        let result = controller.pruneDeliveredBatches(
            deliveredSourceURLs: delivered,
            containerURL: containerURL
        )

        XCTAssertEqual(result.deletedFiles, 2)
        XCTAssertEqual(result.removedBatchDirectories, 1)
        // Le répertoire complet (manifeste inclus) est retiré : son seul
        // contenu était des fichiers livrés + le marqueur de complétion.
        XCTAssertFalse(exists(batch.directory), "Un lot entièrement livré doit disparaître.")
    }

    func test_prune_removesManifestOnlyBatch() {
        let controller = controller()
        let batchID = UUID().uuidString
        let directory = rootURL.appendingPathComponent(batchID)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! "{}".write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = controller.pruneDeliveredBatches(
            deliveredSourceURLs: [],
            containerURL: containerURL
        )

        // Aucun fichier utile : le lot (manifeste de complétion) est retiré.
        XCTAssertEqual(result.deletedFiles, 0)
        XCTAssertEqual(result.removedBatchDirectories, 1)
        XCTAssertFalse(exists(directory))
    }

    func test_prune_ignoresNonUUIDDirectories() {
        let controller = controller()
        // Dossier au nom non-UUID : pas un lot de nos extensions → ignoré,
        // même si un fichier y semble « livré ».
        let impostor = rootURL.appendingPathComponent("bookmarks")
        try! FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: true)
        let file = impostor.appendingPathComponent("fichier.txt")
        try! "x".write(to: file, atomically: true, encoding: .utf8)

        let result = controller.pruneDeliveredBatches(
            deliveredSourceURLs: [file.standardizedFileURL],
            containerURL: containerURL
        )

        XCTAssertEqual(result.deletedFiles, 0)
        XCTAssertEqual(result.removedBatchDirectories, 0)
        XCTAssertTrue(exists(file))
        XCTAssertTrue(exists(impostor))
    }

    func test_prune_reportsError_whenContainerUnreadable() {
        let controller = controller()
        let missingContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-absente-\(UUID().uuidString)")

        let result = controller.pruneDeliveredBatches(
            deliveredSourceURLs: [],
            containerURL: missingContainer
        )

        XCTAssertEqual(result.deletedFiles, 0)
        XCTAssertEqual(result.removedBatchDirectories, 0)
        XCTAssertEqual(result.errors.count, 1, "L'échec de lecture doit être remonté, pas avalé.")
    }
}