//
//  MessageCodec.swift
//  AirBridge
//
//  Created by massi9106 on 23/07/2026.
//

import Foundation

// Import types from same module
// AirBridgeMessage, AirBridgeMessageType, ProtocolCompatibility, BinaryFileChunkPayload are in the same target

struct MessageCodec {

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func encode(_ message: AirBridgeMessage) throws -> Data {
        try encoder.encode(message)
    }

    func decode(_ data: Data) throws -> AirBridgeMessage {
        try decoder.decode(
            AirBridgeMessage.self,
            from: data
        )
    }

    /// Encode un payload selon la version du protocole.
    /// Pour fileChunk en v2+, utilise le format binaire.
    func encodePayload<T: Encodable>(
        _ payload: T,
        protocolVersion: Int = ProtocolCompatibility.currentVersion
    ) throws -> Data {
        // fileChunk en v2+ : format binaire
        if protocolVersion >= 2,
           let binaryChunk = payload as? BinaryFileChunkPayload {
            return binaryChunk.encode()
        }
        // Autres payloads ou v1 : JSON standard
        return try encoder.encode(payload)
    }

    /// Décode un payload selon la version du protocole et le type de message.
    /// Pour fileChunk en v2+, utilise le format binaire.
    func decodePayload<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        protocolVersion: Int = ProtocolCompatibility.currentVersion,
        messageType: AirBridgeMessageType? = nil
    ) throws -> T {
        // fileChunk en v2+ : format binaire
        if protocolVersion >= 2,
           messageType == .fileChunk,
           type == BinaryFileChunkPayload.self {
            let binaryChunk = try BinaryFileChunkPayload.decode(data)
            return binaryChunk as! T
        }
        // Autres payloads ou v1 : JSON standard
        return try decoder.decode(
            type,
            from: data
        )
    }


}
