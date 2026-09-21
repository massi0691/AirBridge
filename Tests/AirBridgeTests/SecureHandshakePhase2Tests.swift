//
//  SecureHandshakePhase2Tests.swift
//  AirBridgeTests
//
//  Tests Phase 2 — intégration SecureHandshake (ECDH P-256 + HKDF-SHA256)
//  + intégrité SHA-256 bout-en-bout + rejet de cipher pair (replay croisé).
//
//  Couvre :
//   1. Débit ChaCha20-Poly1305 + encodage binaire v2 sur 100 MB
//      (régression : baseline pré-correctif = 5.43 MB/s, cible ≥ 22 MB/s).
//   2. Latence handshake ECDH P-256 + HKDF-SHA256 < 100 ms (moyenne sur 50 paires).
//   3. Intégrité SHA-256 sur données déchiffrées (round-trip 1 MB).
//   4. Rejet strict si transferID ou sessionId altéré → déchiffrement = nil.
//   5. Rejet strict entre deux paires de ciphers distincts (pas de collision).
//

import XCTest
import CryptoKit
@testable import AirBridge

final class SecureHandshakePhase2Tests: XCTestCase {

    // 100 MB — minimum pour la mesure de régression.
    private let hundredMB = 100 * 1024 * 1024
    // 1 MB pour SHA-256 (suffisant pour vérifier l'intégrité).
    private let oneMB = 1 * 1024 * 1024

    // MARK: - 1. Débit ChaCha20-Poly1305 + BinaryFileChunkPayload 100 MB

