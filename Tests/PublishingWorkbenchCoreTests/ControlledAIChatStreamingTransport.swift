import Foundation
import PublishingAICore

actor ControlledAIChatStreamingTransport: AIChatStreamingTransport {
  enum WaitError: Error, Equatable {
    case dataRequestUnsupported
    case invalidResponse
    case missingRequestURL
    case requestTimedOut
    case requestStreamEnded
  }

  private let statusCode: Int
  private let streamLines: [String]
  private let requestEvents: AsyncStream<Void>
  private let requestContinuation: AsyncStream<Void>.Continuation
  private let responseReleaseEvents: AsyncStream<Void>
  private let responseReleaseContinuation: AsyncStream<Void>.Continuation
  private var responseReleased = false
  private(set) var requestCount = 0
  private(set) var lastRequest: URLRequest?

  init(statusCode: Int = 200, streamLines: [String]) {
    self.statusCode = statusCode
    self.streamLines = streamLines
    (requestEvents, requestContinuation) = AsyncStream<Void>.makeStream()
    (responseReleaseEvents, responseReleaseContinuation) = AsyncStream<Void>.makeStream()
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    throw WaitError.dataRequestUnsupported
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    lastRequest = request
    requestCount += 1
    requestContinuation.yield(())

    if !responseReleased {
      for await _ in responseReleaseEvents {
        break
      }
    }
    try Task.checkCancellation()

    guard let url = request.url else {
      throw WaitError.missingRequestURL
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
      )
    else {
      throw WaitError.invalidResponse
    }
    let lines = streamLines
    let stream = AsyncThrowingStream<String, Error> { continuation in
      for line in lines {
        continuation.yield(line)
      }
      continuation.finish()
    }
    return (stream, response)
  }

  func waitForRequest(timeoutNanoseconds: UInt64) async throws {
    if requestCount > 0 { return }
    let events = requestEvents
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in events {
          try Task.checkCancellation()
          return
        }
        try Task.checkCancellation()
        throw WaitError.requestStreamEnded
      }
      group.addTask {
        try await Task.sleep(nanoseconds: timeoutNanoseconds)
        throw WaitError.requestTimedOut
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  func releaseResponse() {
    responseReleased = true
    responseReleaseContinuation.yield(())
  }

  func capturedRequest() -> URLRequest? {
    lastRequest
  }
}

/// The test controls the first stream's interruption after the request has
/// crossed the transport boundary, without relying on a wall-clock delay.
actor InterruptibleAIChatStreamingTransport: AIChatStreamingTransport {
  private let requestEvents: AsyncStream<Void>
  private let requestContinuation: AsyncStream<Void>.Continuation
  private var firstResponse: AsyncThrowingStream<String, Error>.Continuation?
  private(set) var requestCount = 0
  private let pausesBeforeSending: Bool
  private let sendGate: AsyncStream<Void>
  private let sendGateContinuation: AsyncStream<Void>.Continuation

  init(pausesBeforeSending: Bool = false) {
    self.pausesBeforeSending = pausesBeforeSending
    (sendGate, sendGateContinuation) = AsyncStream<Void>.makeStream()
    (requestEvents, requestContinuation) = AsyncStream<Void>.makeStream()
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    throw ControlledAIChatStreamingTransport.WaitError.dataRequestUnsupported
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    if pausesBeforeSending {
      requestContinuation.yield(())
      for await _ in sendGate { break }
    }
    try Task.checkCancellation()
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil, headerFields: nil
      )
    else { throw ControlledAIChatStreamingTransport.WaitError.invalidResponse }
    requestCount += 1
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    if requestCount == 1 {
      firstResponse = continuation
      continuation.yield(#"data: {"choices":[{"delta":{"content":"partial"}}]}"#)
      continuation.yield("")
    } else {
      continuation.yield(
        #"data: {"choices":[{"delta":{"content":"partial complete"},"finish_reason":"stop"}]}"#
      )
      continuation.yield("")
      continuation.finish()
    }
    requestContinuation.yield(())
    return (stream, response)
  }

  func waitForFirstRequest() async throws {
    if requestCount > 0 { return }
    let events = requestEvents
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

  func releaseSendGate() {
    sendGateContinuation.yield(())
    sendGateContinuation.finish()
  }

  func publishCheckpoint() {
    firstResponse?.yield(
      #"data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#
    )
    firstResponse?.yield("")
  }

  func interruptFirstResponse() {
    firstResponse?.finish(throwing: URLError(.networkConnectionLost))
    firstResponse = nil
  }
}
