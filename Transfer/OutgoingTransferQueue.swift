//
//  OutgoingTransferQueue.swift
//  AirBridge
//

import Foundation
import Observation

@MainActor
@Observable
final class OutgoingTransferQueue {

    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let peer: Device
        let fileName: String
        let fileSize: Int64
        let contentType: String?
        let fileURL: URL
        let sourceFileURL: URL
        var batchID: UUID?
        var batchFolderName: String?
        var relativePath: String?

        init(
            id: UUID = UUID(),
            peer: Device,
            fileName: String,
            fileSize: Int64,
            contentType: String?,
            fileURL: URL,
            sourceFileURL: URL,
            batchID: UUID? = nil,
            batchFolderName: String? = nil,
            relativePath: String? = nil
        ) {
            self.id = id
            self.peer = peer
            self.fileName = fileName
            self.fileSize = fileSize
            self.contentType = contentType
            self.fileURL = fileURL
            self.sourceFileURL = sourceFileURL
            self.batchID = batchID
            self.batchFolderName = batchFolderName
            self.relativePath = relativePath
        }
    }

    private(set) var entries: [Entry] = []
    private var activeEntryID: UUID?

    var onActivate: ((Entry) -> Void)?

    var activeEntry: Entry? {
        guard let activeEntryID else { return nil }
        return entries.first { $0.id == activeEntryID }
    }

    var queuedEntries: [Entry] {
        entries.filter { $0.id != activeEntryID }
    }

    var allEntries: [Entry] {
        entries
    }

    func enqueue(_ entry: Entry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }

        entries.append(entry)

        if activeEntryID == nil {
            activate(entry.id)
        }
    }

    private func activate(_ entryID: UUID) {
        activeEntryID = entryID
        if let entry = entries.first(where: { $0.id == entryID }) {
            onActivate?(entry)
        }
    }

    @discardableResult
    func finish(transferID: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == transferID }) else {
            return false
        }

        entries.remove(at: index)

        if activeEntryID == transferID {
            activeEntryID = nil
            if let next = entries.first {
                activate(next.id)
            }
        }

        return true
    }

    func cancel(transferID: UUID) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == transferID }) else {
            return nil
        }

        let entry = entries.remove(at: index)

        if activeEntryID == transferID {
            activeEntryID = nil
            if let next = entries.first {
                activate(next.id)
            }
        }

        return entry
    }

    func cancelAll() -> [Entry] {
        let queued = entries.filter { $0.id != activeEntryID }
        let active = activeEntryID.flatMap { id in entries.first { $0.id == id } }
        let cancelled = queued + (active.map { [$0] } ?? [])
        entries.removeAll()
        activeEntryID = nil
        return cancelled
    }

    func contains(_ transferID: UUID) -> Bool {
        entries.contains { $0.id == transferID }
    }

    func isActive(_ transferID: UUID) -> Bool {
        activeEntryID == transferID
    }
}