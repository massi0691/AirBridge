import XCTest
@testable import AirBridge

/// Tests du `ReplayProtectionStore` : protection anti-replay en mémoire.
///
/// Le store rejette les doublons `(peerID, messageID)` selon un TTL et une
/// capacité configurables. Ces tests vérifient l'API publique d'origine
/// (sans toucher au disque ni à la couche réseau).
final class ReplayProtectionStoreTests: XCTestCase {

    // MARK: - Cycle nominal

    func testNewMessageReturnsTrue() async {
        let store = ReplayProtectionStore()
        let peerID = UUID()
        let messageID = UUID()

        let accepted = await store.observe(peerID: peerID, messageID: messageID)
        XCTAssertTrue(accepted, "Un premier message doit être accepté")
    }

    func testDuplicateMessageReturnsFalse() async {
        let store = ReplayProtectionStore()
        let peerID = UUID()
        let messageID = UUID()

        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)

        XCTAssertTrue(first, "Le premier passage doit être accepté")
        XCTAssertFalse(second, "Le second passage du même message doit être détecté comme replay")
    }

    func testDifferentMessageIDsAreIndependent() async {
        let store = ReplayProtectionStore()
        let peerID = UUID()

        let first = await store.observe(peerID: peerID, messageID: UUID())
        let second = await store.observe(peerID: peerID, messageID: UUID())

        XCTAssertTrue(first)
        XCTAssertTrue(second, "Des messageIDs distincts du même pair ne sont pas des replays")
    }

    func testDifferentPeerIDsAreIndependent() async {
        let store = ReplayProtectionStore()
        let messageID = UUID()

        let first = await store.observe(peerID: UUID(), messageID: messageID)
        let second = await store.observe(peerID: UUID(), messageID: messageID)

        XCTAssertTrue(first)
        XCTAssertTrue(
            second,
            "Le même messageID provenant d'un autre pair n'est pas un replay"
        )
    }

    // MARK: - État observable

    func testCountReflectsEntries() async {
        let store = ReplayProtectionStore()
        let peerID = UUID()

        let initialCount = await store.count
        XCTAssertEqual(initialCount, 0, "Le store démarre vide")

        _ = await store.observe(peerID: peerID, messageID: UUID())
        let afterFirst = await store.count
        XCTAssertEqual(afterFirst, 1)

        _ = await store.observe(peerID: peerID, messageID: UUID())
        let afterSecond = await store.count
        XCTAssertEqual(afterSecond, 2)

        // Répéter le premier ne doit PAS augmenter le compteur.
        let sameID = UUID()
        _ = await store.observe(peerID: peerID, messageID: sameID)
        _ = await store.observe(peerID: peerID, messageID: sameID)
        let afterReplay = await store.count
        XCTAssertEqual(afterReplay, 3)
    }

    func testResetClearsStorage() async {
        let store = ReplayProtectionStore()
        let peerID = UUID()

        _ = await store.observe(peerID: peerID, messageID: UUID())
        _ = await store.observe(peerID: peerID, messageID: UUID())
        let beforeReset = await store.count
        XCTAssertEqual(beforeReset, 2)

        await store.reset()
        let afterReset = await store.count
        XCTAssertEqual(afterReset, 0, "reset() doit vider le store")

        // Après reset, le même message peut être vu à nouveau.
        let messageID = UUID()
        let first = await store.observe(peerID: peerID, messageID: messageID)
        let second = await store.observe(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)
        XCTAssertFalse(
            second,
            "Après reset, la première observation est acceptée et la seconde rejetée"
        )
    }

    // MARK: - TTL et capacité

    func testCapacityLimitEvictsOldest() async {
        // Capacité 2 : l'ajout d'un troisième message doit évincer le plus ancien.
        let store = ReplayProtectionStore(maxEntries: 2)
        let peerID = UUID()

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        _ = await store.observe(peerID: peerID, messageID: id1)
        _ = await store.observe(peerID: peerID, messageID: id2)
        _ = await store.observe(peerID: peerID, messageID: id3)

        let count = await store.count
        XCTAssertEqual(count, 2, "Le store ne doit pas dépasser la capacité maximale")

        // id3 doit être présent (tout juste inséré).
        let id3Seen = await store.observe(peerID: peerID, messageID: id3)
        XCTAssertFalse(id3Seen, "id3 vient d'être inséré : deuxième passage = replay")

        // id1 a été évincé et redevient « nouveau ».
        let id1Seen = await store.observe(peerID: peerID, messageID: id1)
        XCTAssertTrue(
            id1Seen,
            "L'entrée la plus ancienne doit avoir été évincée"
        )
    }

    func testCleanupRemovesExpiredEntries() async throws {
        // TTL très court : 0.1s, pour observer l'expiration sans ralentir
        // excessivement la suite de tests.
        let store = ReplayProtectionStore(ttl: 0.1, maxEntries: 100)
        let peerID = UUID()
        let messageID = UUID()

        _ = await store.observe(peerID: peerID, messageID: messageID)
        let beforeCleanup = await store.count
        XCTAssertEqual(beforeCleanup, 1)

        // On attend que l'entrée dépasse le TTL.
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        await store.cleanup()

        let afterCleanup = await store.count
        XCTAssertEqual(
            afterCleanup,
            0,
            "cleanup() doit retirer les entrées expirées"
        )
    }

    func testExpiredEntryIsReaccepted() async throws {
        // Après expiration, observer le même message doit à nouveau
        // retourner `true` : c'est le principe de la fenêtre glissante.
        let store = ReplayProtectionStore(ttl: 0.1, maxEntries: 100)
        let peerID = UUID()
        let messageID = UUID()

        let first = await store.observe(peerID: peerID, messageID: messageID)
        XCTAssertTrue(first)

        let second = await store.observe(peerID: peerID, messageID: messageID)
        XCTAssertFalse(second, "Dans la fenêtre TTL, le doublon est rejeté")

        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        let third = await store.observe(peerID: peerID, messageID: messageID)
        XCTAssertTrue(
            third,
            "Après expiration, le même message peut être ré-accepté"
        )
    }
}
