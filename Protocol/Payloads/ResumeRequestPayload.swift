import Foundation

struct ResumeRequestPayload: Codable, Sendable {
    let transferID: UUID
    let offset: Int64
    let fileName: String
    let sha256: String
    let chunkSize: Int
    let receivedBytes: Int64
    let fileSize: Int64
    let protocolVersion: Int
}
