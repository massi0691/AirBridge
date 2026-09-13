//
//  AirBridgeMessage.swift
//  AirBridge
//
//  Created by massi9106 on 23/07/2026.
//

import Foundation

struct AirBridgeMessage: Codable, Sendable {

    let protocolVersion: Int
    let messageID: UUID
    let type: AirBridgeMessageType
    let sender: Device
    let payload: Data?

    /// Signature ECDSA P-256 du message par l'émetteur.
    ///
    /// Signe les octets du payload (s'il existe), ou une représentation
    /// canonique `(type, messageID)` quand le payload est `nil`. Permet
    /// au récepteur de vérifier que l'émetteur possède bien la clé privée
    /// associée à la clé publique annoncée dans `sender`.
    ///
    /// Les chunks de données ne sont PAS signés (un par octet) : la chaîne
    /// est protégée par un `transferCompleted` signé à la fin.
    let signature: Data?

    /// Charge utile binaire v2 déjà décodée (uniquement pour les
    /// `fileChunk` du protocole v2+).
    ///
    /// Présente **uniquement** quand le message a été reconstitué par
    /// `ConnectionManager.receivePayload` après un premier décodage
    /// binaire : les consommateurs en aval (`AirBridgeCore.onEvent`) la
    /// consultent directement plutôt que de re-décoder le `payload` brut
    /// (gain : on évite un `BinaryFileChunkPayload.decode` redondant sur
    /// chaque chunk, soit ~1 Mo de copies inutiles par gigaoctet).
    ///
    /// `nil` pour tous les autres types de messages, ou pour les chunks
    /// v1. Le champ n'est pas encodé dans la représentation JSON car
    /// seul le `payload` brut transite sur le réseau.
    let decodedBinaryChunk: BinaryFileChunkPayload?

    init(
        protocolVersion: Int = ProtocolCompatibility.currentVersion,
        messageID: UUID = UUID(),
        type: AirBridgeMessageType,
        sender: Device,
        payload: Data? = nil,
        signature: Data? = nil,
        decodedBinaryChunk: BinaryFileChunkPayload? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.type = type
        self.sender = sender
        self.payload = payload
        self.signature = signature
        self.decodedBinaryChunk = decodedBinaryChunk
    }
}
