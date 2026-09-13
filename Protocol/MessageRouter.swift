//
//  MessageRouter.swift
//  AirBridge
//
//  Created by massi9106 on 23/07/2026.
//

import Foundation
import Network

@MainActor
final class MessageRouter {

    enum Event {
        case hello(AirBridgeMessage, NWConnection)

        case acknowledgement(AirBridgeMessage, NWConnection)

        case pairingRequest(AirBridgeMessage, NWConnection)
        case pairingResponse(AirBridgeMessage, NWConnection)

        case keyExchange(AirBridgeMessage, NWConnection)
        case keyExchangeAck(AirBridgeMessage, NWConnection)

        case transferRequest(AirBridgeMessage, NWConnection)

        case transferAccepted(AirBridgeMessage,NWConnection)

        case transferRejected(AirBridgeMessage,NWConnection)

        case fileChunk(AirBridgeMessage,NWConnection)

        case transferCompleted(AirBridgeMessage,NWConnection)

        case transferSucceeded(AirBridgeMessage,NWConnection)

        case transferFailed(AirBridgeMessage,NWConnection)
        case transferCancelled(AirBridgeMessage,NWConnection)
        case resumeRequest(AirBridgeMessage, NWConnection)
        case resumeAccepted(AirBridgeMessage, NWConnection)

        case unknown(AirBridgeMessage, NWConnection)
    }

    var onEvent: ((Event) -> Void)?

    func route(
        _ message: AirBridgeMessage,
        on connection: NWConnection
    ) {
        switch message.type {
        case .hello:
            onEvent?(.hello(message, connection))

        case .acknowledgement:
            onEvent?(.acknowledgement(message, connection))

        case .pairingRequest:
            onEvent?(.pairingRequest(message, connection))

        case .pairingResponse:
            onEvent?(.pairingResponse(message, connection))

        case .keyExchange:
            onEvent?(.keyExchange(message, connection))

        case .keyExchangeAck:
            onEvent?(.keyExchangeAck(message, connection))

        case .transferRequest:
            onEvent?(.transferRequest(message, connection))
       
        case .transferAccepted:
            onEvent?(.transferAccepted(message, connection))
        
        case .transferRejected:
            onEvent?(.transferRejected(message, connection))
            
        case .transferCancelled:
            onEvent?(.transferCancelled(message, connection))
        
        case .fileChunk:
            onEvent?(.fileChunk(message, connection))
            
        case .transferCompleted:
            onEvent?(.transferCompleted(message, connection))
          
        case .transferSucceeded:
            onEvent?(.transferSucceeded(message, connection))
            
        case .transferFailed:
            onEvent?(.transferFailed(message, connection))

        case .resumeRequest:
            onEvent?(.resumeRequest(message, connection))

        case .resumeAccepted:
            onEvent?(.resumeAccepted(message, connection))

        default:
            onEvent?(.unknown(message, connection))
        }
    }
}
