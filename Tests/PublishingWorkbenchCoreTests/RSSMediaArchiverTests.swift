import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RSSMediaArchiverTests: XCTestCase {
  func testImageURLExtractionResolvesRelativeURLsAndRejectsUnsafeSchemes() throws {
    let baseURL = try XCTUnwrap(URL(string: "https://example.com/posts/one"))
    let html = """
      <img src="/images/one.png">
      <img data-src='https://cdn.example.com/two.webp?size=large'>
      <img data-original="javascript:alert(1)">
      <img src="https://user:secret@example.com/private.png">
      <img src="data:image/png;base64,abc">
      """

    let urls = RSSMediaArchiver.imageURLs(in: html, relativeTo: baseURL)

    XCTAssertEqual(
      urls.map(\.absoluteString),
      [
        "https://example.com/images/one.png",
        "https://cdn.example.com/two.webp?size=large"
      ]
    )
  }

  func testArchiveRetriesWithoutRefererAndWritesLocalAsset() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSMediaArchiverTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let articleURL = try XCTUnwrap(URL(string: "https://blog.example.com/posts/one"))
    let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/one.png"))
    let feedID = UUID()
    let article = RSSArticle(
      id: "media-article",
      feedID: feedID,
      title: "图片归档",
      link: articleURL,
      contentHTML: "<p>正文</p><img src=\"https://img.example.com/one.png\">"
    )
    let recorder = RSSMediaRequestRecorder()
    let archiver = RSSMediaArchiver(
      cacheDirectoryURL: rootURL,
      downloadOperation: { request in
        await recorder.record(request)
        let attempt = await recorder.count()
        let response = try XCTUnwrap(
          HTTPURLResponse(
            url: imageURL,
            statusCode: attempt == 1 ? 403 : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
          )
        )
        return (Data([0x89, 0x50, 0x4E, 0x47]), response)
      }
    )

    let result = await archiver.archive(article: article)

    let asset = try XCTUnwrap(result.assets.first)
    XCTAssertTrue(result.failedURLs.isEmpty)
    XCTAssertEqual(asset.remoteURL, imageURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: asset.localURL(in: rootURL).path))

    let requests = await recorder.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Referer"), articleURL.absoluteString)
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Referer"))

    await archiver.remove(assets: [asset])
    XCTAssertFalse(FileManager.default.fileExists(atPath: asset.localURL(in: rootURL).path))
  }
}

private actor RSSMediaRequestRecorder {
  private var recordedRequests: [URLRequest] = []

  func record(_ request: URLRequest) {
    recordedRequests.append(request)
  }

  func count() -> Int {
    recordedRequests.count
  }

  func requests() -> [URLRequest] {
    recordedRequests
  }
}
