import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RSSWebPageSnapshotArchiverTests: XCTestCase {
  func testSnapshotStoresBoundedHTMLWithoutReferer() async throws {
    let pageURL = try XCTUnwrap(URL(string: "https://example.com/posts/one"))
    let recorder = SnapshotRequestRecorder()
    let archiver = RSSWebPageSnapshotArchiver(
      maximumByteCount: 128,
      downloadOperation: { request, _, _ in
        await recorder.record(request)
        let response = try XCTUnwrap(
          HTTPURLResponse(
            url: pageURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
          )
        )
        return (Data("<article>网页全文</article>".utf8), response)
      }
    )

    let snapshot = try await archiver.snapshot(for: pageURL)

    XCTAssertEqual(snapshot.html, "<article>网页全文</article>")
    let recordedRequest = await recorder.request()
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
  }

  func testSnapshotRejectsNonHTMLResponse() async throws {
    let pageURL = try XCTUnwrap(URL(string: "https://example.com/file.pdf"))
    let archiver = RSSWebPageSnapshotArchiver(
      downloadOperation: { request, _, _ in
        let response = try XCTUnwrap(
          HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/pdf"]
          )
        )
        return (Data("not html".utf8), response)
      }
    )

    await assertAsyncThrows {
      _ = try await archiver.snapshot(for: pageURL)
    }
  }
}

private actor SnapshotRequestRecorder {
  private var lastRequest: URLRequest?

  func record(_ request: URLRequest) {
    lastRequest = request
  }

  func request() -> URLRequest? {
    lastRequest
  }
}

private func assertAsyncThrows(
  _ expression: @escaping () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected async expression to throw", file: file, line: line)
  } catch {
    // Expected.
  }
}
