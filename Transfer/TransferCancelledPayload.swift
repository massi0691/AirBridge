//
//  TransferCancelledPayload.swift
//  AirBridge
//
//  Created by massi9106 on 07/08/2026.
//

import Foundation

struct TransferCancelledPayload: Codable, Sendable {
    let transferID: UUID
    let reason: String?
}
