//
//  TransferAcceptedPayload.swift
//  AirBridge
//
//  Created by massi9106 on 24/07/2026.
//

import Foundation

struct TransferRejectedPayload: Codable, Sendable {
    let transferID: UUID
    let reason: String?
}
