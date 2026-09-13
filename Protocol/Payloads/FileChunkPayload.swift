//
//  FileChunkPayload.swift
//  AirBridge
//
//  Created by massi9106 on 24/07/2026.
//

import Foundation

struct FileChunkPayload: Codable, Sendable {
    let transferID: UUID
    let offset: Int64
    let data: Data
    let isLastChunk: Bool
}
