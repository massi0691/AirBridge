//
//  ReceivedBatchSymlinkGuardTests.swift
//  AirBridgeTests
//

import XCTest
@testable import AirBridge

/// Vérifie la garde posée entre la validation de confinement et le
/// déplacement du fichier reçu.
///
/// Les tests travaillent sur de vrais dossiers temporaires : la règle porte
/// sur ce que le système de fichiers contient réellement, donc une doublure
/// de `FileManager` ne prouverait rien.
final class ReceivedBatchSymlinkGuardTests: XCTestCase {

    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let base = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
        .appendingPathComponent(
            "AirBridgeSymlinkGuard-\(UUID().uuidString)"
        )

        root = base.appendingPathComponent("Réception")
        outside = base.appendingPathComponent("Ailleurs")

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        let base = root.deletingLastPathComponent()

        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }

        root = nil
        outside = nil

        try super.tearDownWithError()
    }

    // MARK: - Chemins sains

    func testAFileDirectlyInTheRootIsAccepted() {
        let destination = root.appendingPathComponent("video.mov")

        XCTAssertTrue(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: destination,
                from: root
            )
        )
    }

    func testAFileInARealSubfolderIsAccepted() throws {
        let folder = root.appendingPathComponent("Réception_2026")

        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        XCTAssertTrue(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: folder.appendingPathComponent("photo.jpg"),
                from: root
            )
        )
    }

    /// Le cas courant : ni le sous-dossier ni le fichier n'existent encore
    /// au moment de la vérification.
    func testAPathThatDoesNotExistYetIsAccepted() {
        let destination = root
            .appendingPathComponent("Lot")
            .appendingPathComponent("sous-dossier")
            .appendingPathComponent("fichier.bin")

        XCTAssertTrue(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: destination,
                from: root
            )
        )
    }

    func testARealFileAlreadyPresentIsAccepted() throws {
        let destination = root.appendingPathComponent("déjà-là.bin")

        try Data([0x01]).write(to: destination)

        XCTAssertTrue(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: destination,
                from: root
            )
        )
    }

    // MARK: - Maillon intermédiaire piégé

    /// Le scénario visé : le sous-dossier du lot a été remplacé par un lien
    /// vers l'extérieur après la validation de confinement. `rename` suit
    /// les liens des composants intermédiaires, donc le fichier sortirait.
    func testAnIntermediateSymlinkIsRefused() throws {
        let trap = root.appendingPathComponent("Lot")

        try FileManager.default.createSymbolicLink(
            at: trap,
            withDestinationURL: outside
        )

        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: trap.appendingPathComponent("fichier.bin"),
                from: root
            )
        )
    }

    /// Le lien peut être enfoui : la descente doit examiner chaque maillon,
    /// pas seulement le premier.
    func testASymlinkDeeperInThePathIsRefused() throws {
        let folder = root.appendingPathComponent("Lot")

        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let trap = folder.appendingPathComponent("images")

        try FileManager.default.createSymbolicLink(
            at: trap,
            withDestinationURL: outside
        )

        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: trap.appendingPathComponent("photo.jpg"),
                from: root
            )
        )
    }

    /// Un lien qui pointe *dans* le dossier de réception est refusé lui
    /// aussi : la garde ne cherche pas à deviner une intention, seulement à
    /// écrire là où le chemin le dit.
    func testAnIntermediateSymlinkPointingInsideIsAlsoRefused() throws {
        let real = root.appendingPathComponent("Vrai")

        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: true
        )

        let trap = root.appendingPathComponent("Lot")

        try FileManager.default.createSymbolicLink(
            at: trap,
            withDestinationURL: real
        )

        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: trap.appendingPathComponent("fichier.bin"),
                from: root
            )
        )
    }

    // MARK: - Dernier maillon piégé

    /// `rename` ne suit pas le lien du dernier composant, mais le refuser
    /// évite d'écraser un lien que l'utilisateur a posé lui-même.
    func testASymlinkAsTheFinalComponentIsRefused() throws {
        let trap = root.appendingPathComponent("fichier.bin")

        try FileManager.default.createSymbolicLink(
            at: trap,
            withDestinationURL: outside
                .appendingPathComponent("cible.bin")
        )

        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: trap,
                from: root
            )
        )
    }

    /// Un lien cassé compte comme un lien : `attributesOfItem` ne suit pas
    /// le dernier maillon, donc son absence de cible ne l'efface pas.
    func testABrokenSymlinkIsRefused() throws {
        let trap = root.appendingPathComponent("Lot")

        try FileManager.default.createSymbolicLink(
            at: trap,
            withDestinationURL: outside
                .appendingPathComponent("jamais-créé")
        )

        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: trap.appendingPathComponent("fichier.bin"),
                from: root
            )
        )
    }

    // MARK: - Racine

    /// La descente s'arrête à la racine : ce qu'il y a au-dessus est le
    /// choix de l'utilisateur, et sur macOS `/tmp` est lui-même un lien.
    func testASymlinkAboveTheRootIsIgnored() throws {
        let base = root.deletingLastPathComponent()
        let alias = base.appendingPathComponent("AliasDeRéception")

        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: root
        )

        XCTAssertTrue(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: alias.appendingPathComponent("fichier.bin"),
                from: alias
            )
        )
    }

    func testADestinationOutsideTheRootIsRefused() {
        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: outside.appendingPathComponent("fichier.bin"),
                from: root
            )
        )
    }

    /// La racine elle-même n'est pas une destination : il faut au moins un
    /// composant en dessous.
    func testTheRootItselfIsRefused() {
        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: root,
                from: root
            )
        )
    }

    /// Un chemin qui remonte est refusé même s'il finit sous la racine :
    /// c'est le chemin standardisé qui est examiné.
    func testATraversingPathIsRefused() {
        let destination = root
            .appendingPathComponent("..")
            .appendingPathComponent("Ailleurs")
            .appendingPathComponent("fichier.bin")

        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: destination,
                from: root
            )
        )
    }

    // MARK: - Cohérence avec le confinement

    /// Les deux vérifications sont complémentaires, non redondantes :
    /// `isContained` résout les liens et accepte donc un chemin dont un
    /// maillon est un lien restant à l'intérieur, là où la garde le refuse.
    func testTheGuardIsStricterThanContainmentOnAnInsideSymlink() throws {
        let real = root.appendingPathComponent("Vrai")

        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: true
        )

        let trap = root.appendingPathComponent("Lot")

        try FileManager.default.createSymbolicLink(
            at: trap,
            withDestinationURL: real
        )

        let destination = trap.appendingPathComponent("fichier.bin")

        XCTAssertTrue(
            ReceivedBatchLayout.isContained(destination, in: root)
        )

        XCTAssertFalse(
            ReceivedBatchLayout.containsNoSymbolicLink(
                pathTo: destination,
                from: root
            )
        )
    }
}
