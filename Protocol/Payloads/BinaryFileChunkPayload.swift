//
//  BinaryFileChunkPayload.swift
//  AirBridge
//
//  Created by massi9106 on 23/08/2026.
//

import Foundation

/// Format binaire pour fileChunk (protocole v2+).
///
/// Structure exacte (45 octets d'en-tête + données) :
///   Offset 0..3   : UInt32BE  — taille du chunk (data.count)
///   Offset 4..19  : UUID      — transferID (16 octets, format standard RFC 4122)
///   Offset 20..27 : Int64BE   — offset dans le fichier
///   Offset 28     : UInt8     — flags (bit 0 = isLastChunk)
///   Offset 29..44 : UUID      — sessionId (16 octets) — lie le chunk à la session
///   Offset 45..   : Data      — données brutes du chunk (sans encodage)
///
/// Ce format évite le double base64 (Data → JSON base64 → FrameCodec base64)
/// qui gonflait les chunks de ~78 %. Le gain théorique est ×1,78 sur le débit.
///
/// Le `sessionId` permet au récepteur de vérifier que chaque chunk appartient
/// bien à la session en cours : un attaquant ne peut pas injecter des chunks
/// d'une autre session, même en connaissant le `transferID`.
struct BinaryFileChunkPayload: Codable, Sendable {

    let transferID: UUID
    let offset: Int64
    let data: Data
    let isLastChunk: Bool
    let sessionId: UUID

    /// Taille fixe de l'en-tête binaire
    static let headerSize = 4 + 16 + 8 + 1 + 16  // = 45 octets

    init(
        transferID: UUID,
        offset: Int64,
        data: Data,
        isLastChunk: Bool,
        sessionId: UUID = UUID()
    ) {
        self.transferID = transferID
        self.offset = offset
        self.data = data
        self.isLastChunk = isLastChunk
        self.sessionId = sessionId
    }

    /// Encode le payload en Data binaire brut.
    func encode() -> Data {
        var buffer = Data()
        buffer.reserveCapacity(Self.headerSize + data.count)

        // Length (UInt32BE) - taille des données seulement
        var length = UInt32(data.count).bigEndian
        buffer.append(Data(bytes: &length, count: 4))

        // TransferID (16 bytes UUID) - UUID.uuid returns a tuple of 16 UInt8
        let uuid = transferID.uuid
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        uuidBytes[0] = uuid.0; uuidBytes[1] = uuid.1; uuidBytes[2] = uuid.2; uuidBytes[3] = uuid.3
        uuidBytes[4] = uuid.4; uuidBytes[5] = uuid.5; uuidBytes[6] = uuid.6; uuidBytes[7] = uuid.7
        uuidBytes[8] = uuid.8; uuidBytes[9] = uuid.9; uuidBytes[10] = uuid.10; uuidBytes[11] = uuid.11
        uuidBytes[12] = uuid.12; uuidBytes[13] = uuid.13; uuidBytes[14] = uuid.14; uuidBytes[15] = uuid.15
        buffer.append(Data(uuidBytes))

        // Offset (Int64BE)
        var offsetBE = offset.bigEndian
        buffer.append(Data(bytes: &offsetBE, count: 8))

        // Flags (UInt8) - bit 0 = isLastChunk
        let flags: UInt8 = isLastChunk ? 0x01 : 0x00
        buffer.append(flags)

        // SessionId (16 bytes UUID) - lie le chunk à la session
        let sessionTuple = sessionId.uuid
        var sessionBytes = [UInt8](repeating: 0, count: 16)
        sessionBytes[0] = sessionTuple.0; sessionBytes[1] = sessionTuple.1; sessionBytes[2] = sessionTuple.2; sessionBytes[3] = sessionTuple.3
        sessionBytes[4] = sessionTuple.4; sessionBytes[5] = sessionTuple.5; sessionBytes[6] = sessionTuple.6; sessionBytes[7] = sessionTuple.7
        sessionBytes[8] = sessionTuple.8; sessionBytes[9] = sessionTuple.9; sessionBytes[10] = sessionTuple.10; sessionBytes[11] = sessionTuple.11
        sessionBytes[12] = sessionTuple.12; sessionBytes[13] = sessionTuple.13; sessionBytes[14] = sessionTuple.14; sessionBytes[15] = sessionTuple.15
        buffer.append(Data(sessionBytes))

        // Data (raw, no encoding)
        buffer.append(data)

        return buffer
    }

