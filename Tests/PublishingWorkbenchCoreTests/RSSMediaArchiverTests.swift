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

  func testArchiveWritesLocalAssetWithoutReferer() async throws {
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
      allowsPrivateNetworkAccess: true,
      downloadOperation: { request in
        await recorder.record(request)
        let response = try XCTUnwrap(
          HTTPURLResponse(
            url: imageURL,
            statusCode: 200,
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
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(requests[0].value(forHTTPHeaderField: "Referer"))

    await archiver.remove(assets: [asset])
    XCTAssertFalse(FileManager.default.fileExists(atPath: asset.localURL(in: rootURL).path))
  }

  func testMediaURLExtractionIncludesVideoAudioAndDownloadAttachments() throws {
    let baseURL = try XCTUnwrap(URL(string: "https://example.com/posts/one"))
    let html = """
      <video src="/media/video.mp4"></video>
      <audio data-src="https://cdn.example.com/audio.mp3"></audio>
      <a download href="/files/article.pdf">下载附件</a>
      <a href="/posts/related">普通链接不应缓存</a>
      """

    let urls = RSSMediaArchiver.mediaURLs(in: html, relativeTo: baseURL)

    XCTAssertEqual(
      urls.map(\.absoluteString),
      [
        "https://example.com/media/video.mp4",
        "https://cdn.example.com/audio.mp3",
        "https://example.com/files/article.pdf",
      ]
    )
  }

  func testMediaExtractionDoesNotIncludeArticleURLOrCredentials() throws {
    let articleURL = try XCTUnwrap(URL(string: "https://blog.example.com/posts/one?token=private#fragment"))
    let imageURL = try XCTUnwrap(URL(string: "https://cdn.example.com/one.png"))

    let urls = RSSMediaArchiver.mediaURLs(
      in: "<img src=\"\(imageURL.absoluteString)\">",
      relativeTo: articleURL
    )
    XCTAssertEqual(urls, [imageURL])
    XCTAssertFalse(urls.contains { $0.absoluteString.contains("token=private") })
  }

  func testStartupRecoveryRemovesPersistedDeletionsAndUnreferencedFiles() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSMediaOrphanTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let pendingURL = rootURL.appendingPathComponent("pending/image.png")
    let orphanURL = rootURL.appendingPathComponent("orphan/image.png")
    try FileManager.default.createDirectory(
      at: pendingURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: orphanURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("pending".utf8).write(to: pendingURL)
    try Data("orphan".utf8).write(to: orphanURL)
    let journal = try JSONSerialization.data(
      withJSONObject: ["relativePaths": ["pending/image.png"]],
      options: [.sortedKeys]
    )
    try journal.write(
      to: rootURL.appendingPathComponent(".rss-media-deletion-journal.json"),
      options: .atomic
    )

    let archiver = RSSMediaArchiver(cacheDirectoryURL: rootURL)
    await archiver.recoverPendingDeletions()
    await archiver.removeOrphans(knownAssets: [])

    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
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
