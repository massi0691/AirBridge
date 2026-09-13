//
//  ChunkStreamCipherTests.swift
//  AirBridgeTests
//
//  Tests de sécurité pour ChunkStreamCipher (ChaCha20-Poly1305).
//
//  Le chiffrement de flux des chunks binaires est opt-in : tant qu'aucune
//  clé n'est installée via `init(key:)`, le codec reste en mode transparent
//  (le chunk passe en clair). Avec une clé, ChaCha20-Poly1305 est appliqué
//  en flux :
//   * nonce (12 octets) dérivé de `chunkIndex + sessionId` ;
//   * AAD (additional authenticated data) = `transferID || chunkIndex || sessionId`
//     qui lie le chunk à son transfert et à sa session.
//
//  Les tests suivants vérifient que :
//   - un round-trip chiffrement / déchiffrement restitue l'original ;
//   - toute modification (clé, sessionId, transferID, chunkIndex, ciphertext)
//     fait échouer l'authentification Poly1305 ;
//   - le mode transparent est strictement no-op (idempotent) ;
//   - le nonce est déterministe (reproductible) ;
//   - le chiffrement fonctionne à l'échelle (4 MB).
//

import XCTest
import CryptoKit
@testable import AirBridge

final class ChunkStreamCipherTests: XCTestCase {

    // MARK: - Round-trip

