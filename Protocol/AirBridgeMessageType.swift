//
//  AirBridgeMessageType.swift
//  AirBridge
//
//  Created by massi9106 on 23/07/2026.
//

import Foundation

enum AirBridgeMessageType: String, Codable, Sendable {
    case hello
    case acknowledgement

    case transferRequest
    case transferAccepted
    case transferRejected
    case transferCancelled

    case fileChunk
    case transferCompleted

    case transferSucceeded
    case transferFailed


    case resumeRequest
    case resumeAccepted

    case ping
    case pong
    case error

    case pairingRequest
    case pairingResponse

    /// Échange de clés Diffie-Hellman (ECDH P-256) pour dériver une clé
    /// symétrique de session : le récepteur répond par `keyExchangeAck`
    /// avec sa propre clé publique éphémère. Le `KeyExchangePayload`
    /// transporte la représentation brute de la clé publique
    /// (`P256.KeyAgreement.PublicKey.rawRepresentation`, 65 octets).
    case keyExchange
    case keyExchangeAck
}
