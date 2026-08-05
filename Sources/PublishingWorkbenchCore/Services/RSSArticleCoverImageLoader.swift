import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Loads one RSS article cover through the same redirect-aware, DNS-pinned
/// transport used by feed, snapshot, and media requests.
public struct RSSArticleCoverImageLoader: Sendable {
  public typealias DownloadOperation = @Sendable (
    _ request: URLRequest,
    _ maximumByteCount: Int,
    _ allowsPrivateNetworkAccess: Bool
  ) async throws -> (Data, HTTPURLResponse)

  public static let defaultMaximumByteCount = 2 * 1_024 * 1_024
  public static let defaultTimeoutInterval: TimeInterval = 15

  private let maximumByteCount: Int
  private let timeoutInterval: TimeInterval
  private let allowsPrivateNetworkAccess: Bool
  private let downloadOperation: DownloadOperation

  public init(
    maximumByteCount: Int = RSSArticleCoverImageLoader.defaultMaximumByteCount,
    timeoutInterval: TimeInterval = RSSArticleCoverImageLoader.defaultTimeoutInterval,
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

  public func load(from imageURL: URL) async throws -> Data {
    let validatedURL = try RSSNetworkURLPolicy.syntacticallyValidatedURL(
      imageURL,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    )
    var request = URLRequest(url: validatedURL)
    request.httpMethod = "GET"
    request.cachePolicy = .returnCacheDataElseLoad
    request.timeoutInterval = timeoutInterval
    request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*;q=0.9", forHTTPHeaderField: "Accept")
    request.setValue("RepoPress Studio RSS Cover Thumbnail", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await downloadOperation(
      request,
      maximumByteCount,
      allowsPrivateNetworkAccess
    )
    guard (200..<300).contains(response.statusCode) else {
      throw RSSReaderError.network("文章封面服务器返回 HTTP (response.statusCode)")
    }
    if let mimeType = response.mimeType?.lowercased(),
       !mimeType.isEmpty,
       !mimeType.hasPrefix("image/") {
      throw RSSReaderError.network("远端内容不是图片")
    }
    guard !data.isEmpty else {
      throw RSSReaderError.network("文章封面响应为空")
    }
    return data
  }
}
