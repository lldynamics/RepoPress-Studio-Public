import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class LocalAIEngineDiscoveryServiceTests: XCTestCase {
  func testDiscoversFixedLoopbackEnginesAndNormalizesModels() async throws {
    let transport = RecordingLocalAIEngineDiscoveryTransport(responses: [
      "http://127.0.0.1:11434/api/tags": StubLocalAIResponse(
        body: #"{"models":[{"name":"zeta:latest"},{"name":" alpha "},{"name":"alpha"},{"model":"beta"}]}"#
      ),
      "http://127.0.0.1:1234/v1/models": StubLocalAIResponse(
        body: #"{"data":[{"id":"model-b"},{"id":"model-a"},{"id":"model-b"}]}"#
      ),
      "http://127.0.0.1:8000/v1/models": StubLocalAIResponse(
        body: #"{"data":[{"id":"Qwen/Qwen3"}]}"#
      ),
    ])
    let service = LocalAIEngineDiscoveryService(transport: transport)

    let results = await service.discoverAll()

    XCTAssertEqual(results.map(\.kind), [.ollama, .lmStudio, .vLLM])
    XCTAssertEqual(
      results.map(\.baseURL),
      [
        "http://127.0.0.1:11434/v1",
        "http://127.0.0.1:1234/v1",
        "http://127.0.0.1:8000/v1",
      ]
    )
    XCTAssertTrue(results.allSatisfy(\.isAvailable))
    XCTAssertEqual(results[0].models, ["alpha", "beta", "zeta:latest"])
    XCTAssertEqual(results[1].models, ["model-a", "model-b"])
    XCTAssertEqual(results[2].models, ["Qwen/Qwen3"])

    let requests = await transport.capturedRequests()
    XCTAssertEqual(
      Set(requests.compactMap { $0.url?.absoluteString }),
      Set([
        "http://127.0.0.1:11434/api/tags",
        "http://127.0.0.1:1234/v1/models",
        "http://127.0.0.1:8000/v1/models",
      ])
    )
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    XCTAssertTrue(requests.allSatisfy { $0.timeoutInterval == 1.5 })
    XCTAssertTrue(requests.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization") == nil
        && $0.value(forHTTPHeaderField: "X-API-Key") == nil
        && $0.value(forHTTPHeaderField: "Cookie") == nil
    })
  }

  func testSuccessfulEmptyModelListStillMarksEngineAvailable() async {
    let transport = RecordingLocalAIEngineDiscoveryTransport(responses: [
      "http://127.0.0.1:11434/api/tags": StubLocalAIResponse(body: #"{"models":[]}"#),
      "http://127.0.0.1:1234/v1/models": StubLocalAIResponse(body: #"{"data":[]}"#),
      "http://127.0.0.1:8000/v1/models": StubLocalAIResponse(body: #"{"data":[]}"#),
    ])

    let results = await LocalAIEngineDiscoveryService(transport: transport).discoverAll()

    XCTAssertTrue(results.allSatisfy(\.isAvailable))
    XCTAssertTrue(results.allSatisfy { $0.models.isEmpty })
    XCTAssertTrue(results.allSatisfy {
      $0.message == CoreL10n.text("本地服务可用，但未返回模型。")
    })
  }

  func testRejectsNonLoopbackResponseURL() async {
    let remoteURL = URL(string: "https://collector.example/models")
    let transport = RecordingLocalAIEngineDiscoveryTransport(
      responses: [:],
      fallback: StubLocalAIResponse(
        body: #"{"data":[{"id":"must-not-be-used"}]}"#,
        responseURL: remoteURL
      )
    )

    let results = await LocalAIEngineDiscoveryService(transport: transport).discoverAll()

    XCTAssertTrue(results.allSatisfy { !$0.isAvailable })
    XCTAssertTrue(results.allSatisfy { $0.models.isEmpty })
    XCTAssertTrue(results.allSatisfy {
      $0.message == CoreL10n.text("已阻止非本机探测响应。")
    })
  }

  func testRejectsOversizedInjectedResponse() async {
    let oversizedData = Data(
      repeating: 0x20,
      count: LocalAIEngineDiscoveryService.maximumResponseByteCount + 1
    )
    let transport = RecordingLocalAIEngineDiscoveryTransport(
      responses: [:],
      fallback: StubLocalAIResponse(data: oversizedData)
    )

    let results = await LocalAIEngineDiscoveryService(transport: transport).discoverAll()

    XCTAssertTrue(results.allSatisfy { !$0.isAvailable })
    XCTAssertTrue(results.allSatisfy {
      $0.message == CoreL10n.text("本地服务响应超过安全上限。")
    })
  }

  func testFailureMessagesDoNotExposeResponseBodyOrTransportError() async {
    let secret = "sk-super-secret-response-value"
    let statusTransport = RecordingLocalAIEngineDiscoveryTransport(
      responses: [:],
      fallback: StubLocalAIResponse(
        body: #"{"error":"sk-super-secret-response-value"}"#,
        statusCode: 500
      )
    )
    let statusResults = await LocalAIEngineDiscoveryService(
      transport: statusTransport
    ).discoverAll()

    XCTAssertTrue(statusResults.allSatisfy { !$0.message.contains(secret) })
    XCTAssertTrue(statusResults.allSatisfy {
      $0.message == CoreL10n.format("本地服务响应异常（HTTP %d）。", 500)
    })

    let failureResults = await LocalAIEngineDiscoveryService(
      transport: FailingLocalAIEngineDiscoveryTransport(secret: secret)
    ).discoverAll()
    XCTAssertTrue(failureResults.allSatisfy { !$0.message.contains(secret) })
    XCTAssertTrue(failureResults.allSatisfy {
      $0.message == CoreL10n.text("未检测到本地服务。")
    })
  }
}

private struct StubLocalAIResponse: Sendable {
  var data: Data
  var statusCode: Int
  var responseURL: URL?

  init(body: String, statusCode: Int = 200, responseURL: URL? = nil) {
    data = Data(body.utf8)
    self.statusCode = statusCode
    self.responseURL = responseURL
  }

  init(data: Data, statusCode: Int = 200, responseURL: URL? = nil) {
    self.data = data
    self.statusCode = statusCode
    self.responseURL = responseURL
  }
}

private actor RecordingLocalAIEngineDiscoveryTransport: LocalAIEngineDiscoveryTransport {
  private let responses: [String: StubLocalAIResponse]
  private let fallback: StubLocalAIResponse?
  private var requests: [URLRequest] = []

  init(
    responses: [String: StubLocalAIResponse],
    fallback: StubLocalAIResponse? = nil
  ) {
    self.responses = responses
    self.fallback = fallback
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard let requestURL = request.url,
          let stub = responses[requestURL.absoluteString] ?? fallback else {
      throw StubLocalAITransportError.missingResponse
    }
    let responseURL = stub.responseURL ?? requestURL
    let response = HTTPURLResponse(
      url: responseURL,
      statusCode: stub.statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )
    guard let response else {
      throw StubLocalAITransportError.invalidResponse
    }
    return (stub.data, response)
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}

private enum StubLocalAITransportError: Error, Sendable {
  case missingResponse
  case invalidResponse
}

private struct FailingLocalAIEngineDiscoveryTransport: LocalAIEngineDiscoveryTransport {
  var secret: String

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    throw SensitiveLocalAITransportError(secret: secret)
  }
}

private struct SensitiveLocalAITransportError: LocalizedError, Sendable {
  var secret: String

  var errorDescription: String? {
    "Transport failed with secret: \(secret)"
  }
}
