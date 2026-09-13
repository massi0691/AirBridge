//
//  PendingTransferRequest.swift
//  AirBridge
//
//  Created by massi9106 on 24/07/2026.
//

import Foundation
import Network

struct PendingTransferRequest: Identifiable {
    let sender: Device
    let request: TransferRequestPayload
    let connection: NWConnection

    var id: UUID {
        request.transferID
    }
}

struct PendingTransferBatch: Identifiable {
    let id: UUID
    let sender: Device
    let connection: NWConnection
    private(set) var requests: [PendingTransferRequest]

    var fileCount: Int { requests.count }
    var totalSize: Int64 { requests.reduce(0) { $0 + $1.request.fileSize } }
    var fileNames: [String] { requests.map { $0.request.fileName } }
    var transferIDs: [UUID] { requests.map { $0.request.transferID } }

    init(request: PendingTransferRequest) {
        id = UUID()
        sender = request.sender
        connection = request.connection
        requests = [request]
    }

    /// Indique si la demande provient du même expéditeur et de la même
    /// connexion, donc si elle peut rejoindre ce lot d'autorisation.
    func accepts(_ request: PendingTransferRequest) -> Bool {
        request.sender.id == sender.id
            && request.connection === connection
    }

    mutating func append(_ request: PendingTransferRequest) {
        guard accepts(request),
              !requests.contains(where: { $0.id == request.id }) else {
            return
        }
        requests.append(request)
    }

    mutating func remove(transferIDs: Set<UUID>) {
        requests.removeAll { transferIDs.contains($0.id) }
    }
}
