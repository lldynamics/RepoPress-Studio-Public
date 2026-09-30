import Foundation
import PublishingAICore
import os

final class AIChatRequestTestClock: Sendable {
  private let offset = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

  func now() -> Date { offset.withLock { Date().addingTimeInterval($0) } }
  func advance(by seconds: TimeInterval) { offset.withLock { $0 += seconds } }
}

/// An event-driven suspension point before dispatch or while reading a response.
actor AIChatRequestBoundaryGate {
  private let enteredEvents: AsyncStream<Void>
  private let enteredContinuation: AsyncStream<Void>.Continuation
  private let releaseEvents: AsyncStream<Void>
  private let releaseContinuation: AsyncStream<Void>.Continuation
  private var entered = false
  private(set) var observedCancellation = false

  init() {
    (enteredEvents, enteredContinuation) = AsyncStream.makeStream()
    (releaseEvents, releaseContinuation) = AsyncStream.makeStream()
  }

  func suspend() async throws {
    entered = true
    enteredContinuation.yield(())
    for await _ in releaseEvents { break }
    observedCancellation = Task.isCancelled
    try Task.checkCancellation()
  }

  func release() {
    releaseContinuation.yield(())
    releaseContinuation.finish()
  }

  func waitUntilEntered() async throws {
    if entered { return }
    let events = enteredEvents
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in events { return }
        throw ControlledAIChatStreamingTransport.WaitError.requestStreamEnded
      }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw ControlledAIChatStreamingTransport.WaitError.requestTimedOut
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }
}

actor AIChatBoundaryCompleteTransport: AIChatTransport {
  private let initialFailure: Bool
  let dispatchGate: AIChatRequestBoundaryGate?
  let responseGate: AIChatRequestBoundaryGate?
  private(set) var requestCount = 0

  init(
    dispatchGate: AIChatRequestBoundaryGate? = nil,
    responseGate: AIChatRequestBoundaryGate? = nil,
    initialFailure: Bool = false
  ) {
    self.initialFailure = initialFailure
    self.dispatchGate = dispatchGate
    self.responseGate = responseGate
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let isInitialFailure = initialFailure && requestCount == 0
    if !isInitialFailure { try await dispatchGate?.suspend() }
    try Task.checkCancellation()
    requestCount += 1
    if isInitialFailure {
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
      )!
      return (Data(#"{"error":"temporarily unavailable"}"#.utf8), response)
    }
    try await responseGate?.suspend()
    try Task.checkCancellation()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
    )!
    return (
      Data(#"{"choices":[{"message":{"role":"assistant","content":"complete"}}]}"#.utf8),
      response
    )
  }
}

actor AIChatPartialFailureTransport: AIChatStreamingTransport {
  private let statusCode: Int?
  private let clock: AIChatRequestTestClock?
  private(set) var requestCount = 0

  init(statusCode: Int? = nil, expiring clock: AIChatRequestTestClock? = nil) {
    self.statusCode = statusCode
    self.clock = clock
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    throw ControlledAIChatStreamingTransport.WaitError.dataRequestUnsupported
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    try Task.checkCancellation()
    requestCount += 1
    let first = requestCount == 1
    let response = HTTPURLResponse(
      url: request.url!, statusCode: first ? 200 : statusCode ?? 500,
      httpVersion: nil, headerFields: first ? nil : ["Retry-After": "45"]
    )!
    let stream = AsyncThrowingStream<String, Error> { continuation in
      if first {
        continuation.yield(#"data: {"choices":[{"delta":{"content":"partial"}}]}"#)
        continuation.yield("")
        // All bytes are buffered in order. No wall-clock sleep is needed to
        // expire the authorization before the next continuation validation.
        clock?.advance(by: 3_600)
        continuation.finish(throwing: URLError(.networkConnectionLost))
      } else {
        continuation.yield(#"{"error":{"message":"continuation failed"}}"#)
        continuation.finish()
      }
    }
    return (stream, response)
  }
}
