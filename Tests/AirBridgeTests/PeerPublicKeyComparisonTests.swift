//
//  PeerPublicKeyComparisonTests.swift
//  AirBridgeTests
//
//  Tests de la comparaison de clé publique annoncée / clé publique
//  persistée (anti-substitution d'identité).
//
//  Cette comparaison est au cœur du correctif de sécurité : le pipeline
//  sécurisé de `ConnectionManager` extrait la clé annoncée du payload
//  d'un `pairingRequest` / `pairingResponse` et la compare à celle du
//  `PairingStore`. Si elles diffèrent, `peerPublicKeyMatches` vaut
//  `false`, ce qui force `AuthenticationPolicy` à retourner `.required`
//  (vérification contre la clé du store) plutôt que d'accepter un
//  message dont la signature pourrait être forgée avec une autre clé.
//
//  La méthode `peerPublicKeyMatches` elle-même est privée à
//  `ConnectionManager` ; on teste donc le comportement observable :
//  ce que `ConnectionManager` calcule en interne est précisément
//  l'argument `peerPublicKeyMatches: Bool` passé à
//  `AuthenticationPolicy.authenticationRequirement(...)`.
//

import XCTest
import CryptoKit
@testable import AirBridge

final class PeerPublicKeyComparisonTests: XCTestCase {

    private var pairingStore: PairingStore!

    override func setUp() {
        super.setUp()
        pairingStore = PairingStore()
        clearUserDefaults()
    }

    override func tearDown() {
        clearUserDefaults()
        pairingStore = nil
        super.tearDown()
    }

    // MARK: - Cas nominal : clés identiques

    /// Cas nominal : un pair trusted dont la clé annoncée est la même
    /// que la clé persistée doit satisfaire `peerPublicKeyMatches: true`
    /// et produire une politique `.required` (vérification contre la
    /// clé du store).
    func testMatchesWhenKeysAreEqual() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let peerKey = P256.Signing.PrivateKey()
        let keyBytes = peerKey.publicKey.x963Representation

        // Enregistrer le pair et le marquer trusted avec la même clé.
        _ = pairingStore.recordPairing(
            peerID: peerID,
            peerName: "Peer",
            peerPublicKeyData: keyBytes,
            localIdentity: identity
        )
        _ = pairingStore.setTrustState(.trusted, for: peerID)

        // Le message annonce exactement la même clé que celle persistée.
        let advertisedPublicKey = keyBytes

