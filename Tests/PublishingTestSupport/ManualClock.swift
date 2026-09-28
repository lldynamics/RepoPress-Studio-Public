import Foundation
import os

/// A monotonic clock whose sleepers run only when a test advances it.
/// `waitForSleepCount` lets a test register background tasks before advancing time.
public final class ManualClock: Clock, Sendable {
  public struct Instant: InstantProtocol {
    public typealias Duration = Swift.Duration

    fileprivate let offset: Duration

    public func advanced(by duration: Duration) -> Self {
      Self(offset: offset + duration)
    }

    public func duration(to other: Self) -> Duration {
      other.offset - offset
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private struct Sleeper: Sendable {
    let deadline: Instant
    let sequence: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private struct SleepObserver: Sendable {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct State: Sendable {
    var currentInstant = Instant(offset: .zero)
    var sleepers: [UUID: Sleeper] = [:]
    var activeSleepIDs: Set<UUID> = []
    var cancelledSleepIDs: Set<UUID> = []
    var sleepRequestCount = 0
    var nextSleeperSequence: UInt64 = 0
    var sleepObservers: [SleepObserver] = []
    var pendingSleepObservers: [SleepObserver] = []
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  public init() {}

  public var now: Instant {
    state.withLock { $0.currentInstant }
  }

  public var minimumResolution: Duration { .zero }

  public var pendingSleepCount: Int {
    state.withLock { $0.sleepers.count }
  }

  var pendingDeadlinesInWakeOrder: [Instant] {
    state.withLock { Self.orderedSleepers($0.sleepers).map { $0.1.deadline } }
  }

  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    let id = UUID()
    _ = state.withLock { $0.activeSleepIDs.insert(id) }
    defer {
      state.withLock {
        $0.activeSleepIDs.remove(id)
        $0.cancelledSleepIDs.remove(id)
      }
    }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let registration = state.withLock {
          state -> (cancelled: Bool, due: Bool, observers: [SleepObserver]) in
          if state.cancelledSleepIDs.contains(id) {
            return (true, false, [])
          }
          if state.currentInstant >= deadline {
            return (false, true, [])
          }
          state.nextSleeperSequence &+= 1
          state.sleepers[id] = Sleeper(
            deadline: deadline,
            sequence: state.nextSleeperSequence,
            continuation: continuation
          )
          state.sleepRequestCount += 1
          let ready =
            state.sleepObservers.filter { $0.count <= state.sleepRequestCount }
            + state.pendingSleepObservers.filter { $0.count <= state.sleepers.count }
          state.sleepObservers.removeAll { $0.count <= state.sleepRequestCount }
          state.pendingSleepObservers.removeAll { $0.count <= state.sleepers.count }
          return (false, false, ready)
        }
        for observer in registration.observers {
          observer.continuation.resume()
        }
        if registration.cancelled {
          continuation.resume(throwing: CancellationError())
        } else if registration.due {
          continuation.resume()
        }
      }
    } onCancel: {
      let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
        guard state.activeSleepIDs.contains(id) else { return nil }
        state.cancelledSleepIDs.insert(id)
        return state.sleepers.removeValue(forKey: id)?.continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  public func advance(by duration: Duration) {
    precondition(duration >= .zero, "ManualClock cannot move backwards")
    let ready = state.withLock { state -> [CheckedContinuation<Void, Error>] in
      state.currentInstant = state.currentInstant.advanced(by: duration)
      let dueIDs = Self.orderedSleepers(state.sleepers).filter {
        $0.1.deadline <= state.currentInstant
      }
      return dueIDs.compactMap { state.sleepers.removeValue(forKey: $0.0)?.continuation }
    }
    for continuation in ready {
      continuation.resume()
    }
  }

  private static func orderedSleepers(_ sleepers: [UUID: Sleeper]) -> [(UUID, Sleeper)] {
    sleepers.map { ($0.key, $0.value) }.sorted {
      if $0.1.deadline == $1.1.deadline {
        return $0.1.sequence < $1.1.sequence
      }
      return $0.1.deadline < $1.1.deadline
    }
  }

  /// Waits for the total number of registered sleeps, including cancelled ones.
  public func waitForSleepCount(_ count: Int) async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state -> Bool in
        if state.sleepRequestCount >= count { return true }
        state.sleepObservers.append(SleepObserver(count: count, continuation: continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }

  public func waitForPendingSleepCount(_ count: Int) async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state -> Bool in
        if state.sleepers.count >= count { return true }
        state.pendingSleepObservers.append(SleepObserver(count: count, continuation: continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }
}
