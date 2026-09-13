import XCTest
@testable import AirBridge

@MainActor
final class OutgoingTransferQueueTests: XCTestCase {
    private let peer = Device(
        id: UUID(),
        name: "Test device",
        model: "Test model",
        systemVersion: "Test OS"
    )

    func testEnqueueActivatesOnlyFirstEntry() {
        let queue = OutgoingTransferQueue()
        var activations: [UUID] = []
        queue.onActivate = { activations.append($0.id) }

        let first = makeEntry(fileName: "first")
        let second = makeEntry(fileName: "second")

        queue.enqueue(first)
        queue.enqueue(second)

        XCTAssertEqual(queue.activeEntry?.id, first.id)
        XCTAssertEqual(queue.queuedEntries.map(\.id), [second.id])
        XCTAssertEqual(activations, [first.id])
    }

    func testEntriesAreActivatedInFIFOOrder() {
        let queue = OutgoingTransferQueue()
        var activations: [UUID] = []
        queue.onActivate = { activations.append($0.id) }

        let entries = [
            makeEntry(fileName: "first"),
            makeEntry(fileName: "second"),
            makeEntry(fileName: "third")
        ]

        entries.forEach(queue.enqueue)
        XCTAssertEqual(queue.activeEntry?.id, entries[0].id)

        XCTAssertTrue(queue.finish(transferID: entries[0].id))
        XCTAssertTrue(queue.finish(transferID: entries[1].id))
        XCTAssertTrue(queue.finish(transferID: entries[2].id))

        XCTAssertEqual(activations, entries.map(\.id))
        XCTAssertNil(queue.activeEntry)
        XCTAssertTrue(queue.queuedEntries.isEmpty)
    }

    func testFinishingActiveEntryActivatesNextEntry() {
        let queue = OutgoingTransferQueue()
        var activations: [UUID] = []
        queue.onActivate = { activations.append($0.id) }

        let first = makeEntry(fileName: "first")
        let second = makeEntry(fileName: "second")
        queue.enqueue(first)
        queue.enqueue(second)

        XCTAssertTrue(queue.finish(transferID: first.id))

        XCTAssertEqual(queue.activeEntry?.id, second.id)
        XCTAssertTrue(queue.queuedEntries.isEmpty)
        XCTAssertEqual(activations, [first.id, second.id])
    }

    func testCancellingPendingEntryDoesNotActivateIt() {
        let queue = OutgoingTransferQueue()
        var activations: [UUID] = []
        queue.onActivate = { activations.append($0.id) }

        let first = makeEntry(fileName: "first")
        let second = makeEntry(fileName: "second")
        queue.enqueue(first)
        queue.enqueue(second)

        let cancelled = queue.cancel(transferID: second.id)

        XCTAssertEqual(cancelled?.id, second.id)
        XCTAssertEqual(queue.activeEntry?.id, first.id)
        XCTAssertTrue(queue.queuedEntries.isEmpty)
        XCTAssertEqual(activations, [first.id])
    }

    func testCancelAllClearsActiveAndPendingEntriesWithoutActivatingNext() {
        let queue = OutgoingTransferQueue()
        var activations: [UUID] = []
        queue.onActivate = { activations.append($0.id) }

        let entries = [
            makeEntry(fileName: "first"),
            makeEntry(fileName: "second"),
            makeEntry(fileName: "third")
        ]
        entries.forEach(queue.enqueue)

        let cancelled = queue.cancelAll()

        XCTAssertEqual(cancelled.map(\.id), [entries[1].id, entries[2].id, entries[0].id])
        XCTAssertNil(queue.activeEntry)
        XCTAssertTrue(queue.queuedEntries.isEmpty)
        XCTAssertEqual(activations, [entries[0].id])
    }

    func testDuplicateEnqueueDoesNotActivateOrDuplicateEntry() {
        let queue = OutgoingTransferQueue()
        var activationCount = 0
        queue.onActivate = { _ in activationCount += 1 }

        let entry = makeEntry(fileName: "same")
        queue.enqueue(entry)
        queue.enqueue(entry)

        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(queue.allEntries.map(\.id), [entry.id])
    }

    func testSelectingTwoFilesCreatesTwoDistinctQueuedEntries() {
        let queue = OutgoingTransferQueue()
        let entries = [
            makeEntry(fileName: "first"),
            makeEntry(fileName: "second")
        ]

        entries.forEach(queue.enqueue)

        XCTAssertEqual(queue.allEntries.map(\.id), [entries[0].id, entries[1].id])
        XCTAssertEqual(queue.activeEntry?.id, entries[0].id)
        XCTAssertEqual(queue.queuedEntries.map(\.fileName), ["second"])
    }

    func testSelectingThreeFilesPreservesFIFOOrder() {
        let queue = OutgoingTransferQueue()
        var activations: [UUID] = []
        queue.onActivate = { activations.append($0.id) }
        let entries = [
            makeEntry(fileName: "first"),
            makeEntry(fileName: "second"),
            makeEntry(fileName: "third")
        ]

        entries.forEach(queue.enqueue)
        XCTAssertEqual(queue.queuedEntries.map(\.id), [entries[1].id, entries[2].id])

        XCTAssertTrue(queue.finish(transferID: entries[0].id))
        XCTAssertTrue(queue.finish(transferID: entries[1].id))
        XCTAssertTrue(queue.finish(transferID: entries[2].id))

        XCTAssertEqual(activations, entries.map(\.id))
    }

    func testCancellingOnePendingFileLeavesOtherFilesQueuedInOrder() {
        let queue = OutgoingTransferQueue()
        let entries = [
            makeEntry(fileName: "first"),
            makeEntry(fileName: "second"),
            makeEntry(fileName: "third")
        ]
        entries.forEach(queue.enqueue)

        XCTAssertEqual(queue.cancel(transferID: entries[1].id)?.id, entries[1].id)
        XCTAssertEqual(queue.activeEntry?.id, entries[0].id)
        XCTAssertEqual(queue.queuedEntries.map(\.id), [entries[2].id])

        XCTAssertTrue(queue.finish(transferID: entries[0].id))
        XCTAssertEqual(queue.activeEntry?.id, entries[2].id)
    }

    func testDisconnectCleanupClearsActiveAndMultiplePendingFiles() {
        let queue = OutgoingTransferQueue()
        var activations: [UUID] = []
        queue.onActivate = { activations.append($0.id) }
        let entries = [
            makeEntry(fileName: "first"),
            makeEntry(fileName: "second"),
            makeEntry(fileName: "third")
        ]
        entries.forEach(queue.enqueue)

        let cancelled = queue.cancelAll()

        XCTAssertEqual(cancelled.map(\.id), [entries[1].id, entries[2].id, entries[0].id])
        XCTAssertNil(queue.activeEntry)
        XCTAssertTrue(queue.queuedEntries.isEmpty)
        XCTAssertEqual(activations, [entries[0].id])
    }

    private func makeEntry(fileName: String) -> OutgoingTransferQueue.Entry {
        OutgoingTransferQueue.Entry(
            peer: peer,
            fileName: fileName,
            fileSize: 1,
            contentType: "text/plain",
            fileURL: URL(fileURLWithPath: "/tmp/\(fileName)"),
            sourceFileURL: URL(fileURLWithPath: "/tmp/\(fileName)")
        )
    }
}
