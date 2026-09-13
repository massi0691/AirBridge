//
//  ChunkStreamCipher.swift
//  AirBridge
//
//  Created by massi9106 on 27/08/2026.
//
//  Chiffrement de flux des chunks de fichier via ChaCha20-Poly1305.
//
//  Le format d'un chunk chiffré est :
//    [nonce (12 octets)] [ciphertext (N octets)] [tag (16 octets)]
//
//  Le `nonce` est dérivé du `transferID` (8 octets de poids fort de
//  l'UUID) concaténé au `chunkIndex` (UInt32 en big endian) — soit
//  12 octets. Le `transferID` est OBLIGATOIRE dans la dérivation du
//  nonce (et pas seulement dans l'AAD) : deux transferts A et B
//  partageant la même `sessionId` repartent sinon de `chunkIndex = 0`
//  et produiraient le même nonce pour leur premier chunk — violation
//  RFC 7539 (two-time pad attack). L'inclusion du `transferID` dans
//  le nonce garantit l'unicité (key, nonce) par transfert. Le
//  `sessionId` reste dans l'AAD (pour lier le chunk à la session
//  cross-transferts) mais n'entre plus dans la dérivation du nonce.
//
//  Le `aad` (additional authenticated data) est
//  `transferID || chunkIndex || sessionId` : tout chunk déplacé d'un
//  autre transfert ou d'une autre session sera rejeté à
//  l'authentification.
//
//  Le chiffrement est volontairement **opt-in** : tant qu'une clé
//  symétrique n'est pas installée via `installKey(_:)`, le codec
//  fonctionne en mode transparent (le chunk passe en clair, comme
//  avant). L'activation se fait au moment où le handshake sécurisé
//  (ECDH P-256, planifié dans une phase ultérieure) aboutit.

import Foundation
import CryptoKit

