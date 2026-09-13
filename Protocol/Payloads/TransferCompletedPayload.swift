//
//  TransferCompletedPayload.swift
//  AirBridge
//
//  Created by massi9106 on 26/07/2026.
//

import Foundation

struct TransferCompletedPayload: Codable, Sendable {
    let transferID: UUID
    let totalBytes: Int64
    let sha256: String
}
