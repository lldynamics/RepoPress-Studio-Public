import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RSSWebPageSnapshot: Sendable, Equatable {
  public let html: String
  public let sourceURL: URL
  public let fetchedAt: Date

  public init(html: String, sourceURL: URL, fetchedAt: Date = Date()) {
    self.html = html
    self.sourceURL = sourceURL
    self.fetchedAt = fetchedAt
  }
}

/// Fetches the linked page only when the user explicitly enables web-page
/// snapshots. The default transport revalidates and pins every redirect, and
/// forwards no cookies, credentials, or Referer header.
public struct RSSWebPageSnapshotArchiver: Sendable {
  public typealias DownloadOperation = @Sendable (
    _ request: URLRequest,
    _ maximumByteCount: Int,
    _ allowsPrivateNetworkAccess: Bool
  ) async throws -> (Data, HTTPURLResponse)

  public static let defaultMaximumByteCount = 5 * 1024 * 1024
  public static let defaultTimeoutInterval: TimeInterval = 30

  private let maximumByteCount: Int
  private let timeoutInterval: TimeInterval
  private let allowsPrivateNetworkAccess: Bool
  private let downloadOperation: DownloadOperation

  public init(
    maximumByteCount: Int = RSSWebPageSnapshotArchiver.defaultMaximumByteCount,
    timeoutInterval: TimeInterval = RSSWebPageSnapshotArchiver.defaultTimeoutInterval,
    allowsPrivateNetworkAccess: Bool = false,
    downloadOperation: DownloadOperation? = nil
  ) {
    self.maximumByteCount = max(1, maximumByteCount)
    self.timeoutInterval = max(1, timeoutInterval)
    self.allowsPrivateNetworkAccess = allowsPrivateNetworkAccess
    self.downloadOperation = downloadOperation ?? { request, maximumByteCount, allowsPrivateNetworkAccess in
      try await RSSNetworkHTTPClient.data(
        for: request,
        maximumByteCount: maximumByteCount,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
      )
    }
  }

  public func updateNetworkAccess(enabled: Bool) -> RSSWebPageSnapshotArchiver {
    RSSWebPageSnapshotArchiver(
      maximumByteCount: maximumByteCount,
      timeoutInterval: timeoutInterval,
      allowsPrivateNetworkAccess: enabled,
      downloadOperation: downloadOperation
    )
  }

  public func snapshot(for pageURL: URL) async throws -> RSSWebPageSnapshot {
    let validatedURL = try RSSNetworkURLPolicy.syntacticallyValidatedURL(
      pageURL,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    )
    var request = URLRequest(url: validatedURL)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeoutInterval
    request.setValue(
      "text/html, application/xhtml+xml, text/plain;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    request.setValue("RepoPress Studio RSS Web Snapshot", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await downloadOperation(
      request,
      maximumByteCount,
      allowsPrivateNetworkAccess
    )
    guard (200..<300).contains(response.statusCode) else {
      throw RSSReaderError.network("原网页返回 HTTP \(response.statusCode)")
    }
    if let mimeType = response.mimeType?.lowercased(),
       !mimeType.isEmpty,
       !["text/html", "application/xhtml+xml", "text/plain"].contains(mimeType) {
      throw RSSReaderError.network("原网页不是可保存的 HTML 内容")
    }
    guard let html = Self.decodeHTML(data), !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RSSReaderError.network("原网页不是可识别的文本内容")
    }
    return RSSWebPageSnapshot(
      html: html,
      sourceURL: response.url ?? validatedURL
    )
  }

  private static func decodeHTML(_ data: Data) -> String? {
    String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
  }
}
