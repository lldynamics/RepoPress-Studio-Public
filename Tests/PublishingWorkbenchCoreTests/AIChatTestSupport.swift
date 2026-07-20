import Foundation
import XCTest
@testable import PublishingWorkbenchCore

actor RecordingAIChatTransport: AIChatStreamingTransport {
  private let data: Data
  private let statusCode: Int
  private let streamLines: [String]
  private let streamLineDelayNanoseconds: UInt64
  private let streamFinishesWithCancellation: Bool
  private let headerFields: [String: String]?
  private(set) var lastRequest: URLRequest?
  private var requestCount = 0

  init(
    data: Data,
    statusCode: Int,
    streamLines: [String] = [],
    streamLineDelayNanoseconds: UInt64 = 0,
    streamFinishesWithCancellation: Bool = false,
    headerFields: [String: String]? = nil
  ) {
    self.data = data
    self.statusCode = statusCode
    self.streamLines = streamLines
    self.streamLineDelayNanoseconds = streamLineDelayNanoseconds
    self.streamFinishesWithCancellation = streamFinishesWithCancellation
    self.headerFields = headerFields
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    requestCount += 1

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: headerFields
    )!
    return (data, response)
  }

  func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
    lastRequest = request
    requestCount += 1

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: headerFields
    )!
    let lines = streamLines
    let delay = streamLineDelayNanoseconds
    let finishesWithCancellation = streamFinishesWithCancellation
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for line in lines {
            if delay > 0 {
              try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            continuation.yield(line)
          }
          if finishesWithCancellation {
            continuation.finish(throwing: CancellationError())
            return
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    return (stream, response)
  }

  func capturedRequest() -> URLRequest? {
    lastRequest
  }

  func capturedRequestCount() -> Int {
    requestCount
  }
}

enum ScriptedAIChatTransportError: Error, Equatable, Sendable {
  case connectionLost
}

struct ScriptedAIChatStreamAttempt: Sendable {
  var statusCode: Int
  var headerFields: [String: String]?
  var lines: [String]
  var lineDelayNanoseconds: UInt64
  var terminalError: ScriptedAIChatTransportError?

  init(
    statusCode: Int = 200,
    headerFields: [String: String]? = nil,
    lines: [String] = [],
    lineDelayNanoseconds: UInt64 = 0,
    terminalError: ScriptedAIChatTransportError? = nil
  ) {
    self.statusCode = statusCode
    self.headerFields = headerFields
    self.lines = lines
    self.lineDelayNanoseconds = lineDelayNanoseconds
    self.terminalError = terminalError
  }
}

actor ScriptedAIChatStreamingTransport: AIChatStreamingTransport {
  private let attempts: [ScriptedAIChatStreamAttempt]
  private var requestCount = 0

  init(attempts: [ScriptedAIChatStreamAttempt]) {
    self.attempts = attempts
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCount += 1
    let attempt = attempt(at: requestCount - 1)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: attempt.statusCode,
      httpVersion: nil,
      headerFields: attempt.headerFields
    )!
    return (Data(), response)
  }

  func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
    requestCount += 1
    let attempt = attempt(at: requestCount - 1)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: attempt.statusCode,
      httpVersion: nil,
      headerFields: attempt.headerFields
    )!
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for line in attempt.lines {
            if attempt.lineDelayNanoseconds > 0 {
              try await Task.sleep(nanoseconds: attempt.lineDelayNanoseconds)
            }
            try Task.checkCancellation()
            continuation.yield(line)
          }
          if let terminalError = attempt.terminalError {
            continuation.finish(throwing: terminalError)
          } else {
            continuation.finish()
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, response)
  }

  func capturedRequestCount() -> Int {
    requestCount
  }

  private func attempt(at index: Int) -> ScriptedAIChatStreamAttempt {
    guard !attempts.isEmpty else { return ScriptedAIChatStreamAttempt() }
    return attempts[min(index, attempts.count - 1)]
  }
}

actor DelayedAIChatTransport: AIChatTransport {
  private let data: Data
  private let statusCode: Int
  private let delayNanoseconds: UInt64
  private var requestCount = 0

  init(data: Data, statusCode: Int, delayNanoseconds: UInt64) {
    self.data = data
    self.statusCode = statusCode
    self.delayNanoseconds = delayNanoseconds
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCount += 1
    try await Task.sleep(nanoseconds: delayNanoseconds)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (data, response)
  }

  func capturedRequestCount() -> Int {
    requestCount
  }
}

func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
