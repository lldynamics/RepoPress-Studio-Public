import Foundation
import XCTest

@testable import PublishingAICore

final class AIChatTransportContractsTests: XCTestCase {
  func testTransportLimitsMatchBoundedResponsePolicy() {
    XCTAssertEqual(AIChatTransportLimits.maximumResponseByteCount, 16_777_216)
    XCTAssertEqual(
      AIChatTransportLimits.maximumStreamingResponseByteCount,
      33_554_432
    )
    XCTAssertEqual(
      AIChatTransportLimits.maximumStreamingLineByteCount,
      1_048_576
    )
  }

  func testActorTransportSatisfiesDataAndStreamingContracts() async throws {
    let expectedBody = Data(#"{"message":"ok"}"#.utf8)
    let expectedLines = ["data: first", "", "data: second"]
    let fake = FakeAIChatTransport(responseBody: expectedBody, streamLines: expectedLines)
    let dataTransport: any AIChatTransport = fake
    let streamingTransport: any AIChatStreamingTransport = fake
    let url = try XCTUnwrap(URL(string: "https://example.invalid/v1/chat/completions"))
    let request = URLRequest(url: url)

    let (body, dataResponse) = try await dataTransport.data(for: request)
    let (lineStream, streamingResponse) = try await streamingTransport.lines(for: request)
    var receivedLines: [String] = []
    for try await line in lineStream {
      receivedLines.append(line)
    }

    XCTAssertEqual(body, expectedBody)
    XCTAssertEqual(dataResponse.url, url)
    XCTAssertEqual(receivedLines, expectedLines)
    XCTAssertEqual(streamingResponse.url, url)
  }
}

private actor FakeAIChatTransport: AIChatTransport, AIChatStreamingTransport {
  private let responseBody: Data
  private let streamLines: [String]

  init(responseBody: Data, streamLines: [String]) {
    self.responseBody = responseBody
    self.streamLines = streamLines
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    (
      responseBody,
      try response(for: request, expectedContentLength: responseBody.count)
    )
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    let streamLines = self.streamLines
    let stream = AsyncThrowingStream<String, Error> { continuation in
      for line in streamLines {
        continuation.yield(line)
      }
      continuation.finish()
    }
    return (stream, try response(for: request, expectedContentLength: -1))
  }

  private func response(
    for request: URLRequest,
    expectedContentLength: Int
  ) throws -> URLResponse {
    guard let url = request.url else {
      throw URLError(.badURL)
    }
    return URLResponse(
      url: url,
      mimeType: "application/json",
      expectedContentLength: expectedContentLength,
      textEncodingName: "utf-8"
    )
  }
}