/// Chiffrement symétrique d'un chunk binaire v2.
///
/// Sans clé installée, `encrypt(_:)` et `decrypt(_:)` retournent les
/// données inchangées (mode transparent). Avec une clé, ChaCha20-Poly1305
/// est appliqué en flux : chaque chunk est scellé avec un nonce unique
/// dérivé de `transferID + chunkIndex`, et un AAD qui lie le chunk à
/// son transfert et à sa session.
///
/// `nonisolated` : la structure est immutable (`let key`), donc
/// sans danger à utiliser depuis un actor de fond (le `ChunkSink`
/// de la phase 2-bis). Le projet compile en `-default-isolation=MainActor`,
/// ce qui rendrait la structure `@MainActor` par défaut ; on annule
/// explicitement cet héritage ici.
nonisolated struct ChunkStreamCipher {

    /// Longueur du nonce ChaCha20-Poly1305 (12 octets, standard).
    static let nonceSize = 12

    /// Longueur du tag d'authentification Poly1305 (16 octets).
    static let tagSize = 16

    private let key: SymmetricKey?

    nonisolated init(key: SymmetricKey? = nil) {
        self.key = key
    }

    /// Indique si une clé de chiffrement est installée. `false` = mode
    /// transparent (chunk en clair, comme avant).
    nonisolated var hasKey: Bool {
        return key != nil
    }

    /// Chiffre les données d'un chunk si une clé est installée.
    ///
    /// - Parameters:
    ///   - plaintext: données brutes du chunk
    ///   - transferID: identifiant du transfert
    ///   - chunkIndex: index du chunk dans le transfert
    ///   - sessionId: identifiant de la session active
    /// - Returns: `nonce (12) || ciphertext || tag (16)` si une clé est
    ///   installée, sinon les données brutes (mode transparent).
    nonisolated func encrypt(
        _ plaintext: Data,
        transferID: UUID,
        chunkIndex: UInt32,
        sessionId: UUID
    ) -> Data {
        guard let key = key else {
            return plaintext
        }

        let nonce = Self.deriveNonce(
            transferID: transferID,
            chunkIndex: chunkIndex
        )
        let aad = Self.deriveAAD(
            transferID: transferID,
            chunkIndex: chunkIndex,
            sessionId: sessionId
        )

        do {
            let nonceObj = try ChaChaPoly.Nonce(data: nonce)
            let sealed = try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: nonceObj,
                authenticating: aad
            )

            // Format : [nonce (12)][ciphertext][tag (16)]
            var output = Data()
            output.reserveCapacity(
                Self.nonceSize + sealed.ciphertext.count + Self.tagSize
            )
            output.append(nonce)
            output.append(sealed.ciphertext)
            output.append(sealed.tag)
            return output

        } catch {
            // En cas d'échec de scellage (très improbable), on retourne
            // les données en clair plutôt que de bloquer l'envoi.
            return plaintext
        }
    }

    /// Déchiffre les données d'un chunk si une clé est installée.
    ///
    /// - Parameters:
    ///   - data: données reçues (`nonce || ciphertext || tag`)
    ///   - transferID: identifiant du transfert
    ///   - chunkIndex: index du chunk dans le transfert
    ///   - sessionId: identifiant de la session active
    /// - Returns: plaintext déchiffré si la clé est installée et
    ///   l'authentification réussie ; `nil` si le tag ne correspond pas
    ///   (chunk corrompu, d'une autre session, ou rejoué). En mode
    ///   transparent, retourne `data` inchangé.
    nonisolated func decrypt(
        _ data: Data,
        transferID: UUID,
        chunkIndex: UInt32,
        sessionId: UUID
    ) -> Data? {
        guard key != nil else {
            return data
        }

        guard data.count >= Self.nonceSize + Self.tagSize else {
            return nil
        }

        let nonce = data.prefix(Self.nonceSize)
        let tag = data.suffix(Self.tagSize)
        let ciphertext = data.subdata(
            in: Self.nonceSize..<(data.count - Self.tagSize)
        )

        let aad = Self.deriveAAD(
            transferID: transferID,
            chunkIndex: chunkIndex,
            sessionId: sessionId
        )

        do {
            let nonceObj = try ChaChaPoly.Nonce(data: nonce)
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: nonceObj,
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(
                sealedBox,
                using: key!,
                authenticating: aad
            )
        } catch {
            // Tag invalide : chunk corrompu, déplacé, ou rejoué
            return nil
        }
    }

    // MARK: - Helpers

    /// Dérive un nonce unique par chunk à partir du `transferID` et du
    /// `chunkIndex`. Les 8 premiers octets sont les 8 premiers octets
    /// de la représentation binaire du `transferID` (ordre hôte — voir
    /// [CRITIQUE-1] dans le rapport du reviewer), les 4 derniers sont
    /// le `chunkIndex` en big endian.
    ///
    /// L'inclusion du `transferID` dans le nonce est OBLIGATOIRE pour
    /// respecter RFC 7539 : deux transferts A et B partageant la même
    /// `sessionId` et démarrant à `chunkIndex = 0` produiraient sinon
    /// le même nonce, ce qui constitue un two-time pad attack et
    /// compromet la confidentialité du chiffrement de flux.
    nonisolated private static func deriveNonce(
        transferID: UUID,
        chunkIndex: UInt32
    ) -> Data {
        var nonce = Data(capacity: nonceSize)
        nonce.append(withUnsafeBytes(of: transferID.uuid) { Data($0.prefix(8)) })
        var indexBE = chunkIndex.bigEndian
        nonce.append(Data(bytes: &indexBE, count: 4))
        return nonce
    }

    /// Construit l'additional authenticated data : `transferID ||
    /// chunkIndex || sessionId`. Tout chunk déplacé d'un autre
    /// transfert ou d'une autre session sera rejeté à l'ouverture.
    nonisolated private static func deriveAAD(
        transferID: UUID,
        chunkIndex: UInt32,
        sessionId: UUID
    ) -> Data {
        var aad = Data()
        aad.append(withUnsafeBytes(of: transferID.uuid) { Data($0) })
        var indexBE = chunkIndex.bigEndian
        aad.append(Data(bytes: &indexBE, count: 4))
        aad.append(withUnsafeBytes(of: sessionId.uuid) { Data($0) })
        return aad
    }
}
