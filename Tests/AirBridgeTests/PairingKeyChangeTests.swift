import XCTest
import CryptoKit
@testable import AirBridge

/// Tests pour la détection de changement de clé publique dans `PairingStore`.
///
/// Ces tests vérifient que:
/// 1. Un changement de clé sur un pair `pending` → `keyChanged` (trustState inchangé)
/// 2. Un changement de clé sur un pair `trusted` → `keyChangedDowngraded` (trustState → pending)
/// 3. Un changement de clé sur un pair `blocked` → `keyChanged` (trustState inchangé)
/// 4. Une mise à jour avec la même clé → `updated`
/// 5. Un nouveau pairage → `created`
final class PairingKeyChangeTests: XCTestCase {

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

    // MARK: - Changement de clé sur différents états de confiance

    func testKeyChangeOnPendingPeer() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey1 = P256.Signing.PrivateKey()
        let peerKey2 = P256.Signing.PrivateKey()

        // Premier pairage avec clé 1
        let result1 = store.recordPairing(
            peerID: peerID,
            peerName: "Test",
            peerPublicKeyData: peerKey1.publicKey.x963Representation,
            localIdentity: identity
        )

        let info1 = extractPairingInfo(result1)
        XCTAssertEqual(info1.trustState, .pending)

        // Deuxième enregistrement avec une clé différente
        let result2 = store.recordPairing(
            peerID: peerID,
            peerName: "Test",
            peerPublicKeyData: peerKey2.publicKey.x963Representation,
            localIdentity: identity
        )

        switch result2 {
        case .keyChanged(let info):
            XCTAssertEqual(info.peerPublicKeyData, peerKey2.publicKey.x963Representation)
            XCTAssertEqual(info.trustState, .pending, "Un pair pending garde son état après keyChanged")
        case .keyChangedDowngraded:
            XCTFail("Un pair pending ne doit pas être downgraded")
        default:
            XCTFail("Un changement de clé sur pending doit retourner .keyChanged, reçu : \(result2)")
        }
    }

    func testKeyChangeOnTrustedPeer() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey1 = P256.Signing.PrivateKey()
        let peerKey2 = P256.Signing.PrivateKey()

        // Créer et marquer comme trusted
        let result1 = store.recordPairing(
            peerID: peerID,
            peerName: "Trusted Peer",
            peerPublicKeyData: peerKey1.publicKey.x963Representation,
            localIdentity: identity
        )
        let info1 = extractPairingInfo(result1)
        XCTAssertEqual(info1.trustState, .pending)

        _ = store.setTrustState(.trusted, for: peerID)
        let trustedInfo = store.pairing(for: peerID)!
        XCTAssertEqual(trustedInfo.trustState, .trusted)

        // Enregistrer avec une nouvelle clé : doit downgrader vers pending
        let result2 = store.recordPairing(
            peerID: peerID,
            peerName: "Trusted Peer",
            peerPublicKeyData: peerKey2.publicKey.x963Representation,
            localIdentity: identity
        )

        switch result2 {
        case .keyChangedDowngraded(let info):
            XCTAssertEqual(info.peerPublicKeyData, peerKey2.publicKey.x963Representation)
            XCTAssertEqual(info.trustState, .pending, "Un pair trusted doit être downgraded vers pending")
            XCTAssertNil(info.verifiedAt, "verifiedAt doit être nil après downgrade")
        case .keyChanged:
            XCTFail("Un pair trusted avec nouvelle clé doit retourner .keyChangedDowngraded")
        default:
            XCTFail("Un changement de clé sur trusted doit retourner .keyChangedDowngraded, reçu : \(result2)")
        }
    }

    func testKeyChangeOnBlockedPeer() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey1 = P256.Signing.PrivateKey()
        let peerKey2 = P256.Signing.PrivateKey()

        // Créer et bloquer
        _ = store.recordPairing(
            peerID: peerID,
            peerName: "Blocked Peer",
            peerPublicKeyData: peerKey1.publicKey.x963Representation,
            localIdentity: identity
        )
        _ = store.setTrustState(.blocked, for: peerID)
        let blockedInfo = store.pairing(for: peerID)!
        XCTAssertEqual(blockedInfo.trustState, .blocked)

        // Enregistrer avec une nouvelle clé : keyChanged, trustState reste blocked
        let result2 = store.recordPairing(
            peerID: peerID,
            peerName: "Blocked Peer",
            peerPublicKeyData: peerKey2.publicKey.x963Representation,
            localIdentity: identity
        )

        switch result2 {
        case .keyChanged(let info):
            XCTAssertEqual(info.peerPublicKeyData, peerKey2.publicKey.x963Representation)
            XCTAssertEqual(info.trustState, .blocked, "Un pair blocked garde son état")
        case .keyChangedDowngraded:
            XCTFail("Un pair blocked ne doit pas être downgraded")
        default:
            XCTFail("Un changement de clé sur blocked doit retourner .keyChanged, reçu : \(result2)")
        }
    }

    func testSameKeyReturnsUpdated() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()

        _ = store.recordPairing(
            peerID: peerID,
            peerName: "Test",
            peerPublicKeyData: peerKey.publicKey.x963Representation,
            localIdentity: identity
        )

        // Deuxième enregistrement avec la MÊME clé
        let result2 = store.recordPairing(
            peerID: peerID,
            peerName: "Test Updated",
            peerPublicKeyData: peerKey.publicKey.x963Representation,
            localIdentity: identity
        )

        switch result2 {
        case .updated(let info):
            XCTAssertEqual(info.peerName, "Test Updated", "Le nom doit être mis à jour")
            XCTAssertEqual(info.peerPublicKeyData, peerKey.publicKey.x963Representation)
        default:
            XCTFail("Même clé doit retourner .updated, reçu : \(result2)")
        }
    }

    func testNewPairingReturnsCreated() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()

        let result = store.recordPairing(
            peerID: peerID,
            peerName: "New Peer",
            peerPublicKeyData: peerKey.publicKey.x963Representation,
            localIdentity: identity
        )

        switch result {
        case .created(let info):
            XCTAssertEqual(info.peerID, peerID)
            XCTAssertEqual(info.peerName, "New Peer")
            XCTAssertEqual(info.trustState, .pending)
        default:
            XCTFail("Nouveau pairage doit retourner .created, reçu : \(result)")
        }
    }

    // MARK: - Helpers

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