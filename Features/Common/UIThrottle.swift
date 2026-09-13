//
//  UIThrottle.swift
//  AirBridge
//
//  Throttle helper for high-frequency Core updates.
//
//  The Core can publish transfer state at > 100 Hz during an active
//  transfer. A naive `@Observable` ViewModel that re-projects on every
//  read forces SwiftUI to re-diff the row at 60 Hz minimum, which is
//  wasteful and can drop frames on lower-end devices.
//
//  `UIThrottle` collapses a stream of values into a single republish
//  per `interval`, while still passing through:
//   - terminal values (transfers entering a final state) immediately,
//   - the most recent value once the stream goes quiet.
//
//  The throttle is uni-directionnel : it never invents a value, it
//  only delays or coalesces what the producer emits.
//
//  Usage:
//      let throttle = UIThrottle<Int>(interval: 0.1)
//      for await version in throttle.stream {
//          // republish
//      }
//      throttle.submit(42)   // delivered on the next tick
//      throttle.flush()      // delivered immediately
//

import Foundation

/// Coalesces a high-frequency stream of values into a lower-frequency
/// republish, used to dampen Core → UI repaint storms.
///
/// `Value` is intentionally not constrained to `Equatable` here — the
/// caller is the one deciding what "the value didn't change" means,
/// and our coalescing is done purely on time, not on equality. (If
/// the caller wants to skip duplicates, they can compare in their own
/// `for await` loop.)
@MainActor
final class UIThrottle<Value> {

    /// Last value the producer submitted. Always the freshest input,
    /// even before `value` has caught up to it.
    private var pending: Value?

    /// Last value the consumer observed through `value`. May lag behind
    /// `pending` while the throttle window is active.
    private(set) var value: Value?

    /// Minimum time between two republishes. 100 ms ≈ 10 Hz, the
    /// budget the transfer screen promises in its doc comment.
    let interval: TimeInterval

    /// When the next republish is allowed. Republishes before this
    /// instant are coalesced into the next allowed tick.
    private var nextAllowedAt: Date = .distantPast

    /// Active republish task. Cancelled and rescheduled on every
    /// `submit(_:)` so we always serve the freshest pending value.
    private var pendingTask: Task<Void, Never>?

    /// Stream of republishes. The consumer iterates it in a
    /// `for await` loop. One value per coalesced republish, plus
    /// one per `flush()`.
    let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
        var capturedContinuation: AsyncStream<Value>.Continuation!
        self.stream = AsyncStream<Value> { cont in
            capturedContinuation = cont
        }
        self.continuation = capturedContinuation
    }

    /// Submit a new value. If `interval` has elapsed since the last
    /// republish, the value is published immediately. Otherwise it
    /// is scheduled for the next allowed tick, replacing any value
    /// already pending.
    func submit(_ new: Value) {
        pending = new
        let now = Date()
        if now >= nextAllowedAt {
            republish(now: now)
        } else {
            scheduleRepublish(at: nextAllowedAt)
        }
    }

    /// Force the pending value to be republished on the next runloop
    /// tick, bypassing the interval. Used for terminal values (the
    /// final 100 % of a transfer, a `.cancelled` / `.failed` state)
    /// that the user must see immediately.
    func flush() {
        let now = Date()
        republish(now: now)
    }

    // MARK: - Private

    private func republish(now: Date) {
        nextAllowedAt = now.addingTimeInterval(interval)
        pendingTask?.cancel()
        pendingTask = nil
        guard let pending else { return }
        value = pending
        continuation.yield(pending)
    }

    private func scheduleRepublish(at date: Date) {
        pendingTask?.cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.republish(now: Date())
            }
        }
    }
}
