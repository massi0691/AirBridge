import XCTest
import CryptoKit
@testable import AirBridge

final class PairingStoreTests: XCTestCase {

    private var store: PairingStore!

    override func setUp() {
        super.setUp()
        store = PairingStore()
        clearUserDefaults()
    }

    override func tearDown() {
        clearUserDefaults()
        store = nil
        super.tearDown()
    }

    func testInitialStateIsUnknown() {
        let peerID = UUID()
        let state = store.trustState(for: peerID)
        XCTAssertEqual(state, .unknown, "Un pair jamais vu doit être inconnu")
    }

    func testRecordPairingCreatesPendingEntry() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()
        let peerPublicKeyData = peerKey.publicKey.x963Representation

        let result = store.recordPairing(
            peerID: peerID,
            peerName: "Mac de Test",
            peerPublicKeyData: peerPublicKeyData,
            localIdentity: identity
        )

        let info = extractPairingInfo(result)
        XCTAssertEqual(info.peerID, peerID)
        XCTAssertEqual(info.peerName, "Mac de Test")
        XCTAssertEqual(info.trustState, .pending, "Un nouveau pairage doit être en attente")
        XCTAssertEqual(info.peerPublicKeyData, peerPublicKeyData)

        let reloaded = store.pairing(for: peerID)
        XCTAssertNotNil(reloaded, "Le pairage doit être persisté")
    }

    func testSetTrustStateToTrusted() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()
        _ = store.recordPairing(
            peerID: peerID,
            peerName: "Test",
            peerPublicKeyData: peerKey.publicKey.x963Representation,
            localIdentity: identity
        )

        let updated = store.setTrustState(.trusted, for: peerID)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.trustState, .trusted)
        XCTAssertNotNil(updated?.verifiedAt)
        XCTAssertTrue(store.isTrusted(peerID), "Le pair doit être marqué comme de confiance")
    }

    func testSetTrustStateToBlocked() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()
        _ = store.recordPairing(
            peerID: peerID,
            peerName: "Test",
            peerPublicKeyData: peerKey.publicKey.x963Representation,
            localIdentity: identity
        )

        _ = store.setTrustState(.blocked, for: peerID)
        XCTAssertTrue(store.isBlocked(peerID), "Le pair doit être bloqué")
    }

    func testRemovePairing() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()
        _ = store.recordPairing(
            peerID: peerID,
            peerName: "Test",
            peerPublicKeyData: peerKey.publicKey.x963Representation,
            localIdentity: identity
        )

        XCTAssertNotNil(store.pairing(for: peerID))
        store.removePairing(for: peerID)
        XCTAssertNil(store.pairing(for: peerID))
        XCTAssertEqual(store.trustState(for: peerID), .unknown, "Après suppression, l'état doit être inconnu")
    }

    func testVerifyPeerIdentity() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()
        let correctKey = peerKey.publicKey.x963Representation
        _ = store.recordPairing(
            peerID: peerID,
            peerName: "Test",
            peerPublicKeyData: correctKey,
            localIdentity: identity
        )

        XCTAssertTrue(store.verifyPeerIdentity(peerID: peerID, publicKeyData: correctKey))

        let wrongKey = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertFalse(store.verifyPeerIdentity(peerID: peerID, publicKeyData: wrongKey), "Une clé différente doit être détectée")
    }

    // MARK: - Helpers

    /// Extrait la `PairingInfo` du résultat d'enregistrement, quel que
    /// soit le cas (création, mise à jour, ou changement de clé).
    private func extractPairingInfo(
        _ result: PairingUpdateResult
    ) -> PairingInfo {
        switch result {
        case .created(let info), .updated(let info),
             .keyChanged(let info), .keyChangedDowngraded(let info):
            return info
        }
    }

    private func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "airbridge.pairings.v1")
    }
}
