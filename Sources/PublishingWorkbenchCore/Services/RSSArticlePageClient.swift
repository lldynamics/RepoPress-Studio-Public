import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The HTTP payload and validators needed by the RSS full-text cache.
public struct RSSArticlePageDownload: Sendable {
  public let data: Data
  public let sourceURL: URL
  public let resolvedURL: URL
  public let mimeType: String
  public let textEncodingName: String?
  public let etag: String?
  public let lastModified: String?
  public let notModified: Bool

  public init(
    data: Data,
    sourceURL: URL,
    resolvedURL: URL,
    mimeType: String,
    textEncodingName: String? = nil,
    etag: String? = nil,
    lastModified: String? = nil,
    notModified: Bool = false
  ) {
    self.data = data
    self.sourceURL = sourceURL
    self.resolvedURL = resolvedURL
    self.mimeType = mimeType
    self.textEncodingName = textEncodingName
    self.etag = etag
    self.lastModified = lastModified
    self.notModified = notModified
  }
}

/// Downloads an RSS article page through the same DNS-pinned, redirect-aware
/// network boundary as feed and media requests. It never forwards credentials
/// or cookies and leaves HTML parsing to the extraction service.
public struct RSSArticlePageClient: Sendable {
  public typealias DownloadOperation = @Sendable (
    _ request: URLRequest,
    _ maximumByteCount: Int,
    _ allowsPrivateNetworkAccess: Bool
  ) async throws -> (Data, HTTPURLResponse)

  public static let defaultMaximumByteCount = 4 * 1_024 * 1_024
  public static let defaultTimeoutInterval: TimeInterval = 20

  private static let allowedMIMETypes: Set<String> = [
    "text/html",
    "application/xhtml+xml",
    "text/plain",
  ]

  public let maximumByteCount: Int
  public let timeoutInterval: TimeInterval
  public let allowsPrivateNetworkAccess: Bool
  private let downloadOperation: DownloadOperation

  public init(
    maximumByteCount: Int = RSSArticlePageClient.defaultMaximumByteCount,
    timeoutInterval: TimeInterval = RSSArticlePageClient.defaultTimeoutInterval,
    allowsPrivateNetworkAccess: Bool = false,
    downloadOperation: DownloadOperation? = nil
  ) {
    self.maximumByteCount = max(1, maximumByteCount)
    self.timeoutInterval = max(1, timeoutInterval)
    self.allowsPrivateNetworkAccess = allowsPrivateNetworkAccess
    self.downloadOperation = downloadOperation ?? {
      request,
      maximumByteCount,
      allowsPrivateNetworkAccess in
      try await RSSNetworkHTTPClient.data(
        for: request,
        maximumByteCount: maximumByteCount,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
      )
    }
  }

  public func download(
    url: URL,
    allowsPrivateNetworkAccess overridePrivateNetworkAccess: Bool? = nil,
    etag: String? = nil,
    lastModified: String? = nil
  ) async throws -> RSSArticlePageDownload {
    let permitsPrivateNetwork = overridePrivateNetworkAccess ?? allowsPrivateNetworkAccess
    let validatedURL = try RSSNetworkURLPolicy.syntacticallyValidatedURL(
      url,
      allowsPrivateNetworkAccess: permitsPrivateNetwork
    )

    var request = URLRequest(url: validatedURL)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeoutInterval
    request.setValue(
      "text/html, application/xhtml+xml;q=0.9, text/plain;q=0.6",
      forHTTPHeaderField: "Accept"
    )
    request.setValue(Self.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
    request.setValue("RepoPress Studio RSS Full Text", forHTTPHeaderField: "User-Agent")
    if let etag = etag?.trimmingCharacters(in: .whitespacesAndNewlines), !etag.isEmpty {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    if let lastModified = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines),
       !lastModified.isEmpty {
      request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
    }

    let (data, response) = try await downloadOperation(
      request,
      maximumByteCount,
      permitsPrivateNetwork
    )
    let responseETag = response.value(forHTTPHeaderField: "ETag") ?? etag
    let responseLastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? lastModified
    let resolvedURL = response.url ?? validatedURL

    if response.statusCode == 304 {
      return RSSArticlePageDownload(
        data: Data(),
        sourceURL: validatedURL,
        resolvedURL: resolvedURL,
        mimeType: response.mimeType?.lowercased() ?? "",
        textEncodingName: response.textEncodingName,
        etag: responseETag,
        lastModified: responseLastModified,
        notModified: true
      )
    }

    guard (200..<300).contains(response.statusCode) else {
      throw RSSReaderError.httpStatus(response.statusCode)
    }
    let mimeType = response.mimeType?.lowercased() ?? ""
    guard Self.allowedMIMETypes.contains(mimeType) else {
      throw RSSReaderError.network(
        "原文网页返回了不支持的内容类型：\(mimeType.nilIfEmpty ?? "未知")。"
      )
    }
    guard !data.isEmpty else {
      throw RSSReaderError.network("原文网页响应为空。")
    }

    return RSSArticlePageDownload(
      data: data,
      sourceURL: validatedURL,
      resolvedURL: resolvedURL,
      mimeType: mimeType,
      textEncodingName: response.textEncodingName,
      etag: responseETag,
      lastModified: responseLastModified
    )
  }

  private static var acceptLanguageHeader: String {
    let languages = Array(Locale.preferredLanguages.prefix(3))
    guard let first = languages.first else { return "zh-CN,zh;q=0.9,en;q=0.7" }
    return ([first] + languages.dropFirst().enumerated().map { offset, language in
      let quality = max(0.5, 0.9 - Double(offset) * 0.1)
      return "\(language);q=\(String(format: "%.1f", quality))"
    }).joined(separator: ",")
  }
}
