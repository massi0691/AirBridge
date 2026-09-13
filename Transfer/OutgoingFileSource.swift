//
//  OutgoingFileSource.swift
//  AirBridge
//

import Foundation

struct OutgoingFileSource: Sendable {
    let transferID: UUID
    let url: URL
    let protectedOriginalURL: URL?
    let isTemporary: Bool
}
