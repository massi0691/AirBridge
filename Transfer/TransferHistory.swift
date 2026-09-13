import Foundation

struct TransferHistoryEntry: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let direction: TransferDirection
    let startDate: Date
    let endDate: Date
    let status: TransferStatus
    let remoteDeviceName: String
    let remoteDeviceType: String
    let fileType: String
    let fileCount: Int
    let transferSpeed: Double // Mo/s
    let sha256: String?
}

enum TransferDirection: String, Codable {
    case sent = "sent"
    case received = "received"
}

enum TransferStatus: String, Codable {
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}
