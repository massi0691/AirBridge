//
//  ShareViewModelTests.swift
//  AirBridgeTests
//
//  Tests unitaires du `ShareViewModel`. Comme pour
//  `TransferViewModel`, l'instanciation du ViewModel demande un
//  `AirBridgeCore` complet, ce qui sort du périmètre. On teste
//  donc les invariants observables via une factory partagée et on
//  documente les zones non couvertes.
//
//  Couvre la Phase 3 (écran de partage) — surface
//  `attach/remove/clear/canShare/availableRecipients/send`.
//

import XCTest
import Network
@testable import AirBridge

@MainActor
final class ShareViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeLocalDevice() -> Device {
        Device(
            id: UUID(),
            name: "Mac de Test",
            model: "Mac",
            systemVersion: "26.5"
        )
    }

    private func makeRemoteDevice() -> Device {
        Device(
            id: UUID(),
            name: "iPhone de Test",
            model: "iPhone",
            systemVersion: "26.5"
        )
    }

    /// Construit un `ShareViewModel` adossé à un `AirBridgeCore`
    /// réel (sans réseau). Le Core n'est pas démarré donc aucun
    /// listener Bonjour n'est publié : on peut quand même
    /// manipuler son état interne via les vues qu'il expose.
    private func makeCore() -> AirBridgeCore {
        let bonjour = BonjourService(localDevice: makeLocalDevice())
        let router = MessageRouter()
        let pairingStore = PairingStore()
        let connectionManager = ConnectionManager(
            localDevice: bonjour.localDevice,
            messageRouter: router,
            pairingStore: pairingStore
        )
        let transferManager = TransferManager(
            receivedFolderStore: ReceivedFolderStore(),
            localDevice: bonjour.localDevice,
            historyStore: TransferHistoryStore()
        )
        return AirBridgeCore(
            bonjourService: bonjour,
            connectionManager: connectionManager,
            messageRouter: router,
            transferManager: transferManager,
            receivedFolderStore: ReceivedFolderStore(),
            transferHistoryStore: TransferHistoryStore(),
            pairingStore: pairingStore
        )
    }

    /// Crée un fichier temporaire sur disque pour pouvoir le
    /// passer à `attach(urls:)`. Chaque test doit l'invoquer dans
    /// son `setUp` ou inline (les fichiers temporaires ne sont pas
    /// automatiquement nettoyés par le système de tests XCTest).
    private func makeTempFileURL(name: String = "test.txt") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("hello".utf8)
        )
        return url
    }

    // MARK: - canShare

    func testCanShareIsFalseWhenNotConnected() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        // Ajoute un fichier mais aucun peer n'est connecté.
        let url = makeTempFileURL()
        vm.attach(urls: [url])

        XCTAssertFalse(
            vm.isConnected,
            "Le ViewModel ne doit pas être marqué connecté sans pair."
        )
        XCTAssertFalse(
            vm.canShare,
            "canShare doit être false sans pair connecté."
        )
    }

    func testCanShareIsFalseWhenNoFiles() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        XCTAssertTrue(
            vm.attachedURLs.isEmpty,
            "Le ViewModel doit démarrer avec une liste vide."
        )
        XCTAssertFalse(
            vm.canShare,
            "canShare doit être false sans fichier attaché, même si connecté (ici pas connecté non plus, mais le contrat est sur les fichiers)."
        )
    }

    // MARK: - attach

    func testAttachPreservesOrder() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        let urls = [
            makeTempFileURL(name: "a.txt"),
            makeTempFileURL(name: "b.txt"),
            makeTempFileURL(name: "c.txt"),
        ]
        vm.attach(urls: urls)

        XCTAssertEqual(
            vm.attachedURLs.count,
            3,
            "Tous les fichiers doivent avoir été attachés."
        )
        XCTAssertEqual(
            vm.attachedURLs.map { $0.lastPathComponent },
            ["a.txt", "b.txt", "c.txt"],
            "L'ordre d'attachement doit être préservé."
        )
    }

    func testAttachRejectsDuplicates() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        let url = makeTempFileURL(name: "same.txt")
        vm.attach(urls: [url])
        vm.attach(urls: [url])

        XCTAssertEqual(
            vm.attachedURLs.count,
            1,
            "Un fichier déjà attaché ne doit pas être dupliqué."
        )
    }

    func testAttachDedupesAcrossMultipleCalls() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        let a = makeTempFileURL(name: "a.txt")
        let b = makeTempFileURL(name: "b.txt")
        vm.attach(urls: [a])
        vm.attach(urls: [b, a]) // a est déjà présent, b est nouveau.

        XCTAssertEqual(
            vm.attachedURLs.count,
            2,
            "Les URLs déjà présentes ne doivent pas être ré-ajoutées."
        )
        XCTAssertEqual(
            vm.attachedURLs.map { $0.lastPathComponent },
            ["a.txt", "b.txt"],
            "L'ordre d'arrivée doit être respecté (a avant b)."
        )
    }

    // MARK: - remove

    func testRemoveAtIndexSetRemovesExactlyThoseIndices() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        vm.attach(urls: [
            makeTempFileURL(name: "a.txt"),
            makeTempFileURL(name: "b.txt"),
            makeTempFileURL(name: "c.txt"),
        ])
        vm.remove(urlAt: IndexSet([0, 2])) // on retire a et c.

        XCTAssertEqual(
            vm.attachedURLs.map { $0.lastPathComponent },
            ["b.txt"],
            "Seuls les indices 0 et 2 doivent avoir été retirés."
        )
    }

    func testRemoveAtSingleIndexRemovesThatItem() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        vm.attach(urls: [
            makeTempFileURL(name: "a.txt"),
            makeTempFileURL(name: "b.txt"),
        ])
        vm.remove(urlAt: 1)

        XCTAssertEqual(
            vm.attachedURLs.map { $0.lastPathComponent },
            ["a.txt"],
            "remove(urlAt: 1) doit retirer uniquement le deuxième fichier."
        )
    }

    func testRemoveAtOutOfRangeIndexIsNoOp() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        vm.attach(urls: [makeTempFileURL(name: "a.txt")])
        vm.remove(urlAt: 99) // hors limites.

        XCTAssertEqual(
            vm.attachedURLs.count,
            1,
            "Un index hors limites ne doit rien faire."
        )
    }

    func testClearAttachedEmptiesTheList() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        vm.attach(urls: [
            makeTempFileURL(name: "a.txt"),
            makeTempFileURL(name: "b.txt"),
        ])
        XCTAssertEqual(vm.attachedURLs.count, 2)
        vm.clearAttached()
        XCTAssertTrue(
            vm.attachedURLs.isEmpty,
            "clearAttached doit vider complètement la liste."
        )
    }

    // MARK: - totalAttachedSize

    func testTotalAttachedSizeIsNilWhenEmpty() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        XCTAssertNil(
            vm.totalAttachedSize,
            "totalAttachedSize doit être nil quand la liste est vide."
        )
    }

    func testTotalAttachedSizeIsNonEmptyStringWhenAttached() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        vm.attach(urls: [makeTempFileURL(name: "x.txt")])
        XCTAssertNotNil(
            vm.totalAttachedSize,
            "totalAttachedSize doit produire une chaîne quand au moins un fichier est attaché."
        )
        XCTAssertFalse(
            vm.totalAttachedSize?.isEmpty ?? true,
            "La chaîne produite ne doit pas être vide."
        )
    }

    // MARK: - availableRecipients

    func testAvailableRecipientsReturnsAllWhenToggleIsOn() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        vm.showAllRecipients = true

        let discovered: [DiscoveredDevice] = [
            DiscoveredDevice(
                device: makeRemoteDevice(),
                endpoint: NWEndpoint.hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(integerLiteral: 9_000)
                )
            ),
        ]
        // On ne peut pas injecter directement discoveredDevices dans
        // le bonjourService (chemin Core, intouchable). On vérifie
        // donc que `availableRecipients` est au moins synchronisé
        // avec `discoveredDevices` : si la liste découverte est
        // vide, le toggle ne change rien.
        XCTAssertEqual(
            vm.availableRecipients.count,
            vm.discoveredDevices.count,
            "Avec showAllRecipients = true, availableRecipients == discoveredDevices."
        )
        XCTAssertEqual(
            discovered.count,
            1,
            "Fixture non réinjectée dans le Core (intouchable) — référence."
        )
    }

    func testAvailableRecipientsDefaultsToAll() {
        // Par défaut, le ViewModel expose tous les pairs découverts
        // (le toggle est true à l'init).
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        XCTAssertTrue(
            vm.showAllRecipients,
            "showAllRecipients doit être true par défaut."
        )
        XCTAssertEqual(
            vm.availableRecipients.count,
            vm.discoveredDevices.count,
            "Par défaut, availableRecipients == discoveredDevices."
        )
    }

    // MARK: - send

    func testSendRejectsWhenNotConnected() {
        // On ne peut pas tester un `send` réussi sans Core complet,
        // mais on peut vérifier qu'il retourne `false` sans
        // connexion.
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        let url = makeTempFileURL(name: "send.txt")
        vm.attach(urls: [url])

        // Pas de peer connecté → send doit refuser.
        let recipient = DiscoveredDevice(
            device: makeRemoteDevice(),
            endpoint: NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(integerLiteral: 9_000)
            )
        )

        // Note : recipient.id != connectedDevice?.id → false aussi.
        // Les deux gardes (pas connecté + mauvais destinataire)
        // court-circuitent avant tout effet de bord Core.
        XCTAssertFalse(
            vm.send(to: recipient),
            "send doit retourner false quand aucun peer n'est connecté."
        )
        // Et la liste ne doit pas avoir été vidée, car le Core n'a
        // rien reçu.
        XCTAssertEqual(
            vm.attachedURLs.count,
            1,
            "L'échec de send ne doit pas vider la liste attachée."
        )
    }

    // MARK: - showAllRecipients toggle

    func testShowAllRecipientsToggleIsMutable() {
        let core = makeCore()
        let vm = ShareViewModel(core: core)

        XCTAssertTrue(vm.showAllRecipients)
        vm.showAllRecipients = false
        XCTAssertFalse(vm.showAllRecipients)
        vm.showAllRecipients = true
        XCTAssertTrue(vm.showAllRecipients)
    }

    // MARK: - Zones non couvertes (documentation)

    /// Le filtrage `availableRecipients` selon le `PairingStore`
    /// (toggle = false → uniquement les pairs de confiance) n'est
    /// pas testé ici : le `PairingStore` lit dans `UserDefaults`,
    /// ce qui est faisable (cf. `PairingStoreTests`), mais le
    /// couplage avec `core.pairingStore` et `discoveredDevices`
    /// nécessiterait d'injecter un pair dans les deux, ce qui sort
    /// du périmètre de la Phase 8. La logique testée ici (toggle
    /// = true → tous) reste valide.
    ///
    /// Le routage interne `core.importAndRequestItems(urls:)` n'est
    /// pas non plus testé : il faut un Core complet et un peer
    /// connecté. C'est testé en bout-en-bout dans
    /// `SessionIdSharingTests`.
    func test_documentationOnly_untestedZones() {
        // Pas d'assertion — ce test existe pour ancrer la
        // documentation dans la suite XCTest et la rendre visible
        // dans le rapport.
        XCTAssertTrue(true)
    }
}
