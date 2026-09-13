//
//  TransferPerformanceBenchmarks.swift
//  AirBridgeTests
//
//  Benchmarks de performance pour le pipeline de transfert.
//
//  Mesures (via `XCTMeasureOptions` / `measure { ... }`) :
//   - encodage binaire v2 (BinaryFileChunkPayload) sur 100 MB ;
//   - encodage + décodage binaire sur 100 MB ;
//   - encodage via FrameCodec sur 100 MB ;
//   - chiffrement / déchiffrement ChaCha20-Poly1305 sur 100 MB
//     (chiffre clé pour la cible > 20 MB/s) ;
//   - chiffrement / déchiffrement ChaCha20-Poly1305 sur 1 GB
//     (skip par défaut sur CI contraints) ;
//   - lecture disque (Data + FileHandle) sur 100 MB pour établir
//     la baseline disque.
//

import XCTest
import CryptoKit
@testable import AirBridge

final class TransferPerformanceBenchmarks: XCTestCase {

    // 100 MB
    private let hundredMB = 100 * 1024 * 1024
    // 1 GB
    private let oneGB = 1024 * 1024 * 1024

    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        tempFiles = []
    }

    override func tearDown() {
        // Nettoyage des fichiers temporaires.
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles = []
        super.tearDown()
    }

    // MARK: - Encodage binaire 100 MB

    /// Synthèse de 100 MB de données, encodage en 100 chunks binaires v2
    /// de 1 MB chacun. Mesure le débit d'encodage.
    func testBinaryChunkEncode100MB() throws {
        let totalBytes = hundredMB
        let chunkSize = 1 * 1024 * 1024
        let totalData = Data((0..<totalBytes).map { _ in UInt8.random(in: 0...255) })

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(options: options) {
            var offset: Int = 0
            while offset < totalData.count {
                let end = min(offset + chunkSize, totalData.count)
                let slice = totalData.subdata(in: offset..<end)
                let chunk = BinaryFileChunkPayload(
                    transferID: UUID(),
                    offset: Int64(offset),
                    data: slice,
                    isLastChunk: end == totalData.count,
                    sessionId: UUID()
                )
                _ = chunk.encode()
                offset = end
            }
        }

        // Mesure d'un seul passage pour calculer le MB/s.
        let start = Date()
        var offset: Int = 0
        while offset < totalData.count {
            let end = min(offset + chunkSize, totalData.count)
            let slice = totalData.subdata(in: offset..<end)
            let chunk = BinaryFileChunkPayload(
                transferID: UUID(),
                offset: Int64(offset),
                data: slice,
                isLastChunk: end == totalData.count,
                sessionId: UUID()
            )
            _ = chunk.encode()
            offset = end
        }
        let elapsed = Date().timeIntervalSince(start)
        let throughput = Double(totalBytes) / elapsed / (1024 * 1024)
        print("📊 testBinaryChunkEncode100MB : \(String(format: "%.2f", throughput)) MB/s")
        _ = totalData // silence
    }

    /// Round-trip encode + decode sur 100 MB de chunks de 1 MB.
    func testBinaryChunkEncodeDecodeRoundtrip100MB() throws {
        let totalBytes = hundredMB
        let chunkSize = 1 * 1024 * 1024
        let totalData = Data((0..<totalBytes).map { _ in UInt8.random(in: 0...255) })

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(options: options) {
            var offset: Int = 0
            while offset < totalData.count {
                let end = min(offset + chunkSize, totalData.count)
                let slice = totalData.subdata(in: offset..<end)
                let chunk = BinaryFileChunkPayload(
                    transferID: UUID(),
                    offset: Int64(offset),
                    data: slice,
                    isLastChunk: end == totalData.count,
                    sessionId: UUID()
                )
                let encoded = chunk.encode()
                _ = try! BinaryFileChunkPayload.decode(encoded)
                offset = end
            }
        }

        let start = Date()
        var offset: Int = 0
        while offset < totalData.count {
            let end = min(offset + chunkSize, totalData.count)
            let slice = totalData.subdata(in: offset..<end)
            let chunk = BinaryFileChunkPayload(
                transferID: UUID(),
                offset: Int64(offset),
                data: slice,
                isLastChunk: end == totalData.count,
                sessionId: UUID()
            )
            let encoded = chunk.encode()
            _ = try! BinaryFileChunkPayload.decode(encoded)
            offset = end
        }
        let elapsed = Date().timeIntervalSince(start)
        let throughput = Double(totalBytes) / elapsed / (1024 * 1024)
        print("📊 testBinaryChunkEncodeDecodeRoundtrip100MB : \(String(format: "%.2f", throughput)) MB/s")
    }

    // MARK: - Encodage via FrameCodec

    /// Encodage via FrameCodec sur 100 MB total, en frames de 1 MB (la
    /// limite `FrameCodec.maximumFrameSize` est 10 MB ; on chunked donc
    /// en blocs de 1 MB). Mesure le débit d'encodage + framing.
    func testFrameEncode100MB() throws {
        let totalBytes = hundredMB
        let chunkSize = 1 * 1024 * 1024
        let totalData = Data((0..<totalBytes).map { _ in UInt8.random(in: 0...255) })
        let frameCodec = FrameCodec()

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(options: options) {
            var offset: Int = 0
            while offset < totalData.count {
                let end = min(offset + chunkSize, totalData.count)
                let slice = totalData.subdata(in: offset..<end)
                let framed = try! frameCodec.encode(slice)
                _ = framed
                offset = end
            }
        }

        let start = Date()
        var offset: Int = 0
        while offset < totalData.count {
            let end = min(offset + chunkSize, totalData.count)
            let slice = totalData.subdata(in: offset..<end)
            let framed = try! frameCodec.encode(slice)
            _ = framed
            offset = end
        }
        let elapsed = Date().timeIntervalSince(start)
        let throughput = Double(totalBytes) / elapsed / (1024 * 1024)
        print("📊 testFrameEncode100MB : \(String(format: "%.2f", throughput)) MB/s")
    }

    // MARK: - Chiffrement ChaCha20-Poly1305

    /// Chiffrement + déchiffrement ChaCha20-Poly1305 sur 100 MB en chunks
    /// de 1 MB. C'est le **chiffre clé** pour la cible de > 20 MB/s.
    func testChaChaPolyEncryptDecrypt100MB() throws {
        let totalBytes = hundredMB
        let chunkSize = 1 * 1024 * 1024
        let totalData = Data((0..<totalBytes).map { _ in UInt8.random(in: 0...255) })
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionId = UUID()

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(options: options) {
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
                _ = cipher.decrypt(
                    sealed,
                    transferID: transferID,
                    chunkIndex: index,
                    sessionId: sessionId
                )
                offset = end
                index += 1
            }
        }

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
            _ = cipher.decrypt(
                sealed,
                transferID: transferID,
                chunkIndex: index,
                sessionId: sessionId
            )
            offset = end
            index += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        let throughput = Double(totalBytes) / elapsed / (1024 * 1024)
        print("📊 testChaChaPolyEncryptDecrypt100MB : \(String(format: "%.2f", throughput)) MB/s")
    }

    /// Chiffrement + déchiffrement ChaCha20-Poly1305 sur 1 GB en chunks
    /// de 1 MB. Skipé par défaut — activer via la variable d'environnement
    /// `RUN_1GB_BENCH=1` sur les machines non contraintes.
    func testChaChaPolyEncryptDecrypt1GB() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RUN_1GB_BENCH"] == nil,
            "Test 1 GB skipé par défaut (définir RUN_1GB_BENCH=1 pour l'activer)"
        )

        let totalBytes = oneGB
        let chunkSize = 1 * 1024 * 1024
        let totalData = Data((0..<totalBytes).map { _ in UInt8.random(in: 0...255) })
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)

        let transferID = UUID()
        let sessionId = UUID()

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
            _ = cipher.decrypt(
                sealed,
                transferID: transferID,
                chunkIndex: index,
                sessionId: sessionId
            )
            offset = end
            index += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        let throughput = Double(totalBytes) / elapsed / (1024 * 1024)
        print("📊 testChaChaPolyEncryptDecrypt1GB : \(String(format: "%.2f", throughput)) MB/s")
    }

    // MARK: - Baseline disque

    /// Crée un fichier de 100 MB, le lit par tranches de 1 MB, mesure le
    /// débit. Établit la baseline que l'application doit approcher.
    func testFileReadThroughput() throws {
        let totalBytes = hundredMB
        let chunkSize = 1 * 1024 * 1024
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbridge-bench-\(UUID().uuidString).bin")
        tempFiles.append(fileURL)

        // Écriture initiale.
        let totalData = Data((0..<totalBytes).map { _ in UInt8.random(in: 0...255) })
        try totalData.write(to: fileURL)

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(options: options) {
            let handle = try! FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            while true {
                let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
                if chunk == nil || chunk?.isEmpty == true { break }
            }
        }

        // Mesure dédiée pour le calcul du débit.
        let start = Date()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            if chunk == nil || chunk?.isEmpty == true { break }
        }
        let elapsed = Date().timeIntervalSince(start)
        let throughput = Double(totalBytes) / elapsed / (1024 * 1024)
        print("📊 testFileReadThroughput : \(String(format: "%.2f", throughput)) MB/s")
    }

    // MARK: - Stabilité CPU

    /// Test observationnel : 100 chunks de 1 MB chiffrés en boucle serrée.
    /// Mesure le temps total et le temps moyen par chunk. Assertion douce
    /// : pas de régression catastrophique (> 1 s par chunk).
    func testChunkEncryptCPUStability() {
        let chunkSize = 1 * 1024 * 1024
        let chunkCount = 100
        let key = SymmetricKey(size: .bits256)
        let cipher = ChunkStreamCipher(key: key)
        let transferID = UUID()
        let sessionId = UUID()

        let start = Date()
        var perChunkTimes: [Double] = []
        for i in 0..<chunkCount {
            let data = Data((0..<chunkSize).map { _ in UInt8.random(in: 0...255) })
            let t0 = Date()
            let sealed = cipher.encrypt(
                data,
                transferID: transferID,
                chunkIndex: UInt32(i),
                sessionId: sessionId
            )
            _ = cipher.decrypt(
                sealed,
                transferID: transferID,
                chunkIndex: UInt32(i),
                sessionId: sessionId
            )
            perChunkTimes.append(Date().timeIntervalSince(t0))
        }
        let totalElapsed = Date().timeIntervalSince(start)
        let avgMs = (perChunkTimes.reduce(0, +) / Double(perChunkTimes.count)) * 1000
        let maxMs = (perChunkTimes.max() ?? 0) * 1000
        let minMs = (perChunkTimes.min() ?? 0) * 1000
        let throughput = Double(chunkCount * chunkSize) / totalElapsed / (1024 * 1024)

        print("📊 testChunkEncryptCPUStability : total=\(String(format: "%.3f", totalElapsed))s, " +
              "avg=\(String(format: "%.2f", avgMs))ms/chunk, " +
              "min=\(String(format: "%.2f", minMs))ms, " +
              "max=\(String(format: "%.2f", maxMs))ms, " +
              "throughput=\(String(format: "%.2f", throughput)) MB/s")

        // Assertion douce : pas de régression catastrophique (> 1 s par chunk).
        XCTAssertLessThan(
            maxMs, 1_000,
            "Un chunk de 1 MB ne doit pas prendre plus d'1 s (mesuré : \(maxMs) ms)"
        )
    }
}
