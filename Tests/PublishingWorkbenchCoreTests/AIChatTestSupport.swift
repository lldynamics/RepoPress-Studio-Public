import Foundation
import XCTest
@testable import PublishingWorkbenchCore

actor RecordingAIChatTransport: AIChatStreamingTransport {
  private let data: Data
  private let statusCode: Int
  private let streamLines: [String]
  private let streamLineDelayNanoseconds: UInt64
  private let streamFinishesWithCancellation: Bool
  private(set) var lastRequest: URLRequest?
  private var requestCount = 0

  init(
    data: Data,
    statusCode: Int,
    streamLines: [String] = [],
    streamLineDelayNanoseconds: UInt64 = 0,
    streamFinishesWithCancellation: Bool = false
  ) {
    self.data = data
    self.statusCode = statusCode
    self.streamLines = streamLines
    self.streamLineDelayNanoseconds = streamLineDelayNanoseconds
    self.streamFinishesWithCancellation = streamFinishesWithCancellation
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    requestCount += 1

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
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
      headerFields: nil
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