    /// Scénario de régression : reproduit le pipeline complet
    /// (chiffrement ChaCha20-Poly1305 + encodage binaire v2) sur 100 MB.
    ///
    /// Le baseline pré-correctif était de 5.43 MB/s. L'objectif Phase 2
    /// est ≥ 22 MB/s (4×) avec un stretch à 40 MB/s.
    ///
    /// IMPORTANT : on n'utilise pas `XCTMeasure` ici (qui impose un
    /// baseline/standard et un iterationCount ≥ 5). On utilise un
    /// chronométrage manuel pour avoir un débit en MB/s reproductible.
    func testPipelineThroughput100MB() throws {
        let totalBytes = hundredMB
        let chunkSize = 1 * 1024 * 1024
        let totalData = Data((0..<totalBytes).map { _ in UInt8.random(in: 0...255) })

        // Clé symétrique 256 bits, comme dérivée par SecureHandshake.deriveSessionKey.
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        XCTAssertTrue(cipher.hasKey)

        let transferID = UUID()
        let sessionId = UUID()

        // Réchauffement : un premier passage pour amorcer les caches CPU
        // et l'allocation mémoire avant la mesure.
        var warmOffset = 0
        var warmIndex: UInt32 = 0
        while warmOffset < totalData.count {
            let end = min(warmOffset + chunkSize, totalData.count)
            let slice = totalData.subdata(in: warmOffset..<end)
            let sealed = cipher.encrypt(
                slice,
                transferID: transferID,
                chunkIndex: warmIndex,
                sessionId: sessionId
            )
            // Encodage binaire v2 — on simule le pipeline complet.
            let chunk = BinaryFileChunkPayload(
                transferID: transferID,
                offset: Int64(warmOffset),
                data: sealed, // on encode le ciphertext, pas le plaintext
                isLastChunk: end == totalData.count,
                sessionId: sessionId
            )
            _ = chunk.encode()
            warmOffset = end
            warmIndex += 1
        }

        // Mesure chronométrée du pipeline complet.
        let start = Date()
        var offset: Int = 0
        var index: UInt32 = 0
        while offset < totalData.count {
            let end = min(offset + chunkSize, totalData.count)
            let slice = totalData.subdata(in: offset..<end)
            let sealed = cipher.encrypt(
                slice,
                transferID: transferID,
                chunkIndex: index,
                sessionId: sessionId
            )
            let chunk = BinaryFileChunkPayload(
                transferID: transferID,
                offset: Int64(offset),
                data: sealed,
                isLastChunk: end == totalData.count,
                sessionId: sessionId
            )
            _ = chunk.encode()
            offset = end
            index += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        let throughput = Double(totalBytes) / elapsed / (1024 * 1024)

        print("📊 [Phase 2] Pipeline encrypt + binary encode 100 MB : \(String(format: "%.2f", throughput)) MB/s (durée : \(String(format: "%.3f", elapsed)) s)")

        // Cible Phase 2 : ≥ 22 MB/s (4× baseline). Stretch à 40 MB/s.
        // On reste sur 22 MB/s pour ne pas bloquer les machines moins rapides.
        XCTAssertGreaterThanOrEqual(
            throughput, 22.0,
            "Débit pipeline 100 MB doit être ≥ 22 MB/s (baseline 5.43 MB/s × 4), mesuré : \(throughput) MB/s"
        )
    }

    // MARK: - 2. Latence handshake ECDH P-256 + HKDF-SHA256 < 100 ms

    /// Génère 50 paires de clés P-256, effectue pour chaque paire :
    ///   * génération des deux `P256.KeyAgreement.PrivateKey`,
    ///   * `sharedSecretFromKeyAgreement`,
    ///   * dérivation HKDF-SHA256 → `SymmetricKey` 256 bits.
    ///
    /// Mesure le temps total et la moyenne par handshake. Doit être
    /// < 100 ms en moyenne (objectif UX : handshake imperceptible).
    func testHandshakeLatencyP256() throws {
        let pairCount = 50
        let sessionId = UUID()

        var perPairTimesMs: [Double] = []

        for _ in 0..<pairCount {
            let alice = SecureHandshake()
            let bob = SecureHandshake()

            // Chronométrage du chemin complet : génération des deux clés
            // + dérivation de session des deux côtés. On utilise Date()
            // pour avoir une mesure simple en millisecondes ; la
            // résolution de ContinuousClock (nanos) n'apporte rien pour
            // un test d'UX dont la cible est la centaine de ms.
            let start = Date()

            // Alice dérive sa clé à partir de la clé publique de Bob
            // (et vice-versa, c'est symétrique en ECDH).
            let aliceKey = try alice.deriveSessionKey(
                from: bob.publicKeyData,
                sessionId: sessionId
            )
            let bobKey = try bob.deriveSessionKey(
                from: alice.publicKeyData,
                sessionId: sessionId
            )

            // Les deux clés doivent être identiques (secret partagé).
            let aliceRaw = aliceKey.withUnsafeBytes { Data($0) }
            let bobRaw = bobKey.withUnsafeBytes { Data($0) }
            XCTAssertEqual(
                aliceRaw, bobRaw,
                "Les deux extrémités d'un handshake ECDH doivent dériver la même clé symétrique"
            )

            let elapsedMs = Date().timeIntervalSince(start) * 1000.0
            perPairTimesMs.append(elapsedMs)
        }

        let avgMs = perPairTimesMs.reduce(0, +) / Double(perPairTimesMs.count)
        let maxMs = perPairTimesMs.max() ?? 0
        let minMs = perPairTimesMs.min() ?? 0

        print("📊 [Phase 2] Handshake ECDH P-256 + HKDF-SHA256 sur \(pairCount) paires : " +
              "avg=\(String(format: "%.2f", avgMs)) ms, " +
              "min=\(String(format: "%.2f", minMs)) ms, " +
              "max=\(String(format: "%.2f", maxMs)) ms")

        // Objectif : < 100 ms en moyenne par handshake.
        // On laisse une marge pour les machines virtuelles CI : 200 ms.
        XCTAssertLessThan(
            avgMs, 200.0,
            "Latence moyenne handshake ECDH + HKDF-SHA256 doit être < 200 ms (cible UX < 100 ms), mesurée : \(avgMs) ms"
        )
    }

    // MARK: - 3. Intégrité SHA-256 sur données déchiffrées

    /// Round-trip ChaCha20-Poly1305 sur 1 MB de données reproductibles.
    /// Le SHA-256 du plaintext d'origine doit être strictement égal au
    /// SHA-256 du plaintext déchiffré — c'est la garantie d'intégrité
    /// bout-en-bout au niveau du chiffrement de flux.
    func testSHA256IntegrityAfterEncryptDecrypt() throws {
        // Pattern reproductible : `UInt8(i % 256)` sur 1 MB.
        // Garantit une empreinte SHA-256 déterministe, indépendante de
        // l'allocateur.
        let plaintextSize = oneMB
        let plaintext = Data((0..<plaintextSize).map { i in UInt8(i % 256) })

        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionId = UUID()

        // 1. Empreinte de référence.
        let originalHash = SHA256.hash(data: plaintext)
        let originalHex = originalHash.map { String(format: "%02x", $0) }.joined()

        // 2. Chiffrement.
        let sealed = cipher.encrypt(
            plaintext,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        )
        XCTAssertFalse(
            sealed.isEmpty,
            "encrypt ne doit pas produire de ciphertext vide"
        )
        XCTAssertNotEqual(sealed, plaintext, "le ciphertext doit différer du plaintext")
        // Format : nonce(12) + ciphertext(N) + tag(16).
        XCTAssertEqual(
            sealed.count,
            ChunkStreamCipher.nonceSize + plaintext.count + ChunkStreamCipher.tagSize
        )

        // 3. Déchiffrement.
        guard let decrypted = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionId
        ) else {
            XCTFail("decrypt ne doit pas échouer pour des paramètres cohérents")
            return
        }
        XCTAssertEqual(decrypted.count, plaintext.count, "taille restaurée")

        // 4. Vérification d'intégrité : SHA-256(original) == SHA-256(decrypted).
        let decryptedHash = SHA256.hash(data: decrypted)
        let decryptedHex = decryptedHash.map { String(format: "%02x", $0) }.joined()

        print("📊 [Phase 2] SHA-256 original  : \(originalHex)")
        print("📊 [Phase 2] SHA-256 déchiffré : \(decryptedHex)")

        XCTAssertEqual(
            originalHex, decryptedHex,
            "SHA-256 doit être identique après round-trip chiffrement / déchiffrement"
        )
    }

