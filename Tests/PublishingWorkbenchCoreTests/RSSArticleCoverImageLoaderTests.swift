import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RSSArticleCoverImageLoaderTests: XCTestCase {
  func testLoadsGETImageWithoutForwardingCredentials() async throws {
    let imageURL = try XCTUnwrap(URL(string: "https://cdn.example.com/cover.jpg"))
    let recorder = CoverRequestRecorder()
    let loader = RSSArticleCoverImageLoader(
      downloadOperation: { request, _, _ in
        await recorder.record(request)
        let response = try XCTUnwrap(
          HTTPURLResponse(
            url: imageURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
          )
        )
        return (Data([0xFF, 0xD8, 0xFF]), response)
      }
    )

    let data = try await loader.load(from: imageURL)
    let request = await recorder.request()

    XCTAssertEqual(data, Data([0xFF, 0xD8, 0xFF]))
    XCTAssertEqual(request?.httpMethod, "GET")
    XCTAssertNil(request?.value(forHTTPHeaderField: "Referer"))
    XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
  }

  func testRejectsPrivateCoverBeforeDownload() async throws {
    let privateURL = try XCTUnwrap(URL(string: "http://127.0.0.1/cover.jpg"))
    let loader = RSSArticleCoverImageLoader(
      downloadOperation: { _, _, _ in
        XCTFail("private cover must be rejected before the download operation")
        throw RSSReaderError.network("unexpected download")
      }
    )

    do {
      _ = try await loader.load(from: privateURL)
      XCTFail("Expected private cover to be rejected")
    } catch let error as RSSReaderError {
      XCTAssertEqual(error, .privateNetworkAccessDenied)
    }
  }
}

private actor CoverRequestRecorder {
  private var lastRequest: URLRequest?

  func record(_ request: URLRequest) {
    lastRequest = request
  }

  func request() -> URLRequest? {
    lastRequest
  }
}
