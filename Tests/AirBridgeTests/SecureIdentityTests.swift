import XCTest
import CryptoKit
@testable import AirBridge

final class SecureIdentityTests: XCTestCase {

    func testEnsureIdentityCreatesNewIdentity() throws {
        // Supprimer toute identité existante
        try? deleteTestIdentity()

        let identity = try SecureIdentityStore.ensureIdentity()

        XCTAssertFalse(identity.publicKeyData.isEmpty, "La clé publique ne doit pas être vide")
        XCTAssertEqual(identity.fingerprint.count, 32, "L'empreinte doit faire 32 caractères hex (16 octets)")

        // Vérifier qu'on peut recharger la même identité
        let reloaded = try SecureIdentityStore.loadIdentity()
        XCTAssertNotNil(reloaded, "L'identité doit être persistée")
        XCTAssertEqual(reloaded?.publicKeyData, identity.publicKeyData, "La clé publique doit être identique")
    }

    func testSigningAndVerification() throws {
        try? deleteTestIdentity()
        _ = try SecureIdentityStore.ensureIdentity()

        let dataToSign = "Hello, AirBridge!".data(using: .utf8)!

        let signature = try SecureIdentityStore.sign(dataToSign)
        let identity = try XCTUnwrap(SecureIdentityStore.loadIdentity())

        let valid = SecureIdentityStore.verifySignature(
            signature,
            for: dataToSign,
            publicKeyData: identity.publicKeyData
        )
        XCTAssertTrue(valid, "La signature doit être valide")

        // Modifier les données : la signature ne doit plus être valide
        let tamperedData = "Hello, tampered!".data(using: .utf8)!
        let invalid = SecureIdentityStore.verifySignature(
            signature,
            for: tamperedData,
            publicKeyData: identity.publicKeyData
        )
        XCTAssertFalse(invalid, "Une signature avec données différentes doit être invalide")
    }

    func testFingerprintIsConsistent() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let fp1 = SecureIdentityStore.computeFingerprint(data)
        let fp2 = SecureIdentityStore.computeFingerprint(data)
        XCTAssertEqual(fp1, fp2, "L'empreinte doit être déterministe")
        XCTAssertEqual(fp1.count, 32, "16 octets = 32 caractères hex")
    }

    func testGenerateChallengeIsRandom() {
        let c1 = PairingHandshake.generateChallenge()
        let c2 = PairingHandshake.generateChallenge()
        XCTAssertNotEqual(c1, c2, "Deux challenges successifs doivent être différents")
        XCTAssertEqual(c1.count, 32, "Le challenge doit faire 32 octets")
    }

    func testPrivateKeyIsNotInUserDefaults() throws {
        try? deleteTestIdentity()
        _ = try SecureIdentityStore.ensureIdentity()

        // Vérifier que UserDefaults ne contient PAS de clé privée
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in allKeys {
            if let data = UserDefaults.standard.data(forKey: key) {
                // Une clé privée P-256 brute fait 32 octets.
                // Si on en trouve une dans UserDefaults, c'est une fuite.
                if data.count == 32 {
                    XCTFail("Données de 32 octets trouvées dans UserDefaults (clé possible : \(key)) — violation de sécurité")
                }
            }
        }
    }

    // MARK: - Helpers

    private func deleteTestIdentity() throws {
        let service = "com.airbridge.identity"
        let account = "local-identity"
        let privateKeyTag = "com.airbridge.identity.privateKey"

        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(identityQuery as CFDictionary)

        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag
        ]
        SecItemDelete(keyQuery as CFDictionary)
    }
}