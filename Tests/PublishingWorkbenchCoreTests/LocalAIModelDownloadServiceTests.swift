import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class LocalAIModelDownloadServiceTests: XCTestCase {
  func testPullPostsOnlyModelAndStreamsProgress() async throws {
    let transport = RecordingModelDownloadTransport(
      lines: [
        #"{"status":"pulling manifest"}"#,
        #"{"status":"downloading","completed":512,"total":1024}"#,
        #"{"status":"success"}"#,
      ]
    )
    let service = LocalAIModelDownloadService(transport: transport)

    let updates = try await collect(service.pull(modelID: "qwen3:8b"))
    let capturedRequest = await transport.request()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]

    XCTAssertEqual(request.url, LocalAIModelDownloadService.ollamaPullURL)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(payload?["model"] as? String, "qwen3:8b")
    XCTAssertEqual(payload?["stream"] as? Bool, true)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(updates.map(\.status), ["pulling manifest", "downloading", "success"])
    XCTAssertEqual(updates[1].fractionCompleted, 0.5)
    XCTAssertTrue(updates[2].isComplete)
  }

  func testRejectsUnsafeModelIdentifierBeforeOpeningATransport() async {
    let transport = RecordingModelDownloadTransport(lines: [#"{"status":"success"}"#])
    let service = LocalAIModelDownloadService(transport: transport)

    do {
      _ = try await collect(service.pull(modelID: "https://remote.example/model"))
      XCTFail("Expected the remote-looking model identifier to be rejected")
    } catch let error as LocalAIModelDownloadError {
      XCTAssertEqual(error, .invalidModelIdentifier)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let capturedRequest = await transport.request()
    XCTAssertNil(capturedRequest)
  }

  func testRejectsRedirectedOrIncompleteDownloadWithoutReportingSuccess() async {
    let remoteResponse = URL(string: "https://remote.example/api/pull")!
    let redirectTransport = RecordingModelDownloadTransport(
      lines: [#"{"status":"success"}"#],
      responseURL: remoteResponse
    )
    do {
      _ = try await collect(
        LocalAIModelDownloadService(transport: redirectTransport).pull(modelID: "qwen3"))
      XCTFail("Expected a non-loopback response to be rejected")
    } catch let error as LocalAIModelDownloadError {
      XCTAssertEqual(error, .unsafeResponse)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let incompleteTransport = RecordingModelDownloadTransport(lines: [#"{"status":"downloading"}"#])
    do {
      _ = try await collect(
        LocalAIModelDownloadService(transport: incompleteTransport).pull(modelID: "qwen3"))
      XCTFail("Expected a stream without success to fail")
    } catch let error as LocalAIModelDownloadError {
      XCTAssertEqual(error, .incompleteResponse)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testClassifiesOllamaErrorUpdatesWithoutExposingTheirRawText() async {
    let cases: [(line: String, expected: LocalAIModelDownloadError)] = [
      (#"{"error":"pull model manifest: model does not exist"}"#, .modelNotFound),
      (#"{"error":"write /models: no space left on device"}"#, .insufficientStorage),
      (#"{"error":"server rejected token sk-never-display"}"#, .serverFailure),
    ]

    for item in cases {
      do {
        _ = try await collect(
          LocalAIModelDownloadService(
            transport: RecordingModelDownloadTransport(lines: [item.line])
          ).pull(modelID: "qwen3")
        )
        XCTFail("Expected an Ollama error update")
      } catch let error as LocalAIModelDownloadError {
        XCTAssertEqual(error, item.expected)
        XCTAssertFalse(error.localizedDescription.contains("sk-never-display"))
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func collect(
    _ stream: AsyncThrowingStream<LocalAIModelDownloadProgress, Error>
  ) async throws -> [LocalAIModelDownloadProgress] {
    var updates: [LocalAIModelDownloadProgress] = []
    for try await update in stream {
      updates.append(update)
    }
    return updates
  }
}

private actor RecordingModelDownloadTransport: LocalAIModelDownloadTransport {
  private let linesToSend: [String]
  private let responseURL: URL?
  private var capturedRequest: URLRequest?

  init(lines: [String], responseURL: URL? = nil) {
    linesToSend = lines
    self.responseURL = responseURL
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    capturedRequest = request
    let response = HTTPURLResponse(
      url: responseURL ?? request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/x-ndjson"]
    )!
    let linesToSend = linesToSend
    let stream = AsyncThrowingStream<String, Error> { continuation in
      for line in linesToSend { continuation.yield(line) }
      continuation.finish()
    }
    return (stream, response)
  }

  func request() -> URLRequest? { capturedRequest }
}