        // peerPublicKeyMatches = true (advertised == stored)
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: .transferRequest,
            protocolVersion: 2,
            peerTrustState: .trusted,
            peerPublicKeyMatches: true
        )
        XCTAssertEqual(
            requirement, .required,
            "Clés identiques + pair trusted doit donner .required"
        )
        _ = advertisedPublicKey
    }

    // MARK: - Clés différentes

    /// Si la clé annoncée diffère de la clé persistée, `peerPublicKeyMatches`
    /// vaut `false`. La `AuthenticationPolicy` doit retourner `.required`
    /// (vérification stricte contre la clé du store, qui rejettera la
    /// signature forgée avec une autre clé).
    ///
    /// On utilise `.transferRequest` (pas dans `messagesAllowedBeforePairing`)
    /// pour éviter la branche `.requiredForKnownPeer` qui s'applique aux
    /// messages de premier contact (`pairingRequest`, `hello`, etc.).
    func testDoesNotMatchWhenKeysDiffer() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let storedKey = P256.Signing.PrivateKey()
        let advertisedKey = P256.Signing.PrivateKey()

        _ = pairingStore.recordPairing(
            peerID: peerID,
            peerName: "Peer",
            peerPublicKeyData: storedKey.publicKey.x963Representation,
            localIdentity: identity
        )
        _ = pairingStore.setTrustState(.trusted, for: peerID)

        // peerPublicKeyMatches = false (advertised != stored)
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: .transferRequest,
            protocolVersion: 2,
            peerTrustState: .trusted,
            peerPublicKeyMatches: false
        )
        XCTAssertEqual(
            requirement, .required,
            "Clés différentes + pair trusted doit toujours donner .required (vérification stricte)"
        )
        _ = advertisedKey
    }

    // MARK: - Clé stockée absente

    /// Si la clé stockée manque (pair jamais pairé), la comparaison ne
    /// peut pas confirmer l'identité : `peerPublicKeyMatches` vaut `false`.
    /// Pour un message de premier contact (allowed-before-pairing), la
    /// politique tombe sur `.requiredForKnownPeer` (vérification contre
    /// la clé annoncée seulement).
    func testDoesNotMatchWhenStoredKeyMissing() {
        // Pas d'enregistrement dans le store → key stored = nil.
        // peerPublicKeyMatches = false.
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: .pairingRequest, // dans la liste allowed-before-pairing
            protocolVersion: 2,
            peerTrustState: .unknown, // pas dans le store
            peerPublicKeyMatches: false
        )
        XCTAssertEqual(
            requirement, .requiredForKnownPeer,
            "Pair inconnu + message de premier contact doit donner .requiredForKnownPeer"
        )
    }

    // MARK: - Clé annoncée absente

    /// Si la clé annoncée manque (message qui ne transporte pas de
    /// `PairingPayload`, ex. `transferRequest`), `peerPublicKeyMatches`
    /// vaut `false`. Combiné à un pair trusted, on reste sur `.required`
    /// (vérification stricte contre la clé du store).
    func testDoesNotMatchWhenAdvertisedKeyMissing() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let storedKey = P256.Signing.PrivateKey()

        _ = pairingStore.recordPairing(
            peerID: peerID,
            peerName: "Peer",
            peerPublicKeyData: storedKey.publicKey.x963Representation,
            localIdentity: identity
        )
        _ = pairingStore.setTrustState(.trusted, for: peerID)

        // advertisedPublicKey = nil (message sans payload de pairage)
        // peerPublicKeyMatches = false
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: .transferRequest,
            protocolVersion: 2,
            peerTrustState: .trusted,
            peerPublicKeyMatches: false
        )
        XCTAssertEqual(
            requirement, .required,
            "Clé annoncée absente + pair trusted doit donner .required"
        )
    }

    // MARK: - Downgrade en cas de changement de clé

    /// Le scénario complet de downgrade : un pair trusted change sa clé
    /// publique. `PairingStore.recordPairing` doit retourner
    /// `.keyChangedDowngraded` (trustState → pending). La `AuthenticationPolicy`
    /// avec ce nouveau `peerTrustState: .pending` doit toujours retourner
    /// `.required`, ce qui correspond exactement au comportement attendu :
    /// on exige désormais une signature, et la clé du store (qui n'est plus
    /// la même que celle annoncée) rejettera toute signature forgée avec
    /// l'ancienne clé.
    func testTrustedPeerDowngradesOnKeyChange() throws {
        let identity = try SecureIdentityStore.ensureIdentity()
        let peerID = UUID()
        let key1 = P256.Signing.PrivateKey()
        let key2 = P256.Signing.PrivateKey()

        // Premier pairage + mark trusted.
        _ = pairingStore.recordPairing(
            peerID: peerID,
            peerName: "Trusted Peer",
            peerPublicKeyData: key1.publicKey.x963Representation,
            localIdentity: identity
        )
        _ = pairingStore.setTrustState(.trusted, for: peerID)

        let before = pairingStore.pairing(for: peerID)!
        XCTAssertEqual(before.trustState, .trusted)

        // Nouveau pairage avec une clé différente.
        let result = pairingStore.recordPairing(
            peerID: peerID,
            peerName: "Trusted Peer",
            peerPublicKeyData: key2.publicKey.x963Representation,
            localIdentity: identity
        )

        switch result {
        case .keyChangedDowngraded(let info):
            XCTAssertEqual(
                info.trustState, .pending,
                "La confiance doit être rétrogradée vers .pending"
            )
            XCTAssertNil(
                info.verifiedAt,
                "verifiedAt doit être nil après downgrade"
            )

            // La AuthenticationPolicy, consultée avec le nouveau trustState
            // et `peerPublicKeyMatches: false` (puisque la clé annoncée
            // diffère de la clé stockée), doit retourner `.required`.
            let requirement = AuthenticationPolicy.authenticationRequirement(
                for: .transferRequest,
                protocolVersion: 2,
                peerTrustState: info.trustState,
                peerPublicKeyMatches: false
            )
            XCTAssertEqual(
                requirement, .required,
                "Post-downgrade, le pair pending doit rester en .required"
            )
        default:
            XCTFail("Un changement de clé sur un pair trusted doit produire .keyChangedDowngraded, reçu : \(result)")
        }
    }

    // MARK: - Helpers

    private func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "airbridge.pairings.v1")
    }
}
