//
 //  BinaryFileChunkPayloadTests.swift
 //  AirBridgeTests
 //
 //  Created by massi9106 on 23/08/2026.
 //

import XCTest
@testable import AirBridge

final class BinaryFileChunkPayloadTests: XCTestCase {

    // MARK: - Round-trip

    func testEncodeDecodeRoundTrip() {
        let transferID = UUID()
        let offset: Int64 = 1_000_000
        let data = Data(repeating: 0xAB, count: 2_000_000)
        let isLastChunk = true

        let original = BinaryFileChunkPayload(
            transferID: transferID,
            offset: offset,
            data: data,
            isLastChunk: isLastChunk
        )

        let encoded = original.encode()
        let decoded = try! BinaryFileChunkPayload.decode(encoded)

        XCTAssertEqual(decoded.transferID, transferID)
        XCTAssertEqual(decoded.offset, offset)
        XCTAssertEqual(decoded.data, data)
        XCTAssertEqual(decoded.isLastChunk, isLastChunk)
    }

    func testEncodeDecodeRoundTripNotLastChunk() {
        let transferID = UUID()
        let offset: Int64 = 0
        let data = Data(repeating: 0x42, count: 2_000_000)
        let isLastChunk = false

        let original = BinaryFileChunkPayload(
            transferID: transferID,
            offset: offset,
            data: data,
            isLastChunk: isLastChunk
        )

        let encoded = original.encode()
        let decoded = try! BinaryFileChunkPayload.decode(encoded)

        XCTAssertEqual(decoded.transferID, transferID)
        XCTAssertEqual(decoded.offset, offset)
        XCTAssertEqual(decoded.data, data)
        XCTAssertEqual(decoded.isLastChunk, isLastChunk)
    }

    func testEncodeDecodeRoundTripSmallChunk() {
        let transferID = UUID()
        let offset: Int64 = 512 * 1024
        let data = Data("Hello, world!".utf8)
        let isLastChunk = true

        let original = BinaryFileChunkPayload(
            transferID: transferID,
            offset: offset,
            data: data,
            isLastChunk: isLastChunk
        )

        let encoded = original.encode()
        let decoded = try! BinaryFileChunkPayload.decode(encoded)

        XCTAssertEqual(decoded.transferID, transferID)
        XCTAssertEqual(decoded.offset, offset)
        XCTAssertEqual(decoded.data, data)
        XCTAssertEqual(decoded.isLastChunk, isLastChunk)
    }

    // MARK: - Structure

    func testHeaderSizeIs45Bytes() {
        // L'en-tête binaire v2 est désormais de 45 octets :
        //   4  (length) + 16 (transferID) + 8 (offset) + 1 (flags) + 16 (sessionId)
        // Le sessionId lie chaque chunk à la session active.
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(),
            isLastChunk: false
        )