    /// Décode un payload binaire.
    /// - Parameter data: Données complètes (header + chunk data)
    /// - Returns: BinaryFileChunkPayload décodé
    /// - Throws: Erreur si le format est invalide
    static func decode(_ data: Data) throws -> BinaryFileChunkPayload {
        guard data.count >= headerSize else {
            throw BinaryFileChunkError.invalidData("Données trop courtes : \(data.count) < \(headerSize)")
        }

        var offset = 0

        // Length (UInt32BE)
        let lengthData = data.subdata(in: offset..<offset+4)
        let length = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        offset += 4

        // Vérifier que la taille annoncée est raisonnable
        guard length >= 0 && length <= FrameCodec.maximumFrameSize else {
            throw BinaryFileChunkError.invalidData("Taille de chunk invalide : \(length)")
        }

        // TransferID (16 bytes)
        guard data.count >= offset + 16 else {
            throw BinaryFileChunkError.invalidData("Données trop courtes pour TransferID")
        }
        let uuidData = data.subdata(in: offset..<offset+16)
        let transferID = uuidData.withUnsafeBytes { bytes in
            let uuid = bytes.loadUnaligned(as: uuid_t.self)
            return UUID(uuid: uuid)
        }
        offset += 16

        // Offset (Int64BE)
        guard data.count >= offset + 8 else {
            throw BinaryFileChunkError.invalidData("Données trop courtes pour offset")
        }
        let offsetData = data.subdata(in: offset..<offset+8)
        let chunkOffset = Int64(bitPattern: offsetData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian })
        guard chunkOffset >= 0 else {
            throw BinaryFileChunkError.invalidData("Offset négatif")
        }
        offset += 8

        // Flags (UInt8)
        guard data.count > offset else {
            throw BinaryFileChunkError.invalidData("Données trop courtes pour flags")
        }
        let flags = data[offset]
        offset += 1
        let isLastChunk = (flags & 0x01) != 0

        // SessionId (16 bytes)
        guard data.count >= offset + 16 else {
            throw BinaryFileChunkError.invalidData("Données trop courtes pour SessionId")
        }
        let sessionData = data.subdata(in: offset..<offset+16)
        let sessionId = sessionData.withUnsafeBytes { bytes in
            let uuid = bytes.loadUnaligned(as: uuid_t.self)
            return UUID(uuid: uuid)
        }
        offset += 16

        // Vérifier qu'il y a assez de données pour le chunk
        guard data.count == offset + length else {
            throw BinaryFileChunkError.invalidData("Taille de données incohérente : \(data.count - offset) octets disponibles, \(length) attendus")
        }

        // Data
        let chunkData = data.subdata(in: offset..<offset+length)

        return BinaryFileChunkPayload(
            transferID: transferID,
            offset: chunkOffset,
            data: chunkData,
            isLastChunk: isLastChunk,
            sessionId: sessionId
        )
    }
}

extension BinaryFileChunkPayload {
    /// Encodage personnalisé : utilise le format binaire, pas JSON.
    /// Note : Cette implémentation est nécessaire pour satisfaire `Encodable`
    /// mais ne doit PAS être utilisée directement — passer par `MessageCodec.encodePayload`
    /// qui appelle `encode()` directement.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encode())
    }

    /// Décodage personnalisé : utilise le format binaire, pas JSON.
    /// Note : Cette implémentation est nécessaire pour satisfaire `Decodable`
    /// mais ne doit PAS être utilisée directement — passer par `MessageCodec.decodePayload`
    /// qui appelle `decode(_:)` directement.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        let payload = try BinaryFileChunkPayload.decode(data)
        self.transferID = payload.transferID
        self.offset = payload.offset
        self.data = payload.data
        self.isLastChunk = payload.isLastChunk
        self.sessionId = payload.sessionId
    }
}

enum BinaryFileChunkError: Error {
    case invalidData(String)
}
