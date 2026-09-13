//
//  TransfertTimeoutManager.swift
//  AirBridge
//
//  Created by massi9106 on 07/08/2026.
//

import Foundation

@MainActor
final class TransferTimeoutManager {

    enum TimeoutKind {
        case approval
        case transferActivity
        case completionConfirmation
    }

    struct TimeoutEntry {
        let kind: TimeoutKind
        let task: Task<Void, Never>
    }

    private var tasks: [UUID: TimeoutEntry] = [:]

    func start(
        transferID: UUID,
        kind: TimeoutKind,
        duration: Duration,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        cancel(transferID: transferID)

        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: duration)

                guard !Task.isCancelled else {
                    return
                }

                onTimeout()

            } catch {
                // Task annulée : rien à faire.
            }
        }

        tasks[transferID] = TimeoutEntry(
            kind: kind,
            task: task
        )
    }

    func cancel(
        transferID: UUID
    ) {
        tasks[transferID]?.task.cancel()
        tasks[transferID] = nil
    }

    func cancelAll() {
        for (_, entry) in tasks {
            entry.task.cancel()
        }

        tasks.removeAll()
    }
}
