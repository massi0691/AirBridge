import Foundation

struct ResumeAcceptedPayload: Codable, Sendable {
    let transferID: UUID
    let offset: Int64
    let fileName: String
    let sha256: String
    let chunkSize: Int
    let fileSize: Int64
}
