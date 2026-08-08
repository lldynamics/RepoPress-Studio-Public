import Foundation

enum PersistentWindowCommandMenuDecision: Equatable {
  case noChange
  case install
  case remove
  case deferUntilTrackingEnds
}

struct PersistentWindowCommandMenuPolicy {
  static func decision(
    hasMainWindow: Bool,
    commandExists: Bool,
    isMenuTracking: Bool
  ) -> PersistentWindowCommandMenuDecision {
    let commandShouldExist = !hasMainWindow
    guard commandShouldExist != commandExists else {
      return .noChange
    }
    guard !isMenuTracking else {
      return .deferUntilTrackingEnds
    }
    return commandShouldExist ? .install : .remove
  }
}

struct WindowLifecycleRetrySchedule: Equatable {
  let token: Int
  let delay: TimeInterval
}

struct PersistentWindowCommandRequestState: Equatable {
  private(set) var isPending = false
  private(set) var isScheduled = false
  private(set) var retryCount = 0
  private var nextRetryToken = 0
  private var activeRetryToken: Int?

  mutating func request() -> Bool {
    isPending = true
    return scheduleIfNeeded()
  }

  mutating func beginScheduledAttempt() -> Bool {
    guard isScheduled else { return false }
    isScheduled = false
    return isPending
  }

  mutating func markAttemptUnavailable() -> WindowLifecycleRetrySchedule? {
    guard isPending else { return nil }
    return scheduleRetryIfNeeded()
  }

  mutating func markCompleted() {
    isPending = false
    retryCount = 0
    activeRetryToken = nil
  }

  mutating func retryTimerFired(token: Int) -> Bool {
    guard activeRetryToken == token else { return false }
    activeRetryToken = nil
    return scheduleIfNeeded()
  }

  private mutating func scheduleIfNeeded() -> Bool {
    guard isPending,
          !isScheduled
    else {
      return false
    }
    isScheduled = true
    return true
  }

  private mutating func scheduleRetryIfNeeded() -> WindowLifecycleRetrySchedule? {
    guard activeRetryToken == nil else { return nil }
    nextRetryToken += 1
    let token = nextRetryToken
    activeRetryToken = token
    let delay = Self.retryDelay(for: retryCount)
    retryCount = min(retryCount + 1, 4)
    return WindowLifecycleRetrySchedule(token: token, delay: delay)
  }

  private static func retryDelay(for retryCount: Int) -> TimeInterval {
    let cappedRetryCount = min(max(retryCount, 0), 4)
    return min(0.1 * pow(2, Double(cappedRetryCount)), 1.0)
  }
}

struct MainWindowRestoreRequestState: Equatable {
  private(set) var isPending = false
  private(set) var isScheduled = false
  private(set) var isActionInFlight = false
  private(set) var retryCount = 0
  private var nextRetryToken = 0
  private var activeRetryToken: Int?

  mutating func request() -> Bool {
    isPending = true
    return scheduleIfNeeded()
  }

  mutating func actionBecameAvailable() -> Bool {
    guard isPending, !isActionInFlight else { return false }
    activeRetryToken = nil
    return scheduleIfNeeded()
  }

  mutating func beginScheduledAttempt() -> Bool {
    guard isScheduled else { return false }
    isScheduled = false
    return isPending && !isActionInFlight
  }

  mutating func markActionUnavailable() -> WindowLifecycleRetrySchedule? {
    guard isPending, !isActionInFlight else { return nil }
    return scheduleRetryIfNeeded()
  }

  mutating func markActionDispatched() {
    guard isPending else { return }
    isActionInFlight = true
    retryCount = 0
    activeRetryToken = nil
  }

  mutating func markCompleted() {
    isPending = false
    isActionInFlight = false
    retryCount = 0
    activeRetryToken = nil
  }

  mutating func retryTimerFired(token: Int) -> Bool {
    guard activeRetryToken == token,
          isPending,
          !isActionInFlight
    else {
      return false
    }
    activeRetryToken = nil
    return scheduleIfNeeded()
  }

  private mutating func scheduleIfNeeded() -> Bool {
    guard isPending,
          !isScheduled,
          !isActionInFlight
    else {
      return false
    }
    isScheduled = true
    return true
  }

  private mutating func scheduleRetryIfNeeded() -> WindowLifecycleRetrySchedule? {
    guard activeRetryToken == nil else { return nil }
    nextRetryToken += 1
    let token = nextRetryToken
    activeRetryToken = token
    let delay = Self.retryDelay(for: retryCount)
    retryCount = min(retryCount + 1, 4)
    return WindowLifecycleRetrySchedule(token: token, delay: delay)
  }

  private static func retryDelay(for retryCount: Int) -> TimeInterval {
    let cappedRetryCount = min(max(retryCount, 0), 4)
    return min(0.1 * pow(2, Double(cappedRetryCount)), 1.0)
  }
}
