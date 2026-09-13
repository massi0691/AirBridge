//
//  AirBridgeSession.swift
//  AirBridge
//
//  Created by massi9106 on 26/07/2026.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class AirBridgeSession: Identifiable {

    enum Direction {
        case incoming
        case outgoing
    }

    enum State {
        case connecting
        case ready
        case waiting
        case failed
        case disconnected
    }

    let id: UUID
    let connection: NWConnection
    let direction: Direction
    let createdAt: Date

    private(set) var peer: Device?
    private(set) var state: State
    private(set) var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        connection: NWConnection,
        direction: Direction,
        peer: Device? = nil
    ) {
        self.id = id
        self.connection = connection
        self.direction = direction
        self.peer = peer
        self.state = .connecting
        self.createdAt = Date()
        self.lastActivityAt = Date()
    }

    func identifyPeer(_ device: Device) {
        peer = device
        touch()
    }

    func updateState(_ newState: State) {
        state = newState
        touch()
    }

    func touch() {
        lastActivityAt = Date()
    }
}
