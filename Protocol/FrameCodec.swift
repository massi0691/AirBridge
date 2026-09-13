//
//  FrameCodec.swift
//  AirBridge
//
//  Created by massi9106 on 23/07/2026.
//

import Foundation

enum FrameCodecError: Error {
    case invalidHeader
    case frameTooLarge
}

/// `nonisolated` : codec pur sans état, utilisé depuis les files du
/// framework Network comme depuis le cœur `@MainActor`. L'isolation par
/// défaut du projet (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) rendrait
/// sinon ses constantes inaccessibles depuis les closures d'envoi/réception.
nonisolated struct FrameCodec {

    nonisolated static let headerSize = 4
    nonisolated static let maximumFrameSize = 10 * 1024 * 1024

    func encode(_ payload: Data) throws -> Data {
        guard payload.count <= Self.maximumFrameSize else {
            throw FrameCodecError.frameTooLarge
        }

        var length = UInt32(payload.count).bigEndian
        let header = Data(
            bytes: &length,
            count: MemoryLayout<UInt32>.size
        )

        return header + payload
    }

    func decodeLength(from header: Data) throws -> Int {
        guard header.count == Self.headerSize else {
            throw FrameCodecError.invalidHeader
        }

        // `loadUnaligned` et non `load` : rien ne garantit que le tampon d'un
        // `Data` soit aligné sur quatre octets — il peut être une tranche
        // d'un tampon plus grand. `load` sur une adresse non alignée est un
        // comportement indéfini, qui passe inaperçu jusqu'au jour où il
        // plante.
        let value = header.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: UInt32.self)
        }

        let length = Int(UInt32(bigEndian: value))

        guard length <= Self.maximumFrameSize else {
            throw FrameCodecError.frameTooLarge
        }

        return length
    }
}
