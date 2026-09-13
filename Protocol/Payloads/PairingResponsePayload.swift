import Foundation

struct PairingResponsePayload: Codable, Sendable {
    let peerID: UUID
    let peerName: String
    let publicKeyData: Data
    let challenge: Data
    let signature: Data
    let protocolVersion: Int
    let accepted: Bool
}