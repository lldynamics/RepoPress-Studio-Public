import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor RSSMediaNetworkAccessState {
  private var value: Bool

  init(_ value: Bool) {
    self.value = value
  }

  func get() -> Bool {
    value
  }

  func set(_ value: Bool) {
    self.value = value
  }
}

public struct RSSMediaArchiveResult: Sendable {
  public let assets: [RSSMediaAsset]
  public let failedURLs: [URL]

  public init(assets: [RSSMediaAsset] = [], failedURLs: [URL] = []) {
    self.assets = assets
    self.failedURLs = failedURLs
  }
}

/// Experimental offline enrichment: downloads media only for articles the
/// reader has chosen to keep locally.
///
/// Media requests never carry a `Referer`, cookie, credential, or article URL.
/// This avoids leaking private feed paths and query values to a media host.
/// Requests use the RSS DNS-pinned transport and do not silently route private
/// subscription credentials through a third-party proxy.
public actor RSSMediaArchiver {
  public typealias DownloadOperation = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  public static let defaultMaximumMediaCount = 32
  @available(*, deprecated, message: "Use defaultMaximumMediaCount")
  public static let defaultMaximumImageCount = defaultMaximumMediaCount
  public static let defaultMaximumImageByteCount = 12 * 1024 * 1024
  public static let defaultTimeoutInterval: TimeInterval = 20

  public let cacheDirectoryURL: URL

  private static let deletionJournalFileName = ".rss-media-deletion-journal.json"

  private struct DeletionJournal: Codable {
    var relativePaths: [String]
  }

  private let fileManager: FileManager
  private let maximumMediaCount: Int
  private let maximumMediaByteCount: Int
  private let timeoutInterval: TimeInterval
  private var allowsPrivateNetworkAccess: Bool
  private let networkAccessState: RSSMediaNetworkAccessState
  private let downloadOperation: DownloadOperation

  public init(
    cacheDirectoryURL: URL,
    maximumImageCount: Int = RSSMediaArchiver.defaultMaximumMediaCount,
    maximumImageByteCount: Int = RSSMediaArchiver.defaultMaximumImageByteCount,
    timeoutInterval: TimeInterval = RSSMediaArchiver.defaultTimeoutInterval,
    allowsPrivateNetworkAccess: Bool = false,
    downloadOperation: DownloadOperation? = nil
  ) {
    self.cacheDirectoryURL = cacheDirectoryURL.standardizedFileURL
    self.fileManager = .default
    self.maximumMediaCount = max(1, maximumImageCount)
    self.maximumMediaByteCount = max(1, maximumImageByteCount)
    self.timeoutInterval = max(1, timeoutInterval)
    self.allowsPrivateNetworkAccess = allowsPrivateNetworkAccess
    let networkAccessState = RSSMediaNetworkAccessState(allowsPrivateNetworkAccess)
    self.networkAccessState = networkAccessState
    self.downloadOperation = downloadOperation ?? Self.makeDefaultDownloadOperation(
      timeoutInterval: max(1, timeoutInterval),
      maximumByteCount: max(1, maximumImageByteCount),
      networkAccessState: networkAccessState
    )
  }

  public func updateNetworkAccess(enabled: Bool) {
    allowsPrivateNetworkAccess = enabled
    Task { await networkAccessState.set(enabled) }
  }

  public func archive(
    article: RSSArticle,
    excludingURLs: Set<URL> = []
  ) async -> RSSMediaArchiveResult {
    let mediaURLs = Self.mediaURLs(in: article, maximumCount: maximumMediaCount)
      .filter { !excludingURLs.contains($0) }
    guard !mediaURLs.isEmpty else { return RSSMediaArchiveResult() }

    do {
      try fileManager.createDirectory(
        at: cacheDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      return RSSMediaArchiveResult(failedURLs: mediaURLs)
    }

    var assets: [RSSMediaAsset] = []
    var failedURLs: [URL] = []
    var nextIndex = 0
    let concurrencyLimit = min(4, mediaURLs.count)

    await withTaskGroup(of: (URL, RSSMediaAsset?).self) { group in
      func addNext() {
        guard nextIndex < mediaURLs.count else { return }
        let mediaURL = mediaURLs[nextIndex]
        nextIndex += 1
        let articleID = article.id
        group.addTask { [self] in
          do {
            return (mediaURL, try await self.archiveMedia(
              mediaURL,
              articleID: articleID
            ))
          } catch {
            return (mediaURL, nil)
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
    let paths = assets.compactMap { safeRelativePath($0.relativePath) }
    guard !paths.isEmpty else { return }
    var journal = loadDeletionJournal()
    journal.relativePaths = Array(Set(journal.relativePaths + paths)).sorted()
    guard saveDeletionJournal(journal) else { return }
    processDeletionJournal()
  }

  /// Completes a deletion that was durably recorded before a process stop.
  public func recoverPendingDeletions() {
    processDeletionJournal()
  }

  /// Removes files that no longer have a database record. This is intentionally
  /// scoped to the app-owned RSSMedia directory and runs after a restart, so a
  /// feed deletion cannot leave unbounded orphaned assets behind.
  public func removeOrphans(knownAssets: [RSSMediaAsset]) {
    processDeletionJournal()
    let root = cacheDirectoryURL.standardizedFileURL
    guard fileManager.fileExists(atPath: root.path) else { return }
    let knownPaths = Set(knownAssets.compactMap { safeRelativePath($0.relativePath) })
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) else { return }
    var orphanURLs: [URL] = []
    for case let url as URL in enumerator {
      guard url.lastPathComponent != Self.deletionJournalFileName,
            let relativePath = relativePath(of: url, under: root),
            !knownPaths.contains(relativePath),
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true else { continue }
      orphanURLs.append(url)
    }
    for url in orphanURLs {
      try? fileManager.removeItem(at: url)
      removeEmptyParentDirectories(from: url.deletingLastPathComponent(), root: root)
    }
  }

  public static func mediaURLs(
    in article: RSSArticle,
    maximumCount: Int = RSSMediaArchiver.defaultMaximumMediaCount
  ) -> [URL] {
    let html = [
      article.contentHTML,
      article.summaryHTML,
      article.webPageSnapshotHTML ?? "",
    ].joined(separator: "\n")
    return mediaURLs(in: html, relativeTo: article.link, maximumCount: maximumCount)
  }

  public static func mediaURLs(
    in html: String,
    relativeTo baseURL: URL?,
    maximumCount: Int = RSSMediaArchiver.defaultMaximumMediaCount
  ) -> [URL] {
    guard maximumCount > 0 else { return [] }

    var output: [URL] = []
    var seen = Set<String>()
    let range = NSRange(html.startIndex..., in: html)
    let tagExpression = try? NSRegularExpression(
      pattern: #"(?is)<(img|video|audio|source|a)\b[^>]*>"#
    )
    tagExpression?.enumerateMatches(in: html, range: range) { match, _, _ in
      guard output.count < maximumCount,
            let match,
            let tagRange = Range(match.range, in: html),
            let tagNameRange = Range(match.range(at: 1), in: html) else { return }
      let tag = String(html[tagRange])
      let tagName = String(html[tagNameRange]).lowercased()
      if tagName == "a" && !Self.hasAttribute(in: tag, named: "download") {
        return
      }
      let attributeNames = tagName == "a"
        ? ["href"]
        : ["src", "data-src", "data-original"]
      guard let rawValue = Self.attributeValue(in: tag, named: attributeNames),
            let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
            Self.isAllowedRemoteURL(url),
            seen.insert(url.absoluteString).inserted else { return }
      output.append(url)
    }
    return output
  }

  private static func attributeValue(in tag: String, named names: [String]) -> String? {
    let namesPattern = names
      .map(NSRegularExpression.escapedPattern(for:))
      .joined(separator: "|")
    guard let expression = try? NSRegularExpression(
      pattern: "(?is)\\b(?:\(namesPattern))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
    ),
    let match = expression.firstMatch(
      in: tag,
      range: NSRange(tag.startIndex..., in: tag)
    ) else { return nil }
    for captureIndex in 1...3 {
      guard let range = Range(match.range(at: captureIndex), in: tag) else { continue }
      let value = String(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    return ""
  }

  private static func hasAttribute(in tag: String, named name: String) -> Bool {
    guard let expression = try? NSRegularExpression(
      pattern: "(?is)\\b\(NSRegularExpression.escapedPattern(for: name))(?:\\s*=|\\s|>)"
    ) else { return false }
    return expression.firstMatch(
      in: tag,
      range: NSRange(tag.startIndex..., in: tag)
    ) != nil
  }

  /// Compatibility helper for callers that only want `<img>` sources.
  public static func imageURLs(
    in article: RSSArticle,
    maximumCount: Int = RSSMediaArchiver.defaultMaximumMediaCount
  ) -> [URL] {
    imageURLs(
      in: [article.contentHTML, article.summaryHTML].joined(separator: "\n"),
      relativeTo: article.link,
      maximumCount: maximumCount
    )
  }

  public static func imageURLs(
    in html: String,
    relativeTo baseURL: URL?,
    maximumCount: Int = RSSMediaArchiver.defaultMaximumMediaCount
  ) -> [URL] {
    mediaURLs(
      in: html,
      relativeTo: baseURL,
      maximumCount: maximumCount
    ).filter { url in
      let pathExtension = url.pathExtension.lowercased()
      return ["avif", "bmp", "gif", "jpeg", "jpg", "png", "svg", "webp"].contains(pathExtension)
    }
  }

  private func archiveMedia(
    _ mediaURL: URL,
    articleID: String
  ) async throws -> RSSMediaAsset {
    let (data, response) = try await download(mediaURL)
    guard !data.isEmpty, data.count <= maximumMediaByteCount else {
      throw RSSReaderError.network("媒体超过本地缓存大小限制")
    }
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)
    guard Self.looksLikeMedia(contentType: contentType, url: mediaURL, data: data) else {
      throw RSSReaderError.network("远端内容不是受支持的媒体或附件")
    }

    let articleDirectoryName = Self.digest(articleID)
    let mediaName = Self.digest(mediaURL.absoluteString)
    let fileExtension = Self.fileExtension(contentType: contentType, url: mediaURL)
    let relativePath = "\(articleDirectoryName)/\(mediaName).\(fileExtension)"
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
      remoteURL: mediaURL,
      relativePath: relativePath,
      contentType: contentType,
      byteCount: data.count
    )
  }

  private func download(
    _ mediaURL: URL
  ) async throws -> (Data, HTTPURLResponse) {
    guard (try? RSSNetworkURLPolicy.syntacticallyValidatedURL(
      mediaURL,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    )) != nil else {
      throw RSSReaderError.network("已阻止访问本机或局域网媒体地址。")
    }
    var request = URLRequest(url: mediaURL)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeoutInterval
    request.setValue(
      "image/avif,image/webp,image/apng,image/svg+xml,image/*,video/*,audio/*,application/pdf,application/zip,*/*;q=0.1",
      forHTTPHeaderField: "Accept"
    )
    request.setValue("RepoPress Studio RSS Media Archiver", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await downloadOperation(request)
    guard (200..<300).contains(response.statusCode) else {
      throw RSSReaderError.network("媒体服务器返回 HTTP \(response.statusCode)")
    }
    return (data, response)
  }

  private static func makeDefaultDownloadOperation(
    timeoutInterval: TimeInterval,
    maximumByteCount: Int,
    networkAccessState: RSSMediaNetworkAccessState
  ) -> DownloadOperation {
    { request in
      let allowsPrivateNetworkAccess = await networkAccessState.get()
      let (data, response) = try await RSSNetworkHTTPClient.data(
        for: request,
        maximumByteCount: maximumByteCount,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
      )
      return (data, response)
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

  private static func looksLikeMedia(contentType: String?, url: URL, data: Data) -> Bool {
    let normalizedContentType = contentType?.lowercased() ?? ""
    if normalizedContentType.hasPrefix("image/")
      || normalizedContentType.hasPrefix("video/")
      || normalizedContentType.hasPrefix("audio/") {
      return true
    }
    if [
      "application/pdf",
      "application/zip",
      "application/x-7z-compressed",
      "application/x-rar-compressed",
      "application/octet-stream",
    ].contains(normalizedContentType),
    Self.allowedAttachmentExtensions.contains(url.pathExtension.lowercased()) {
      return true
    }
    let extensionValue = url.pathExtension.lowercased()
    if Self.allowedMediaExtensions.contains(extensionValue) {
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
      case "video/mp4": return "mp4"
      case "video/webm": return "webm"
      case "audio/mpeg": return "mp3"
      case "audio/ogg": return "ogg"
      case "audio/wav": return "wav"
      case "application/pdf": return "pdf"
      case "application/zip": return "zip"
      default: break
      }
    }
    let extensionValue = url.pathExtension.lowercased()
    return Self.allowedMediaExtensions.contains(extensionValue)
      || Self.allowedAttachmentExtensions.contains(extensionValue)
      ? (extensionValue == "jpeg" ? "jpg" : extensionValue)
      : "bin"
  }

  private static let allowedMediaExtensions: Set<String> = [
    "avif", "bmp", "gif", "jpeg", "jpg", "m4a", "mp3", "mp4", "ogg", "png",
    "svg", "wav", "webm", "webp",
  ]

  private static let allowedAttachmentExtensions: Set<String> = [
    "7z", "csv", "doc", "docx", "epub", "gz", "json", "pdf", "ppt", "pptx",
    "rtf", "tar", "txt", "xls", "xlsx", "xml", "zip",
  ]

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

  private var deletionJournalURL: URL {
    cacheDirectoryURL.appendingPathComponent(Self.deletionJournalFileName)
  }

  private func processDeletionJournal() {
    let journal = loadDeletionJournal()
    guard !journal.relativePaths.isEmpty else {
      try? fileManager.removeItem(at: deletionJournalURL)
      return
    }
    let root = cacheDirectoryURL.standardizedFileURL
    var remaining: [String] = []
    for relativePath in journal.relativePaths {
      guard let safePath = safeRelativePath(relativePath) else { continue }
      let localURL = root.appendingPathComponent(safePath).standardizedFileURL
      guard localURL.path.hasPrefix(root.path + "/") else { continue }
      do {
        if fileManager.fileExists(atPath: localURL.path) {
          try fileManager.removeItem(at: localURL)
        }
        removeEmptyParentDirectories(from: localURL.deletingLastPathComponent(), root: root)
      } catch {
        remaining.append(safePath)
      }
    }
    if remaining.isEmpty {
      try? fileManager.removeItem(at: deletionJournalURL)
    } else {
      _ = saveDeletionJournal(DeletionJournal(relativePaths: Array(Set(remaining)).sorted()))
    }
  }

  private func loadDeletionJournal() -> DeletionJournal {
    guard let data = try? Data(contentsOf: deletionJournalURL),
          let journal = try? JSONDecoder().decode(DeletionJournal.self, from: data) else {
      return DeletionJournal(relativePaths: [])
    }
    return DeletionJournal(
      relativePaths: journal.relativePaths.compactMap(safeRelativePath)
    )
  }

  private func saveDeletionJournal(_ journal: DeletionJournal) -> Bool {
    do {
      try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(journal)
      try data.write(to: deletionJournalURL, options: [.atomic])
      let handle = try FileHandle(forWritingTo: deletionJournalURL)
      try handle.synchronize()
      try handle.close()
      return true
    } catch {
      return false
    }
  }

  private func safeRelativePath(_ value: String) -> String? {
    let normalized = value.replacingOccurrences(of: "\\", with: "/")
    let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
      return nil
    }
    return components.joined(separator: "/")
  }

  private func relativePath(of url: URL, under root: URL) -> String? {
    guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { return nil }
    return String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
      .replacingOccurrences(of: "\\", with: "/")
  }
}
