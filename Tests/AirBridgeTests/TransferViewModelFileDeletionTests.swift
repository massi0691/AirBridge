//
//  TransferViewModelFileDeletionTests.swift
//  AirBridgeTests
//
//  Tests unitaires de la fonction `deleteFile(at:)` exposée par
//  `TransferViewModel`. Cette fonction pure est le cœur de
//  `deleteStoredFile(for:)` : elle applique les règles métier
//  (refus des `.partial`, mapping d'erreurs) sans dépendre d'un
//  `AirBridgeCore` complet.
//
//  Les cas couverts :
//   - suppression d'un fichier existant → succès + fichier absent
//     du disque ;
//   - suppression d'un fichier inexistant → `.fileNotFound` ;
//   - suppression d'un dossier → `.unknown` (FileManager refuse de
//     supprimer un répertoire avec `removeItem` par défaut, ou
//     réussit si le dossier est vide selon les plateformes) ;
//   - suppression d'un fichier `.partial` → `.permissionDenied`
//     (protection contre la suppression d'un fichier de reprise en
//     cours) ;
//   - suppression d'un fichier après l'avoir rendu inaccessible en
//     passant un `FileManager` factice.
//
//  La conformité `Error` de `FileDeleteError` est également
//  vérifiée.
//
//  Couvre la Phase UX AirDrop-like (sheet d'actions et suppression
//  de stockage).
//

import XCTest
@testable import AirBridge

@MainActor
final class TransferViewModelFileDeletionTests: XCTestCase {

    // MARK: - FileDeleteError

    /// `FileDeleteError` doit être conforme `Error` pour pouvoir
    /// être utilisé dans un `Result<…, FileDeleteError>`.
    func testFileDeleteErrorConformsToError() {
        let error: Error = FileDeleteError.fileNotFound
        // Si la conformance est manquante, cette conversion ne
        // compile pas.
        XCTAssertNotNil(
            error as? FileDeleteError,
            "FileDeleteError doit être conforme à Error."
        )
    }

    /// Les trois cas documentés (`fileNotFound`,
    /// `permissionDenied`, `unknown`) doivent tous être
    /// instanciables.
    func testFileDeleteErrorAllCases() {
        let _: FileDeleteError = .fileNotFound
        let _: FileDeleteError = .permissionDenied
        let _: FileDeleteError = .unknown(
            NSError(domain: "test", code: 0)
        )
    }

    // MARK: - Suppression réussie

    /// Suppression d'un fichier existant : le résultat doit être
    /// `.success` ET le fichier ne doit plus exister sur disque.
    func testDeleteFileRemovesExistingFile() throws {
        let tempURL = try makeTempFile(
            name: "airbridge-delete-ok.bin",
            contents: Data("hello".utf8)
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempURL.path),
            "Pré-condition : le fichier doit exister avant suppression."
        )

        let result = TransferViewModel.deleteFile(at: tempURL)

