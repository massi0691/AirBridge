import Foundation

struct PairingRequestPayload: Codable, Sendable {
    let peerID: UUID
    let peerName: String
    let publicKeyData: Data
    let challenge: Data
    let signature: Data
    let protocolVersion: Int
}