    /// Cas nominal : avec une clé installée, chiffrer 4 KB de données puis
    /// déchiffrer doit restituer exactement le plaintext d'origine.
    func testEncryptDecryptRoundtrip() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionId = UUID()
        let plaintext = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })

        let sealed = cipher.encrypt(
            plaintext,
            transferID: transferID,
            chunkIndex: 7,
            sessionId: sessionId
        )
        XCTAssertNotNil(sealed, "encrypt ne doit pas échouer")
        XCTAssertNotEqual(sealed, plaintext, "le ciphertext doit différer du plaintext")

        let decrypted = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 7,
            sessionId: sessionId
        )
        XCTAssertNotNil(decrypted, "le déchiffrement doit réussir")
        XCTAssertEqual(decrypted, plaintext, "le plaintext déchiffré doit être identique")
    }

    // MARK: - Échecs d'authentification

    /// Avec une clé différente, le tag Poly1305 doit être invalide : le
    /// déchiffrement retourne `nil` (chunk corrompu, déplacé ou rejoué).
    func testDecryptFailsWithWrongKey() {
        let keyA = SymmetricKey(size: .bits256)
        let keyB = SymmetricKey(size: .bits256)
        let encrypter = ChunkStreamCipher(key: keyA)
        let decrypter = ChunkStreamCipher(key: keyB)

        let plaintext = Data("secret payload".utf8)
        let sealed = encrypter.encrypt(
            plaintext,
            transferID: UUID(),
            chunkIndex: 0,
            sessionId: UUID()
        )

        let result = decrypter.decrypt(
            sealed,
            transferID: UUID(),
            chunkIndex: 0,
            sessionId: UUID()
        )
        XCTAssertNil(result, "Une clé différente doit invalider le tag Poly1305")
    }

    /// Un octet modifié dans le ciphertext doit faire échouer la
    /// vérification du tag d'authentification.
    func testDecryptFailsWithTamperedCiphertext() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionId = UUID()
        var sealed = cipher.encrypt(
            Data(repeating: 0xCC, count: 1024),
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )

        // Flipper un octet au milieu du ciphertext (après le nonce de 12 octets).
        let tamperIndex = ChunkStreamCipher.nonceSize + 5
        sealed[tamperIndex] ^= 0xFF

        let result = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )
        XCTAssertNil(result, "Un octet du ciphertext modifié doit invalider le tag")
    }

    /// Un chunk d'une session A déchiffré avec la sessionId B en AAD doit
    /// être rejeté : la session est liée au tag.
    func testDecryptFailsWithWrongSessionId() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let sessionA = UUID()
        let sessionB = UUID()
        let transferID = UUID()

        let sealed = cipher.encrypt(
            Data(repeating: 0x42, count: 256),
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionA
        )

        let result = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionB
        )
        XCTAssertNil(result, "Un sessionId différent en AAD doit invalider le tag")
    }

    /// Un chunk déplacé d'un autre transfert (transferID différent en AAD)
    /// doit être rejeté.
    func testDecryptFailsWithWrongTransferID() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let sessionId = UUID()
        let transferA = UUID()
        let transferB = UUID()

        let sealed = cipher.encrypt(
            Data(repeating: 0x99, count: 256),
            transferID: transferA,
            chunkIndex: 0,
            sessionId: sessionId
        )

        let result = cipher.decrypt(
            sealed,
            transferID: transferB,
            chunkIndex: 0,
            sessionId: sessionId
        )
        XCTAssertNil(result, "Un transferID différent en AAD doit invalider le tag")
    }

    /// Un chunk dont le chunkIndex ne correspond pas à celui utilisé pour
    /// le chiffrement doit être rejeté (l'index est dans l'AAD).
    func testDecryptFailsWithWrongChunkIndex() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionId = UUID()

        let sealed = cipher.encrypt(
            Data(repeating: 0x55, count: 256),
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )

        let result = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 1,
            sessionId: sessionId
        )
        XCTAssertNil(result, "Un chunkIndex différent en AAD doit invalider le tag")
    }

    // MARK: - Mode transparent

    /// Sans clé installée, le codec doit fonctionner en mode transparent :
    /// `encrypt` retourne le plaintext tel quel, et `decrypt` le restitue
    /// inchangé. Aucune erreur ne doit survenir.
    func testTransparentModeWhenNoKey() {
        let cipher = ChunkStreamCipher() // pas de clé
        XCTAssertFalse(cipher.hasKey, "hasKey doit être false en mode transparent")

        let plaintext = Data("plain chunk, no encryption".utf8)
        let transferID = UUID()
        let sessionId = UUID()

        let sealed = cipher.encrypt(
            plaintext,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )
        XCTAssertEqual(
            sealed, plaintext,
            "En mode transparent, encrypt doit retourner le plaintext inchangé"
        )

        let result = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )
        XCTAssertEqual(
            result, plaintext,
            "En mode transparent, decrypt doit restituer le plaintext inchangé"
        )
    }

    // MARK: - Déterminisme du nonce

    /// Le nonce doit être strictement déterministe : pour les mêmes
    /// paramètres (transferID, chunkIndex), deux appels à `encrypt`
    /// produisent des ciphertexts identiques (y compris le nonce). Cela
    /// permet la détection de rejeu au niveau supérieur (le récepteur
    /// observant qu'un (transferID, chunkIndex) déjà vu est ré-émis).
    ///
    /// Ce déterminisme est SÛR car le `transferID` fait désormais partie
    /// de la dérivation du nonce (cf. [CRITIQUE-1]) : deux transferts
    /// distincts produisent des nonces distincts, donc des ciphertexts
    /// distincts, même pour le même `chunkIndex`. Le déterminisme
    /// observé ici n'est qu'au sein d'un même transfert — la
    /// réutilisation de nonce cross-transferts, qui violait RFC 7539,
    /// est testée dans `testNonceUniquenessAcrossTransfers`.
    func testNonceDeterministic() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionId = UUID()
        let plaintext = Data(repeating: 0xAB, count: 512)
        let chunkIndex: UInt32 = 42

        let sealed1 = cipher.encrypt(
            plaintext,
            transferID: transferID,
            chunkIndex: chunkIndex,
            sessionId: sessionId
        )
        let sealed2 = cipher.encrypt(
            plaintext,
            transferID: transferID,
            chunkIndex: chunkIndex,
            sessionId: sessionId
        )
        XCTAssertEqual(
            sealed1, sealed2,
            "Deux chiffrements avec les mêmes paramètres doivent produire le même ciphertext"
        )

        // Les 12 premiers octets (nonce) doivent être identiques entre les
        // deux appels — c'est ce qu'on entend ici par « déterministe ».
        XCTAssertEqual(
            sealed1.prefix(ChunkStreamCipher.nonceSize),
            sealed2.prefix(ChunkStreamCipher.nonceSize)
        )
    }

    // MARK: - Non-régression CRITIQUE-1 : unicité du nonce cross-transferts

    /// Deux transferts A et B dans la même session, démarrant tous
    /// deux à `chunkIndex = 0`, doivent produire des ciphertexts
    /// DIFFÉRENTS.
    ///
    /// Ce test de non-régression protège contre la réintroduction du
    /// bug [CRITIQUE-1] identifié en revue Phase 2 : avant le
    /// correctif, le nonce était dérivé uniquement de
    /// `sessionId || chunkIndex`, ce qui produisait le même nonce pour
    /// les premiers chunks de deux transferts concurrents dans la
    /// même session — violation RFC 7539 (two-time pad attack) qui
    /// compromet la confidentialité du chiffrement de flux.
    ///
    /// Le correctif intègre le `transferID` dans la dérivation du
    /// nonce : un même `(transferID, chunkIndex)` produit toujours le
    /// même nonce, mais deux `transferID` distincts produisent des
    /// nonces distincts même avec un `chunkIndex` identique.
    func testNonceUniquenessAcrossTransfers() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        let session = UUID()
        let transferA = UUID()
        let transferB = UUID()
        let plaintext = Data(repeating: 0x42, count: 256)

        let ctA = cipher.encrypt(
            plaintext,
            transferID: transferA,
            chunkIndex: 0,
            sessionId: session
        )
        let ctB = cipher.encrypt(
            plaintext,
            transferID: transferB,
            chunkIndex: 0,
            sessionId: session
        )

        XCTAssertNotEqual(
            ctA, ctB,
            "Nonce reuse critique : deux transferts différents dans la même session doivent produire des ciphertexts différents"
        )

        // Vérification plus fine : les nonces (12 premiers octets) doivent
        // différer. C'est la signature cryptographique du bug : deux
        // ciphertexts peuvent diverger par hasard sur le tag, mais des
        // nonces identiques impliquent une violation RFC 7539.
        XCTAssertNotEqual(
            ctA.prefix(ChunkStreamCipher.nonceSize),
            ctB.prefix(ChunkStreamCipher.nonceSize),
            "Les nonces doivent être distincts entre deux transferts concurrents"
        )
    }

    // MARK: - Échelle (4 MB)

    /// Le chiffrement doit fonctionner à l'échelle d'un chunk réaliste de
    /// plusieurs MB. Vérifie que le ciphertext est différent du plaintext
    /// et que le round-trip restitue l'original.
    func testLargePayload() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let plaintext = Data((0..<(4 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        XCTAssertEqual(plaintext.count, 4 * 1024 * 1024)

        let transferID = UUID()
        let sessionId = UUID()
        let sealed = cipher.encrypt(
            plaintext,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )
        // Format : nonce(12) + ciphertext(N) + tag(16).
        XCTAssertEqual(
            sealed.count,
            ChunkStreamCipher.nonceSize + plaintext.count + ChunkStreamCipher.tagSize
        )

        let decrypted = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )
        XCTAssertNotNil(decrypted)
        XCTAssertEqual(decrypted, plaintext, "Le round-trip 4 MB doit être exact")
    }

    // MARK: - hasKey

    /// `hasKey` doit refléter l'état de la clé : false par défaut, true
    /// après construction avec une clé.
    func testHasKeyReflectsInstallState() {
        let noKey = ChunkStreamCipher()
        XCTAssertFalse(noKey.hasKey, "hasKey doit être false sans clé")

        let withKey = ChunkStreamCipher(key: SymmetricKey(size: .bits256))
        XCTAssertTrue(withKey.hasKey, "hasKey doit être true avec une clé")
    }
}
