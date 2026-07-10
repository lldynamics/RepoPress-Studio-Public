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
