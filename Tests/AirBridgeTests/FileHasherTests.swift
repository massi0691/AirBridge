//
//  FileHasherTests.swift
//  AirBridgeTests
//
//  Tests du calcul d'empreinte SHA-256 des fichiers.
//
//  Le SHA-256 est la preuve d'intégrité affichée à l'utilisateur et
//  vérifiée à la réception : une empreinte silencieusement fausse
//  invalide la détection de toute corruption. Les valeurs sont
//  comparées à des références connues (et non recalculées par le même
//  code) pour que le test échoue réellement si l'algorithme change.
//

import XCTest
import CryptoKit
@testable import AirBridge

final class FileHasherTests: XCTestCase {

    // MARK: - Valeurs de référence

    /// SHA-256 de la chaîne vide (fichier vide).
    private static let emptyFileSHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// SHA-256 de « hello ».
    private static let helloSHA256 =
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    // MARK: - Cas nominaux

    func testEmptyFileHash() throws {
        let url = try temporaryFile(data: Data())

        XCTAssertEqual(
            try FileHasher.sha256(of: url),
            Self.emptyFileSHA256,
            "L'empreinte d'un fichier vide est le SHA-256 canonique."
        )
    }

    func testSmallFileHash() throws {
        let url = try temporaryFile(data: Data("hello".utf8))

        XCTAssertEqual(
            try FileHasher.sha256(of: url),
            Self.helloSHA256
        )
    }

    /// Le buffer interne fait 64 Kio : un fichier plus grand force
    /// plusieurs passages dans la boucle de lecture.
    func testLargeFileHashSpansMultipleBuffers() throws {
        let payload = Data((0..<(256 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let url = try temporaryFile(data: payload)

        let expected = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(try FileHasher.sha256(of: url), expected)
    }

    /// La taille exacte de la limite de buffer : un seul passage avec
    /// un dernier fragment potentiellement nul.
    func testFileExactlyAtBufferSize() throws {
        let payload = Data((0..<(64 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let url = try temporaryFile(data: payload)

        let expected = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(try FileHasher.sha256(of: url), expected)
    }

    func testIdenticalContentsProduceIdenticalHashes() throws {
        let payload = Data((0..<(100 * 1024)).map { _ in UInt8.random(in: 0...255) })

        let a = try temporaryFile(data: payload)
        let b = try temporaryFile(data: payload)

        XCTAssertEqual(
            try FileHasher.sha256(of: a),
            try FileHasher.sha256(of: b)
        )
    }

    func testDifferentContentsProduceDifferentHashes() throws {
        let a = try temporaryFile(data: Data("hello".utf8))
        let b = try temporaryFile(data: Data("world".utf8))

        XCTAssertNotEqual(
            try FileHasher.sha256(of: a),
            try FileHasher.sha256(of: b)
        )
    }

    // MARK: - Gestion d'erreurs

    func testMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbridge-missing-\(UUID().uuidString).bin")

        // Un fichier absent ne doit PAS être confondu avec un fichier
        // vide : l'empreinte ne peut pas être calculée.
        XCTAssertThrowsError(
            try FileHasher.sha256(of: missing)
        ) { error in
            XCTAssertNotEqual(
                error.localizedDescription,
                "",
                "L'erreur doit nommer le fichier introuvable : \(error)"
            )
        }
    }

    func testSha256IfAvailableReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbridge-missing-\(UUID().uuidString).bin")

        XCTAssertNil(FileHasher.sha256IfAvailable(of: missing))
    }

    func testSha256IfAvailableReturnsHashForValidFile() throws {
        let url = try temporaryFile(data: Data("hello".utf8))

        XCTAssertEqual(
            FileHasher.sha256IfAvailable(of: url),
            Self.helloSHA256
        )
    }

    // MARK: - Outils

    private func temporaryFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbridge-hash-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }
}
