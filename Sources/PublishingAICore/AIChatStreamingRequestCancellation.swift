import Foundation
import os

/// Cancels the producer directly, including while a send waits to enter a
/// transport actor. Registration also observes revocation that happened first.
package final class AIChatStreamingRequestCancellation: Sendable {
  private struct State {
    var cancelled = false
    var finished = false
    var task: Task<Void, Never>?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  package init() {}

  package func register(_ task: Task<Void, Never>) {
    let cancel = state.withLock { state in
      if state.cancelled { return true }
      if !state.finished { state.task = task }
      return false
    }
    if cancel { task.cancel() }
  }

  package func cancel() {
    let task = state.withLock { state in
      state.cancelled = true
      let task = state.task
      state.task = nil
      return task
    }
    task?.cancel()
  }

  package func finish() {
    state.withLock { state in
      state.finished = true
      state.task = nil
    }
  }
}
