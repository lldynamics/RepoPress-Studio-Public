import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RSSMediaArchiveResult: Sendable {
  public let assets: [RSSMediaAsset]
  public let failedURLs: [URL]

  public init(assets: [RSSMediaAsset] = [], failedURLs: [URL] = []) {
    self.assets = assets
    self.failedURLs = failedURLs
  }
}

/// Downloads images only for articles the reader has chosen to keep locally.
///
/// The first request carries the article URL as `Referer`, which is required by
/// some legitimate image hosts. If that request is rejected, the archiver
/// retries once without the header. This stays a direct request and does not
/// silently route private subscription credentials through a third-party proxy.
public actor RSSMediaArchiver {
  public typealias DownloadOperation = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  public static let defaultMaximumImageCount = 32
  public static let defaultMaximumImageByteCount = 12 * 1024 * 1024
  public static let defaultTimeoutInterval: TimeInterval = 20

  public let cacheDirectoryURL: URL

  private let fileManager: FileManager
  private let maximumImageCount: Int
  private let maximumImageByteCount: Int
  private let timeoutInterval: TimeInterval
  private let downloadOperation: DownloadOperation

  public init(
    cacheDirectoryURL: URL,
    fileManager: FileManager = .default,
    maximumImageCount: Int = RSSMediaArchiver.defaultMaximumImageCount,
    maximumImageByteCount: Int = RSSMediaArchiver.defaultMaximumImageByteCount,
    timeoutInterval: TimeInterval = RSSMediaArchiver.defaultTimeoutInterval,
    downloadOperation: DownloadOperation? = nil
  ) {
    self.cacheDirectoryURL = cacheDirectoryURL.standardizedFileURL
    self.fileManager = fileManager
    self.maximumImageCount = max(1, maximumImageCount)
    self.maximumImageByteCount = max(1, maximumImageByteCount)
    self.timeoutInterval = max(1, timeoutInterval)
    self.downloadOperation = downloadOperation ?? Self.makeDefaultDownloadOperation(
      timeoutInterval: max(1, timeoutInterval),
      maximumByteCount: max(1, maximumImageByteCount)
    )
  }

  public func archive(article: RSSArticle) async -> RSSMediaArchiveResult {
    let imageURLs = Self.imageURLs(in: article, maximumCount: maximumImageCount)
    guard !imageURLs.isEmpty else { return RSSMediaArchiveResult() }

    do {
      try fileManager.createDirectory(
        at: cacheDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      return RSSMediaArchiveResult(failedURLs: imageURLs)
    }

    var assets: [RSSMediaAsset] = []
    var failedURLs: [URL] = []
    var nextIndex = 0
    let concurrencyLimit = min(4, imageURLs.count)

    await withTaskGroup(of: (URL, RSSMediaAsset?).self) { group in
      func addNext() {
        guard nextIndex < imageURLs.count else { return }
        let imageURL = imageURLs[nextIndex]
        nextIndex += 1
        let articleID = article.id
        let articleURL = article.link
        group.addTask { [self] in
          do {
            return (imageURL, try await self.archiveImage(
              imageURL,
              articleID: articleID,
              referer: articleURL
            ))
          } catch {
            return (imageURL, nil)
          }
        }
      }

      for _ in 0..<concurrencyLimit { addNext() }
      while let result = await group.next() {
        if let asset = result.1 {
          assets.append(asset)
        } else {
          failedURLs.append(result.0)
        }
        addNext()
      }
    }

    return RSSMediaArchiveResult(
      assets: assets.sorted { $0.remoteURL.absoluteString < $1.remoteURL.absoluteString },
      failedURLs: failedURLs.sorted { $0.absoluteString < $1.absoluteString }
    )
  }

  public func remove(assets: [RSSMediaAsset]) {
    let root = cacheDirectoryURL.standardizedFileURL
    for asset in assets {
      let localURL = asset.localURL(in: root).standardizedFileURL
      guard localURL.path.hasPrefix(root.path + "/") else { continue }
      try? fileManager.removeItem(at: localURL)
      removeEmptyParentDirectories(from: localURL.deletingLastPathComponent(), root: root)
    }
  }

  public static func imageURLs(
    in article: RSSArticle,
    maximumCount: Int = RSSMediaArchiver.defaultMaximumImageCount
  ) -> [URL] {
    let html = [article.contentHTML, article.summaryHTML].joined(separator: "\n")
    return imageURLs(in: html, relativeTo: article.link, maximumCount: maximumCount)
  }

  public static func imageURLs(
    in html: String,
    relativeTo baseURL: URL?,
    maximumCount: Int = RSSMediaArchiver.defaultMaximumImageCount
  ) -> [URL] {
    guard maximumCount > 0,
          let expression = try? NSRegularExpression(
            pattern: #"(?is)<img\b[^>]*\b(?:src|data-src|data-original)\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))"#
          )
    else { return [] }

    var output: [URL] = []
    var seen = Set<String>()
    let range = NSRange(html.startIndex..., in: html)
    expression.enumerateMatches(in: html, range: range) { match, _, _ in
      guard output.count < maximumCount, let match else { return }
      for captureIndex in 1...3 {
        guard let captureRange = Range(match.range(at: captureIndex), in: html) else { continue }
        let rawValue = String(html[captureRange])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
              Self.isAllowedRemoteURL(url),
              seen.insert(url.absoluteString).inserted
        else { continue }
        output.append(url)
        break
      }
    }
    return output
  }

  private func archiveImage(
    _ imageURL: URL,
    articleID: String,
    referer: URL?
  ) async throws -> RSSMediaAsset {
    let (data, response) = try await download(imageURL, referer: referer)
    guard !data.isEmpty, data.count <= maximumImageByteCount else {
      throw RSSReaderError.network("图片超过本地缓存大小限制")
    }
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)
    guard Self.looksLikeImage(contentType: contentType, url: imageURL, data: data) else {
      throw RSSReaderError.network("远端内容不是图片")
    }

    let articleDirectoryName = Self.digest(articleID)
    let imageName = Self.digest(imageURL.absoluteString)
    let fileExtension = Self.fileExtension(contentType: contentType, url: imageURL)
    let relativePath = "\(articleDirectoryName)/\(imageName).\(fileExtension)"
    let destinationURL = cacheDirectoryURL.appendingPathComponent(relativePath)
    let parentURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

    if !fileManager.fileExists(atPath: destinationURL.path) {
      let stagingURL = parentURL.appendingPathComponent(
        ".rss-media-\(UUID().uuidString).stage"
      )
      defer { try? fileManager.removeItem(at: stagingURL) }
      try data.write(to: stagingURL, options: [.atomic])
      do {
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
      } catch CocoaError.fileWriteFileExists {
        // Another concurrent article request may have produced the same
        // content between the existence check and the publish step.
      }
    }

    return RSSMediaAsset(
      articleID: articleID,
      remoteURL: imageURL,
      relativePath: relativePath,
      contentType: contentType,
      byteCount: data.count
    )
  }

  private func download(
    _ imageURL: URL,
    referer: URL?
  ) async throws -> (Data, HTTPURLResponse) {
    var lastError: Error?
    for includesReferer in [true, false] {
      var request = URLRequest(url: imageURL)
      request.httpMethod = "GET"
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.timeoutInterval = timeoutInterval
      request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
      request.setValue("RepoPress Studio RSS Media Archiver", forHTTPHeaderField: "User-Agent")
      if includesReferer, let referer {
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
      }

      do {
        let (data, response) = try await downloadOperation(request)
        guard (200..<300).contains(response.statusCode) else {
          let error = RSSReaderError.network("图片服务器返回 HTTP \(response.statusCode)")
          if includesReferer, Self.shouldRetryWithoutReferer(response.statusCode) {
            lastError = error
            continue
          }
          throw error
        }
        return (data, response)
      } catch {
        lastError = error
        if includesReferer { continue }
        throw error
      }
    }
    throw lastError ?? RSSReaderError.network("图片下载失败")
  }

  private static func makeDefaultDownloadOperation(
    timeoutInterval: TimeInterval,
    maximumByteCount: Int
  ) -> DownloadOperation {
    { request in
      let session = CredentialSafeURLSession.make(
        timeoutIntervalForRequest: timeoutInterval,
        timeoutIntervalForResource: timeoutInterval + 10
      )
      defer { session.invalidateAndCancel() }
      let (data, response) = try await BoundedHTTPResponseLoader.data(
        for: request,
        using: session,
        maximumByteCount: maximumByteCount
      )
      guard let httpResponse = response as? HTTPURLResponse else {
        throw RSSReaderError.invalidHTTPResponse
      }
      return (data, httpResponse)
    }
  }

  private static func isAllowedRemoteURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          components.host?.isEmpty == false,
          components.user == nil,
          components.password == nil
    else { return false }
    return true
  }

  private static func shouldRetryWithoutReferer(_ statusCode: Int) -> Bool {
    statusCode == 401 || statusCode == 403 || statusCode == 429 || statusCode >= 500
  }

  private static func looksLikeImage(contentType: String?, url: URL, data: Data) -> Bool {
    if let contentType, contentType.lowercased().hasPrefix("image/") { return true }
    let extensionValue = url.pathExtension.lowercased()
    if ["avif", "bmp", "gif", "jpeg", "jpg", "png", "svg", "webp"].contains(extensionValue) {
      return true
    }
    guard data.count >= 4 else { return false }
    let bytes = [UInt8](data.prefix(12))
    return bytes.starts(with: [0xFF, 0xD8, 0xFF])
      || bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
      || bytes.starts(with: [0x47, 0x49, 0x46, 0x38])
      || (bytes.count >= 12 && String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF"
        && String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP")
  }

  private static func fileExtension(contentType: String?, url: URL) -> String {
    if let contentType {
      switch contentType.lowercased() {
      case "image/jpeg": return "jpg"
      case "image/svg+xml": return "svg"
      case "image/png": return "png"
      case "image/gif": return "gif"
      case "image/webp": return "webp"
      case "image/avif": return "avif"
      default: break
      }
    }
    let extensionValue = url.pathExtension.lowercased()
    return ["avif", "bmp", "gif", "jpeg", "jpg", "png", "svg", "webp"].contains(extensionValue)
      ? (extensionValue == "jpeg" ? "jpg" : extensionValue)
      : "img"
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func removeEmptyParentDirectories(from directory: URL, root: URL) {
    var current = directory.standardizedFileURL
    while current.path.hasPrefix(root.path + "/"), current != root {
      guard (try? fileManager.contentsOfDirectory(atPath: current.path).isEmpty) == true else { break }
      try? fileManager.removeItem(at: current)
      current.deleteLastPathComponent()
    }
  }
}