    /// Si le `transferID` est modifié entre `encrypt` et `decrypt`,
    /// le tag Poly1305 doit être invalide : `decrypt` retourne `nil`.
    /// C'est la garantie que les chunks d'un transfert A ne peuvent pas
    /// être rejoués dans un transfert B.
    func testRejectsAlteredTransferID() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let sessionId = UUID()
        let transferA = UUID()
        let transferB = UUID()

        let sealed = cipher.encrypt(
            Data(repeating: 0x77, count: 4096),
            transferID: transferA,
            chunkIndex: 0,
            sessionId: sessionId
        )

        let result = cipher.decrypt(
            sealed,
            transferID: transferB, // ← transferID modifié
            chunkIndex: 0,
            sessionId: sessionId
        )
        XCTAssertNil(
            result,
            "Un transferID modifié doit faire échouer l'authentification Poly1305"
        )
    }

    /// Si le `sessionId` est modifié entre `encrypt` et `decrypt`,
    /// `decrypt` retourne `nil` (le sessionId fait partie de l'AAD).
    func testRejectsAlteredSessionId() {
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionA = UUID()
        let sessionB = UUID()

        let sealed = cipher.encrypt(
            Data(repeating: 0x88, count: 4096),
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionA
        )

        let result = cipher.decrypt(
            sealed,
            transferID: transferID,
            chunkIndex: 0,
            sessionId: sessionB // ← sessionId modifié
        )
        XCTAssertNil(
            result,
            "Un sessionId modifié doit faire échouer l'authentification Poly1305"
        )
    }

    // MARK: - 4. Rejet entre deux paires de ciphers distincts

    /// Deux paires (A, B) et (C, D) effectuent chacune un handshake ECDH
    /// indépendant avec des `sessionId` distincts. Les clés symétriques
    /// dérivées doivent être distinctes — il n'y a aucune collision.
    ///
    /// Test critique : un chunk chiffré par la paire (A, B) ne doit PAS
    /// être déchiffrable par la paire (C, D), même si elles utilisent
    /// toutes deux ChaCha20-Poly1305 avec une clé 256 bits.
    func testCipherPairRejection() throws {
        // Paire 1 : Alice / Bob, session 1.
        let alice1 = SecureHandshake()
        let bob1 = SecureHandshake()
        let session1 = UUID()
        let transfer1 = UUID()

        let keyAB = try alice1.deriveSessionKey(
            from: bob1.publicKeyData,
            sessionId: session1
        )
        let cipherAB = ChunkStreamCipher(key: keyAB)

        // Paire 2 : Carol / Dave, session 2.
        let carol = SecureHandshake()
        let dave = SecureHandshake()
        let session2 = UUID()
        let transfer2 = UUID()

        let keyCD = try carol.deriveSessionKey(
            from: dave.publicKeyData,
            sessionId: session2
        )
        let cipherCD = ChunkStreamCipher(key: keyCD)

        // Les deux clés symétriques doivent être distinctes.
        let keyABRaw = keyAB.withUnsafeBytes { Data($0) }
        let keyCDRaw = keyCD.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(
            keyABRaw, keyCDRaw,
            "Deux handshakes ECDH distincts doivent dériver des clés symétriques différentes"
        )
        XCTAssertEqual(keyABRaw.count, 32, "clé symétrique = 256 bits")
        XCTAssertEqual(keyCDRaw.count, 32, "clé symétrique = 256 bits")

        // A chiffre un message avec sa clé.
        let plaintext = Data("transfert A → B uniquement".utf8)
        let sealed = cipherAB.encrypt(
            plaintext,
            transferID: transfer1,
            chunkIndex: 0,
            sessionId: session1
        )

        // C tente de déchiffrer avec sa clé — doit échouer.
        let result = cipherCD.decrypt(
            sealed,
            transferID: transfer1,
            chunkIndex: 0,
            sessionId: session1
        )
        XCTAssertNil(
            result,
            "Un chunk chiffré par la paire A/B ne doit jamais être déchiffrable par la paire C/D"
        )

        // Et A relit son propre chunk avec ses bons paramètres — doit réussir.
        let decrypted = cipherAB.decrypt(
            sealed,
            transferID: transfer1,
            chunkIndex: 0,
            sessionId: session1
        )
        XCTAssertEqual(
            decrypted, plaintext,
            "Le destinataire légitime doit pouvoir déchiffrer"
        )

        // Et aucun croisement des paramètres (transfer2, session2) ne doit
        // fonctionner non plus, même avec la bonne clé A/B.
        let crossResult = cipherAB.decrypt(
            sealed,
            transferID: transfer2,
            chunkIndex: 0,
            sessionId: session2
        )
        XCTAssertNil(
            crossResult,
            "Un transferID ou sessionId différent doit invalider le tag, même avec la bonne clé"
        )

        // Empreinte SHA-256 du plaintext.
        let hash = SHA256.hash(data: plaintext)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        print("📊 [Phase 2] Cipher pair rejection OK — clé A/B ≠ clé C/D, SHA-256 plaintext : \(hashHex)")
    }

    // MARK: - 5. Compatibilité v1/v2 (cross-protocol) — MAJEUR-4

    /// Un pair qui parle v1 envoie un message de contrôle **non signé**
    /// alors que l'application locale est en v2. Le message doit être
    /// refusé à trois niveaux :
    ///   1. `ProtocolCompatibility.isSupported(1) == false` — la trame est
    ///      écartée avant tout routage (et la connexion fermée) ;
    ///   2. `AuthenticationPolicy` renvoie `.required` pour toute version
    ///      antérieure à v2 — aucun mode permissif ne subsiste ;
    ///   3. `MessageAuthenticator.verify` rejette un contrôle non signé.
    ///
    /// C'est la garantie anti-downgrade : conserver un fallback v1
    /// permettrait à un attaquant de faire accepter des mutations non
    /// authentifiées en annonçant simplement une version ancienne.
    func testV1IsRefusedWithoutDowngrade() {
        // Un message `hello` non signé, annoncé en v1.
        let v1Hello = AirBridgeMessage(
            protocolVersion: 1,
            type: .hello,
            sender: Device(
                id: UUID(),
                name: "Pair v1",
                model: "iPhone",
                systemVersion: "26.0"
            ),
            payload: nil,
            signature: nil
        )

        // 0. La version elle-même est hors de la plage acceptée.
        XCTAssertFalse(
            ProtocolCompatibility.isSupported(v1Hello.protocolVersion),
            "Une trame v1 ne doit pas être décodable par une application v2"
        )

        // 1. La politique reste stricte pour v1, même quand tous les
        //    autres indicateurs (pair trusted, clé qui matche)
        //    suggéreraient un traitement nominal.
        let requirement = AuthenticationPolicy.authenticationRequirement(
            for: v1Hello.type,
            protocolVersion: v1Hello.protocolVersion,
            peerTrustState: .trusted,
            peerPublicKeyMatches: true
        )
        XCTAssertEqual(
            requirement, .required,
            "Un message v1 ne doit bénéficier d'aucun mode permissif"
        )

        // 2. `MessageAuthenticator` rejette le contrôle non signé.
        let accepted = MessageAuthenticator.verify(
            v1Hello,
            requirement: requirement,
            storePublicKey: nil,
            advertisedPublicKey: nil
        )
        XCTAssertFalse(
            accepted,
            "Un message v1 non signé doit être rejeté (anti-downgrade)"
        )
    }

    // MARK: - 6. Anti-replay keyExchange — MAJEUR-4

    /// Un `keyExchange` réémis avec le même `messageID` doit être
    /// détecté comme un replay par `ReplayProtectionStore`.
    ///
    /// Le `keyExchange` est un message de premier contact (autorisé
    /// avant pairage) : un attaquant qui l'aurait capturé pourrait
    /// tenter de le rejouer pour forcer une nouvelle dérivation de
    /// clé. La fenêtre anti-replay doit rejeter la seconde occurrence
    /// sans lui laisser la possibilité de se faire passer pour un
    /// nouveau handshake.
    ///
    /// Note : ce test n'exerce pas le pipeline complet
    /// (`ConnectionManager.isFreshMessage`), qui dépend d'un acteur ;
    /// il vérifie directement la primitive `ReplayProtectionStore` qui
    /// est la brique de base.
    func testKeyExchangeReplayRejected() async {
        let store = ReplayProtectionStore()
        let peerID = UUID()
        let messageID = UUID() // même `messageID` que le `keyExchange` original

        // Première occurrence : le `keyExchange` est accepté.
        let firstObservation = await store.observe(
            peerID: peerID,
            messageID: messageID
        )
        XCTAssertTrue(
            firstObservation,
            "La première occurrence d'un keyExchange doit être acceptée"
        )

        // Rejeu : le même `(peerID, messageID)` revient. Le store doit
        // le détecter comme doublon et retourner `false`.
        let replayObservation = await store.observe(
            peerID: peerID,
            messageID: messageID
        )
        XCTAssertFalse(
            replayObservation,
            "Un keyExchange réémis avec le même messageID doit être détecté comme replay"
        )
    }
}
