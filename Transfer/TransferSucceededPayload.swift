//
//  TransferSucceededPayload.swift
//  AirBridge
//
//  Created by massi9106 on 02/08/2026.
//

import Foundation

struct TransferSucceededPayload: Codable, Sendable {
    let transferID: UUID
    let receivedBytes: Int64
}