        XCTAssertEqual(payload.encode().count, BinaryFileChunkPayload.headerSize)
    }

    func testHeaderSizeConstant() {
        XCTAssertEqual(BinaryFileChunkPayload.headerSize, 45)
    }

    func testEncodedLengthIncludesDataSize() {
        let data = Data(repeating: 0xFF, count: 123_456)
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: data,
            isLastChunk: false
        )

        let encoded = payload.encode()
        XCTAssertEqual(encoded.count, BinaryFileChunkPayload.headerSize + data.count)
    }

    // MARK: - Header fields

    func testLengthFieldIsFirst4Bytes() {
        let data = Data(repeating: 0x00, count: 1000)
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: data,
            isLastChunk: false
        )

        let encoded = payload.encode()
        let length = encoded.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(length), data.count)
    }

    func testTransferIDAtOffset4() {
        let transferID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let payload = BinaryFileChunkPayload(
            transferID: transferID,
            offset: 0,
            data: Data(count: 10),
            isLastChunk: false
        )

        let encoded = payload.encode()
        let uuidData = encoded.subdata(in: 4..<20)
        let decodedID = uuidData.withUnsafeBytes { bytes in
            UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
        }
        XCTAssertEqual(decodedID, transferID)
    }

    func testOffsetAtOffset20() {
        let offset: Int64 = 987_654_321
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: offset,
            data: Data(count: 10),
            isLastChunk: false
        )

        let encoded = payload.encode()
        let offsetData = encoded.subdata(in: 20..<28)
        let decodedOffset = Int64(bitPattern: offsetData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian })
        XCTAssertEqual(decodedOffset, offset)
    }

    func testFlagsAtOffset28() {
        let payloadLast = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(count: 10),
            isLastChunk: true
        )
        let payloadNotLast = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(count: 10),
            isLastChunk: false
        )

        let encodedLast = payloadLast.encode()
        let encodedNotLast = payloadNotLast.encode()

        XCTAssertEqual(encodedLast[28], 0x01)
        XCTAssertEqual(encodedNotLast[28], 0x00)
    }

    func testSessionIdAtOffset29() {
        // Le sessionId suit immédiatement le flags, sur 16 octets (29..44).
        // Il lie chaque chunk à la session active — un chunk déplacé
        // d'une autre session sera rejeté à la réception.
        let sessionId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(count: 10),
            isLastChunk: false,
            sessionId: sessionId
        )

        let encoded = payload.encode()
        let sessionData = encoded.subdata(in: 29..<45)
        let decoded = sessionData.withUnsafeBytes { bytes in
            UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
        }
        XCTAssertEqual(decoded, sessionId)
    }

    // MARK: - Error handling

    func testDecodeTooShortDataThrows() {
        let shortData = Data(count: BinaryFileChunkPayload.headerSize - 1)
        XCTAssertThrowsError(try BinaryFileChunkPayload.decode(shortData)) { error in
            guard case BinaryFileChunkError.invalidData(let msg) = error else {
                XCTFail("Erreur inattendue : \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Données trop courtes"))
        }
    }

    func testDecodeDataLengthMismatchThrows() {
        // Crée un payload valide puis modifie le length field
        var data = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(count: 100),
            isLastChunk: false
        ).encode()

        // Change le length field à une valeur incorrecte
        var wrongLength = UInt32(999).bigEndian
        data.replaceSubrange(0..<4, with: Data(bytes: &wrongLength, count: 4))

        XCTAssertThrowsError(try BinaryFileChunkPayload.decode(data)) { error in
            guard case BinaryFileChunkError.invalidData(let msg) = error else {
                XCTFail("Erreur inattendue : \(error)")
                return
            }
            XCTAssertTrue(msg.contains("incoh"))
        }
    }

    // MARK: - Codable conformance (via MessageCodec)

    func testCodableRoundTripViaMessageCodec() {
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 123_456,
            data: Data(repeating: 0xCD, count: 500_000),
            isLastChunk: true
        )

        let codec = MessageCodec()
        let encoded = try! codec.encodePayload(payload, protocolVersion: 2)
        let decoded = try! codec.decodePayload(
            BinaryFileChunkPayload.self,
            from: encoded,
            protocolVersion: 2,
            messageType: .fileChunk
        )

        XCTAssertEqual(decoded.transferID, payload.transferID)
        XCTAssertEqual(decoded.offset, payload.offset)
        XCTAssertEqual(decoded.data, payload.data)
        XCTAssertEqual(decoded.isLastChunk, payload.isLastChunk)
    }

    func testMessageCodecFallsBackToJSONForV1() {
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 123,
            data: Data("test".utf8),
            isLastChunk: false
        )

        let codec = MessageCodec()
        // En v1, on ne doit pas utiliser BinaryFileChunkPayload directement
        // mais le test vérifie que l'encodage JSON fonctionne
        let encoded = try! codec.encodePayload(payload, protocolVersion: 1)
        let decoded = try! codec.decodePayload(
            BinaryFileChunkPayload.self,
            from: encoded,
            protocolVersion: 1,
            messageType: .fileChunk
        )

        XCTAssertEqual(decoded.transferID, payload.transferID)
        XCTAssertEqual(decoded.offset, payload.offset)
        XCTAssertEqual(decoded.data, payload.data)
        XCTAssertEqual(decoded.isLastChunk, payload.isLastChunk)
    }

    // MARK: - MessageCodec integration

    func testMessageCodecUsesBinaryForV2FileChunk() {
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: Data(repeating: 0xEF, count: 100),
            isLastChunk: true
        )

        let codec = MessageCodec()
        let encoded = try! codec.encodePayload(payload, protocolVersion: 2)
        let decoded = try! codec.decodePayload(
            BinaryFileChunkPayload.self,
            from: encoded,
            protocolVersion: 2,
            messageType: .fileChunk
        )

        // Le format binaire est plus compact que JSON+base64
        XCTAssertEqual(decoded.data.count, 100)
        XCTAssertEqual(decoded.isLastChunk, true)
    }

    // MARK: - FrameCodec integration

    func testBinaryPayloadFitsInFrame() {
        // Un chunk de 2 Mo doit tenir dans une frame
        let largeData = Data(repeating: 0x00, count: 2 * 1024 * 1024)
        let payload = BinaryFileChunkPayload(
            transferID: UUID(),
            offset: 0,
            data: largeData,
            isLastChunk: true
        )

        let encoded = payload.encode()
        let frameCodec = FrameCodec()
        let framed = try! frameCodec.encode(encoded)

        // Header (4B) + payload (45B + 2MB)
        let expectedSize = FrameCodec.headerSize + BinaryFileChunkPayload.headerSize + largeData.count
        XCTAssertEqual(framed.count, expectedSize)
        XCTAssertLessThan(framed.count, FrameCodec.maximumFrameSize)
    }
}