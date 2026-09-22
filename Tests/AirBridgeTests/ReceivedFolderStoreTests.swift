//
//  ReceivedFolderStoreTests.swift
//  AirBridgeTests
//
//  Tests du magasin du dossier de réception choisi par l'utilisateur.
//
//  Ce dossier est le contrat de l'utilisateur : « mes fichiers atterrissent
//  ici ». La persistance repose sur un security-scoped bookmark ; la garde
//  `startAccessingSecurityScopedResource` est ce qui empêche l'application
//  de mémoriser un dossier auquel elle n'a plus accès.
//

import XCTest
@testable import AirBridge

@MainActor
final class ReceivedFolderStoreTests: XCTestCase {

    /// Clé privée du store, répétée ici intentionnellement : le test
    /// nettoie les restes d'un bookmark pour repartir d'un état connu.
    private static let bookmarkKey = "airbridge.received-folder-bookmark"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        super.tearDown()
    }

    func testStartsWithoutDirectory() {
        let store = ReceivedFolderStore()
        XCTAssertNil(store.selectedDirectory)
    }

    func testClearDirectoryRemovesBookmark() {
        let store = ReceivedFolderStore()

        store.clearDirectory()

        XCTAssertNil(store.selectedDirectory)
        XCTAssertNil(
            UserDefaults.standard.data(forKey: Self.bookmarkKey),
            "clearDirectory doit aussi oublier le bookmark persisté."
        )
    }

    func testSelectingNonSecurityScopedURLIsRefused() {
        // En contexte de test, l'URL temporaire n'est pas security-scoped :
        // `startAccessingSecurityScopedResource` renvoie faux et la garde
        // empêche la mémorisation d'un dossier inaccessible.
        let store = ReceivedFolderStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbridge-test-\(UUID().uuidString)")

        store.selectDirectory(url)

        XCTAssertNil(store.selectedDirectory)
        XCTAssertNil(UserDefaults.standard.data(forKey: Self.bookmarkKey))
    }

    func testRestoreWithoutBookmarkKeepsNil() {
        // Aucun bookmark persisté (setUp l'a effacé) : la restauration
        // ne doit rien inventer.
        let store = ReceivedFolderStore()

        store.clearDirectory()

        let restored = ReceivedFolderStore()
        XCTAssertNil(restored.selectedDirectory)
    }
}
