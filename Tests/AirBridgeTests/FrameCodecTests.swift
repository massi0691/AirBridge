//
//  FrameCodecTests.swift
//  AirBridgeTests
//

import XCTest
@testable import AirBridge

final class FrameCodecTests: XCTestCase {

    private let codec = FrameCodec()

    // MARK: - Aller-retour

    func testAFrameDecodesBackToItsPayloadLength() throws {
        let payload = Data(repeating: 0xAB, count: 1_234)
        let frame = try codec.encode(payload)

        XCTAssertEqual(
            frame.count,
            FrameCodec.headerSize + payload.count
        )

        let header = frame.prefix(FrameCodec.headerSize)

        XCTAssertEqual(
            try codec.decodeLength(from: header),
            payload.count
        )
    }

    func testAnEmptyPayloadEncodesAZeroLength() throws {
        let frame = try codec.encode(Data())

        XCTAssertEqual(
            try codec.decodeLength(
                from: frame.prefix(FrameCodec.headerSize)
            ),
            0
        )
    }

    func testTheLargestAllowedPayloadRoundTrips() throws {
        let header = Data([
            UInt8((FrameCodec.maximumFrameSize >> 24) & 0xFF),
            UInt8((FrameCodec.maximumFrameSize >> 16) & 0xFF),
            UInt8((FrameCodec.maximumFrameSize >> 8) & 0xFF),
            UInt8(FrameCodec.maximumFrameSize & 0xFF)
        ])

        XCTAssertEqual(
            try codec.decodeLength(from: header),
            FrameCodec.maximumFrameSize
        )
    }

    // MARK: - Ordre des octets

    /// L'en-tête est gros-boutien : c'est ce qui passe sur le câble, et
    /// deux appareils doivent le lire pareil quelle que soit leur
    /// architecture.
    func testTheHeaderIsBigEndian() throws {
        let header = Data([0x00, 0x00, 0x01, 0x00])

        XCTAssertEqual(
            try codec.decodeLength(from: header),
            256
        )
    }

    // MARK: - En-tête non aligné

    /// `Data` ne garantit aucun alignement : une tranche d'un tampon plus
    /// grand peut commencer à un octet impair. Lire l'entier avec `load`
    /// y est un comportement indéfini — ce test décale volontairement
    /// l'en-tête pour exercer ce cas.
    func testAHeaderSlicedAtAnOddOffsetDecodesCorrectly() throws {
        for offset in 1...7 {
            var buffer = Data(repeating: 0x00, count: offset)
            buffer.append(Data([0x00, 0x00, 0x01, 0x00]))

            let slice = buffer.suffix(FrameCodec.headerSize)

            XCTAssertEqual(
                try codec.decodeLength(from: slice),
                256,
                "En-tête décalé de \(offset) octets mal décodé"
            )
        }
    }

    /// Le même contrôle sur un vrai en-tête produit par `encode`, extrait
    /// d'un tampon de trames concaténées comme le fait une lecture réseau.
    func testAHeaderExtractedFromConcatenatedFramesDecodesCorrectly() throws {
        let first = try codec.encode(Data(repeating: 0x01, count: 3))
        let second = try codec.encode(Data(repeating: 0x02, count: 777))

        let stream = first + second

        let secondHeader = stream.dropFirst(first.count)
            .prefix(FrameCodec.headerSize)

        XCTAssertEqual(
            try codec.decodeLength(from: secondHeader),
            777
        )
    }

    // MARK: - En-têtes invalides

    func testAShortHeaderIsRejected() {
        XCTAssertThrowsError(
            try codec.decodeLength(from: Data([0x00, 0x01]))
        )
    }

    func testAnEmptyHeaderIsRejected() {
        XCTAssertThrowsError(
            try codec.decodeLength(from: Data())
        )
    }

    func testAnOversizedHeaderIsRejected() {
        XCTAssertThrowsError(
            try codec.decodeLength(
                from: Data(repeating: 0x00, count: 5)
            )
        )
    }

    // MARK: - Plafond de trame

    /// Un en-tête annonçant quatre gigaoctets est refusé plutôt que
    /// provisionné : sinon le récepteur attendrait une lecture qu'il ne
    /// peut pas satisfaire.
    func testAHeaderAnnouncingMoreThanTheMaximumIsRejected() {
        let header = Data([0xFF, 0xFF, 0xFF, 0xFF])

        XCTAssertThrowsError(
            try codec.decodeLength(from: header)
        ) { error in
            XCTAssertEqual(
                error as? FrameCodecError,
                .frameTooLarge
            )
        }
    }

    func testEncodingBeyondTheMaximumIsRejected() {
        let payload = Data(
            repeating: 0x00,
            count: FrameCodec.maximumFrameSize + 1
        )

        XCTAssertThrowsError(
            try codec.encode(payload)
        ) { error in
            XCTAssertEqual(
                error as? FrameCodecError,
                .frameTooLarge
            )
        }
    }

    /// Le plafond de trame doit rester au-dessus du plus gros morceau que
    /// l'émetteur produit, sinon les gros fichiers deviendraient
    /// inenvoyables.
    func testTheMaximumFrameLeavesRoomForTheLargestChunk() {
        XCTAssertLessThan(
            TransferChunkSizing.largeFileChunkSize,
            FrameCodec.maximumFrameSize
        )
    }
}
