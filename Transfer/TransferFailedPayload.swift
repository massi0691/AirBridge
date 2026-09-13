//
//  TransferFailedPayload.swift
//  AirBridge
//
//  Created by massi9106 on 02/08/2026.
//

import Foundation

struct TransferFailedPayload: Codable, Sendable {
    let transferID: UUID
    let reason: String
}