        switch result {
        case .success:
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: tempURL.path),
                "Le fichier doit avoir été supprimé du disque."
            )
        case .failure(let error):
            XCTFail("Suppression d'un fichier existant a échoué : \(error)")
        }
    }

    /// Suppression dans un sous-dossier (chemin non-trivial) : on
    /// vérifie que la résolution de chemin se fait correctement.
    func testDeleteFileInNestedDirectory() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirBridgeDeleteTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let nestedURL = baseDir.appendingPathComponent("nested.txt")
        try Data("content".utf8).write(to: nestedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))

        let result = TransferViewModel.deleteFile(at: nestedURL)

        guard case .success = result else {
            return XCTFail("Suppression d'un fichier niché doit réussir.")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: nestedURL.path),
            "Le fichier niché doit avoir été supprimé."
        )
    }

    // MARK: - Fichier inexistant

    /// Suppression d'un fichier qui n'existe pas → `.fileNotFound`.
    /// Le test est robuste aux environnements où le dossier parent
    /// n'existe pas non plus : on crée le parent puis on cible un
    /// nom de fichier arbitraire qui n'a jamais été créé.
    func testDeleteFileReturnsFileNotFoundForMissingFile() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "airbridge-deleted-\(UUID().uuidString).bin"
            )
        // Le fichier n'a jamais existé.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingURL.path),
            "Pré-condition : le fichier ne doit pas exister."
        )

        let result = TransferViewModel.deleteFile(at: missingURL)

        guard case .failure(.fileNotFound) = result else {
            return XCTFail(
                "Un fichier inexistant doit produire .fileNotFound, reçu \(result)."
            )
        }
    }

    // MARK: - Protection .partial

    /// Suppression d'un fichier portant l'extension `.partial` →
    /// `.permissionDenied`, même si le fichier existe. C'est la
    /// garde anti-écrasement d'un fichier de reprise en cours.
    func testDeleteFileRefusesPartialFiles() throws {
        let partialURL = try makeTempFile(
            name: "resume.partial",
            contents: Data("en cours".utf8)
        )
        defer { try? FileManager.default.removeItem(at: partialURL) }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partialURL.path),
            "Pré-condition : le .partial doit exister."
        )

        let result = TransferViewModel.deleteFile(at: partialURL)

        guard case .failure(.permissionDenied) = result else {
            return XCTFail(
                "Un .partial doit produire .permissionDenied, reçu \(result)."
            )
        }
        // Et le fichier ne doit pas avoir été touché.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partialURL.path),
            "Le .partial ne doit pas avoir été supprimé du disque."
        )
    }

    /// La protection `.partial` doit s'appliquer avant la
    /// vérification d'existence, donc même un `.partial`
    /// inexistant doit produire `.permissionDenied` (l'erreur
    /// métier prime sur l'absence de fichier : on ne veut pas
    /// révéler qu'un fichier n'existe pas s'il s'appelle
    /// `.partial`).
    func testDeleteFileRefusesMissingPartialToo() {
        let missingPartial = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).partial")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingPartial.path)
        )

        let result = TransferViewModel.deleteFile(at: missingPartial)

        guard case .failure(.permissionDenied) = result else {
            return XCTFail(
                "Un .partial inexistant doit aussi produire .permissionDenied, reçu \(result)."
            )
        }
    }

    // MARK: - Dossier

    /// Suppression d'un dossier (et non d'un fichier) : sur la
    /// plupart des plateformes `FileManager.removeItem` sur un
    /// dossier **vide** réussit. Le test est écrit de manière
    /// souple : on vérifie juste qu'aucun crash ne se produit et
    /// que le résultat est cohérent (succès OU `.unknown`, jamais
    /// `.fileNotFound` / `.permissionDenied`).
    func testDeleteFileOnDirectoryDoesNotCrash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "airbridge-dir-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = TransferViewModel.deleteFile(at: dir)

        // L'extension est vide, donc on n'est PAS dans la branche
        // `.partial`. On n'est PAS non plus dans la branche
        // `.fileNotFound` puisque le dossier existe. Selon
        // l'OS, la suppression réussit ou produit une erreur
        // `NSFileWriteUnknownError` mappée sur `.unknown`.
        switch result {
        case .success:
            // Comportement possible : le dossier a été supprimé.
            break
        case .failure(.unknown):
            // Comportement possible : FileManager refuse selon
            // l'OS/le format. Acceptable.
            break
        case .failure(let other):
            XCTFail(
                "Suppression d'un dossier ne doit produire ni .fileNotFound, ni .permissionDenied, reçu \(other)."
            )
        }
    }

    // MARK: - Injection de FileManager

    /// On peut injecter un `FileManager` factice via le paramètre
    /// `fileManager:` pour tester le mapping d'erreurs sans
    /// toucher au disque. On simule une `NSError` de code
    /// `NSFileWriteNoPermissionError` (513) et on vérifie qu'elle
    /// est mappée sur `.permissionDenied`.
    func testDeleteFileMapsPermissionError() {
        let fakeManager = FakeFileManager(
            behavior: .throwError(
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError
                )
            )
        )
        let url = URL(fileURLWithPath: "/tmp/fake.bin")
        let result = TransferViewModel.deleteFile(
            at: url,
            fileManager: fakeManager
        )
        guard case .failure(.permissionDenied) = result else {
            return XCTFail(
                "Une NSFileWriteNoPermissionError doit produire .permissionDenied, reçu \(result)."
            )
        }
    }

    /// Une `NSError` d'un autre code (ex. 0 — erreur inconnue)
    /// doit être mappée sur `.unknown(error)`.
    func testDeleteFileMapsUnknownError() {
        let underlying = NSError(
            domain: "custom",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let fakeManager = FakeFileManager(
            behavior: .throwError(underlying)
        )
        let url = URL(fileURLWithPath: "/tmp/fake.bin")
        let result = TransferViewModel.deleteFile(
            at: url,
            fileManager: fakeManager
        )
        guard case .failure(.unknown(let captured)) = result else {
            return XCTFail(
                "Une erreur non mappée doit produire .unknown, reçu \(result)."
            )
        }
        XCTAssertEqual(
            (captured as NSError).code,
            42,
            "L'erreur originale doit être encapsulée."
        )
    }

    // MARK: - Helpers

    /// Crée un fichier temporaire avec le contenu donné. L'extension
    /// est forcée (le caller passe le nom complet). Le fichier est
    /// laissé sur disque pour la durée du test ; le caller est
    /// responsable de le nettoyer via `defer`.
    private func makeTempFile(
        name: String,
        contents: Data
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }
}

// MARK: - FakeFileManager

/// Substituts minimaux pour tester le mapping d'erreurs sans
/// manipuler le disque. On ne couvre QUE le strict nécessaire
/// (existence + suppression), le reste des méthodes `FileManager`
/// n'est pas appelé par `deleteFile(at:fileManager:)`.
private final class FakeFileManager: FileManager, @unchecked Sendable {

    enum Behavior {
        case throwError(Error)
        case succeed
    }

    private let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        // Pour les tests, on suppose toujours que le fichier existe
        // (sinon la fonction retourne `.fileNotFound` avant même
        // d'arriver à `removeItem`).
        true
    }

    override func removeItem(at URL: URL) throws {
        switch behavior {
        case .throwError(let error):
            throw error
        case .succeed:
            return
        }
    }
}
