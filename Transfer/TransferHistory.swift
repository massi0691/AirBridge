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

/// Conformances `Equatable` (synthétisées : enums sans valeur
/// associée) — requises par les comparaisons
/// `historyEntry.direction == .sent` et `status == .completed` de
/// `TransferViewModel` ; sans elles elles ne compilent pas.
enum TransferDirection: String, Codable, Equatable {
    case sent = "sent"
    case received = "received"
}

enum TransferStatus: String, Codable, Equatable {
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}
