import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RSSArticlePageClientTests: XCTestCase {
  private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var requestStorage: URLRequest?
    private var maximumByteCountStorage: Int?
    private var allowsPrivateNetworkStorage: Bool?

    func record(
      request: URLRequest,
      maximumByteCount: Int,
      allowsPrivateNetworkAccess: Bool
    ) {
      lock.lock()
      requestStorage = request
      maximumByteCountStorage = maximumByteCount
      allowsPrivateNetworkStorage = allowsPrivateNetworkAccess
      lock.unlock()
    }

    var request: URLRequest? {
      lock.lock()
      defer { lock.unlock() }
      return requestStorage
    }

    var maximumByteCount: Int? {
      lock.lock()
      defer { lock.unlock() }
      return maximumByteCountStorage
    }

    var allowsPrivateNetworkAccess: Bool? {
      lock.lock()
      defer { lock.unlock() }
      return allowsPrivateNetworkStorage
    }
  }

  func testDownloadBuildsStatelessArticleRequestAndReturnsValidators() async throws {
    let sourceURL = try XCTUnwrap(URL(string: "http://reader.example/post"))
    let resolvedURL = try XCTUnwrap(URL(string: "https://www.reader.example/post"))
    let probe = Probe()
    let client = RSSArticlePageClient(
      maximumByteCount: 12_345,
      timeoutInterval: 7,
      downloadOperation: { request, limit, allowsPrivateNetworkAccess in
        probe.record(
          request: request,
          maximumByteCount: limit,
          allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
        )
        return (
          Data("<article><p>正文</p></article>".utf8),
          HTTPURLResponse(
            url: resolvedURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
              "Content-Type": "text/html; charset=utf-8",
              "ETag": "new-etag",
              "Last-Modified": "Wed, 26 Aug 2026 08:00:00 GMT",
            ]
          )!
        )
      }
    )

    let result = try await client.download(
      url: sourceURL,
      allowsPrivateNetworkAccess: true,
      etag: "old-etag",
      lastModified: "Tue, 25 Aug 2026 08:00:00 GMT"
    )

    XCTAssertEqual(result.sourceURL, sourceURL)
    XCTAssertEqual(result.resolvedURL, resolvedURL)
    XCTAssertEqual(result.mimeType, "text/html")
    XCTAssertEqual(result.textEncodingName?.lowercased(), "utf-8")
    XCTAssertEqual(result.etag, "new-etag")
    XCTAssertEqual(result.lastModified, "Wed, 26 Aug 2026 08:00:00 GMT")
    XCTAssertFalse(result.notModified)
    XCTAssertEqual(probe.maximumByteCount, 12_345)
    XCTAssertEqual(probe.allowsPrivateNetworkAccess, true)

    let request = try XCTUnwrap(probe.request)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.timeoutInterval, 7)
    XCTAssertTrue(request.value(forHTTPHeaderField: "Accept")?.contains("text/html") == true)
    XCTAssertFalse(request.value(forHTTPHeaderField: "Accept-Language")?.isEmpty ?? true)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      "RepoPress Studio RSS Full Text"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "old-etag")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "If-Modified-Since"),
      "Tue, 25 Aug 2026 08:00:00 GMT"
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
  }

  func testNotModifiedReturnsCacheSignalWithoutBody() async throws {
    let url = try XCTUnwrap(URL(string: "https://reader.example/post"))
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 304,
          httpVersion: "HTTP/1.1",
          headerFields: ["ETag": "same-etag"]
        )!
      )
    })

    let result = try await client.download(url: url, etag: "same-etag")

    XCTAssertTrue(result.notModified)
    XCTAssertTrue(result.data.isEmpty)
    XCTAssertEqual(result.etag, "same-etag")
  }

  func testDownloadRejectsUnsupportedMIMEType() async throws {
    let url = try XCTUnwrap(URL(string: "https://reader.example/post"))
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      (
        Data("%PDF".utf8),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/pdf"]
        )!
      )
    })

    do {
      _ = try await client.download(url: url)
      XCTFail("非网页 MIME 不应进入正文提取")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("内容类型"))
    }
  }

  func testDownloadRejectsHTTPFailure() async throws {
    let url = try XCTUnwrap(URL(string: "https://reader.example/post"))
    let client = RSSArticlePageClient(downloadOperation: { request, _, _ in
      (
        Data("blocked".utf8),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 403,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "text/html"]
        )!
      )
    })

    do {
      _ = try await client.download(url: url)
      XCTFail("HTTP 失败不应作为正文返回")
    } catch let error as RSSReaderError {
      XCTAssertEqual(error, .httpStatus(403))
    }
  }
}
