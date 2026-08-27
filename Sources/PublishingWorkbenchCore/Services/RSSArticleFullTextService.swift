import CryptoKit
import Foundation

/// Coordinates page download, DOM extraction, quality validation, and the
/// durable full-text record written by `RSSReaderStore`.
public struct RSSArticleFullTextService: Sendable {
  public static let retryDelay: TimeInterval = 30 * 60
  public static let maximumRetryDelay: TimeInterval = 24 * 60 * 60

  private let pageClient: RSSArticlePageClient
  private let extractor: RSSArticleDOMExtractionService

  public init() {
    self.pageClient = RSSArticlePageClient()
    self.extractor = RSSArticleDOMExtractionService()
  }

  public init(
    pageClient: RSSArticlePageClient,
    extractor: RSSArticleDOMExtractionService = RSSArticleDOMExtractionService()
  ) {
    self.pageClient = pageClient
    self.extractor = extractor
  }

  /// Detects the signals feeds commonly use when their payload is only a
  /// teaser. A short article is not automatically considered incomplete.
  public func isTruncatedCandidate(_ article: RSSArticle) -> Bool {
    guard let link = article.link,
          let scheme = link.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return false
    }

    let contentHTML = article.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    let summaryHTML = article.summaryHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    let readable = article.readableText.trimmingCharacters(in: .whitespacesAndNewlines)

    if contentHTML.isEmpty {
      return true
    }
    if contentHTML == summaryHTML, !summaryHTML.isEmpty, readable.count < 1_200 {
      return true
    }
    if Self.hasTruncationMarker(in: readable) {
      return true
    }
    return false
  }

  /// Fetches and validates an independent cache record. A quality rejection is
  /// returned as data so it can be persisted and does not trigger a fetch loop.
  public func fetchFullTextRecord(
    for article: RSSArticle,
    cachedRecord: RSSArticleFullTextRecord? = nil,
    allowsPrivateNetworkAccess: Bool = false,
    attemptedAt: Date = Date(),
    forceRefresh: Bool = false
  ) async throws -> RSSArticleFullTextRecord {
    guard let url = article.link,
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      throw RSSReaderError.persistence("该文章没有有效的原文网页链接。")
    }

    // Validators and cached bodies are reusable only for the exact source URL
    // and the current extraction algorithm. This prevents a changed article
    // link from receiving another origin's ETag and lets extractor upgrades
    // re-process an otherwise unchanged page.
    let reusableCachedRecord: RSSArticleFullTextRecord? = {
      guard !forceRefresh,
            let cachedRecord,
            cachedRecord.articleID == article.id,
            cachedRecord.sourceURL?.absoluteString == url.absoluteString,
            cachedRecord.extractorIdentifier == RSSArticleDOMExtractionService.extractorIdentifier,
            cachedRecord.extractorVersion == RSSArticleDOMExtractionService.extractorVersion else {
        return nil
      }
      return cachedRecord
    }()

    let download = try await pageClient.download(
      url: url,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess,
      etag: reusableCachedRecord?.sourceETag,
      lastModified: reusableCachedRecord?.sourceLastModified
    )

    if download.notModified {
      guard let cachedRecord = reusableCachedRecord else {
        throw RSSReaderError.persistence("原文未变更，但本地没有可用的全文缓存。")
      }
      switch cachedRecord.status {
      case .ready:
        guard !cachedRecord.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw RSSReaderError.persistence("原文未变更，但本地全文缓存为空。")
        }
        return .ready(
          articleID: article.id,
          contentHTML: cachedRecord.contentHTML,
          plainText: cachedRecord.plainText,
          sourceURL: download.sourceURL,
          resolvedURL: download.resolvedURL,
          extractorIdentifier: cachedRecord.extractorIdentifier,
          extractorVersion: cachedRecord.extractorVersion,
          sourceETag: download.etag,
          sourceLastModified: download.lastModified,
          sourceContentHash: cachedRecord.sourceContentHash,
          confidence: cachedRecord.confidence,
          attemptedAt: attemptedAt
        )
      case .rejected:
        return .rejected(
          articleID: article.id,
          sourceURL: download.sourceURL,
          resolvedURL: download.resolvedURL,
          extractorIdentifier: cachedRecord.extractorIdentifier,
          extractorVersion: cachedRecord.extractorVersion,
          sourceETag: download.etag,
          sourceLastModified: download.lastModified,
          sourceContentHash: cachedRecord.sourceContentHash,
          confidence: cachedRecord.confidence,
          attemptedAt: attemptedAt,
          retryAfter: attemptedAt.addingTimeInterval(Self.retryDelay(after: cachedRecord)),
          failureMessage: cachedRecord.failureMessage,
          contentHTML: cachedRecord.contentHTML,
          plainText: cachedRecord.plainText
        )
      case .failed:
        return .failed(
          articleID: article.id,
          sourceURL: download.sourceURL,
          resolvedURL: download.resolvedURL,
          extractorIdentifier: cachedRecord.extractorIdentifier,
          extractorVersion: cachedRecord.extractorVersion,
          sourceETag: download.etag,
          sourceLastModified: download.lastModified,
          sourceContentHash: cachedRecord.sourceContentHash,
          confidence: cachedRecord.confidence,
          attemptedAt: attemptedAt,
          retryAfter: attemptedAt.addingTimeInterval(Self.retryDelay(after: cachedRecord)),
          failureMessage: cachedRecord.failureMessage
        )
      }
    }

    let extraction = try extractor.extract(
      data: download.data,
      sourceURL: download.resolvedURL,
      expectedTitle: article.title,
      textEncodingName: download.textEncodingName
    )
    let rejectionReason = qualityRejectionReason(extraction, comparedWith: article)
    let hash = Self.sha256(download.data)

    if let rejectionReason {
      return .rejected(
        articleID: article.id,
        sourceURL: download.sourceURL,
        resolvedURL: download.resolvedURL,
        extractorIdentifier: extraction.extractorIdentifier,
        extractorVersion: extraction.extractorVersion,
        sourceETag: download.etag,
        sourceLastModified: download.lastModified,
        sourceContentHash: hash,
        confidence: extraction.confidence,
        attemptedAt: attemptedAt,
        retryAfter: attemptedAt.addingTimeInterval(Self.retryDelay(after: reusableCachedRecord)),
        failureMessage: rejectionReason,
        contentHTML: extraction.contentHTML,
        plainText: extraction.plainText
      )
    }

    return .ready(
      articleID: article.id,
      contentHTML: extraction.contentHTML,
      plainText: extraction.plainText,
      sourceURL: download.sourceURL,
      resolvedURL: download.resolvedURL,
      extractorIdentifier: extraction.extractorIdentifier,
      extractorVersion: extraction.extractorVersion,
      sourceETag: download.etag,
      sourceLastModified: download.lastModified,
      sourceContentHash: hash,
      confidence: extraction.confidence,
      attemptedAt: attemptedAt
    )
  }

  /// Compatibility entry point for callers that need a renderable article.
  /// Persistence should use `fetchFullTextRecord` so the feed payload remains
  /// independent from the extracted page.
  public func fetchFullText(
    for article: RSSArticle,
    allowsPrivateNetworkAccess: Bool = false
  ) async throws -> RSSArticle {
    let record = try await fetchFullTextRecord(
      for: article,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    )
    guard record.status == .ready else {
      throw RSSReaderError.persistence(
        record.failureMessage ?? "提取结果未通过正文质量校验。"
      )
    }
    return articleByApplying(record, to: article)
  }

  public func articleByApplying(
    _ record: RSSArticleFullTextRecord,
    to article: RSSArticle
  ) -> RSSArticle {
    guard record.status == .ready else { return article }
    var updated = article
    updated.contentHTML = record.contentHTML
    return updated
  }

  public func failureRecord(
    for article: RSSArticle,
    cachedRecord: RSSArticleFullTextRecord? = nil,
    error: Error,
    attemptedAt: Date = Date()
  ) -> RSSArticleFullTextRecord {
    let reusableCachedRecord: RSSArticleFullTextRecord? = {
      guard let cachedRecord,
            cachedRecord.articleID == article.id,
            cachedRecord.sourceURL?.absoluteString == article.link?.absoluteString else {
        return nil
      }
      return cachedRecord
    }()
    return .failed(
      articleID: article.id,
      sourceURL: article.link,
      resolvedURL: reusableCachedRecord?.resolvedURL,
      extractorIdentifier: reusableCachedRecord?.extractorIdentifier
        ?? RSSArticleDOMExtractionService.extractorIdentifier,
      extractorVersion: reusableCachedRecord?.extractorVersion
        ?? RSSArticleDOMExtractionService.extractorVersion,
      sourceETag: reusableCachedRecord?.sourceETag,
      sourceLastModified: reusableCachedRecord?.sourceLastModified,
      sourceContentHash: reusableCachedRecord?.sourceContentHash,
      confidence: reusableCachedRecord?.confidence ?? 0,
      attemptedAt: attemptedAt,
      retryAfter: attemptedAt.addingTimeInterval(Self.retryDelay(after: reusableCachedRecord)),
      failureMessage: error.localizedDescription
    )
  }

  private func qualityRejectionReason(
    _ extraction: RSSArticleDOMExtractionResult,
    comparedWith article: RSSArticle
  ) -> String? {
    let extracted = extraction.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    let feedText = article.readableText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !extracted.isEmpty else { return "原文网页没有可读正文。" }

    // Confidence incorporates semantic containers, prose structure, link
    // density, shell hints, and title similarity. A semantic short post can
    // therefore pass without an arbitrary minimum article length.
    if extraction.confidence < 0.28 {
      return "页面结构置信度过低，已保留 Feed 原文。"
    }

    if !feedText.isEmpty {
      let minimumUsefulCount = max(12, Int(Double(feedText.count) * 0.85))
      if extracted.count < minimumUsefulCount {
        return "提取结果比 Feed 已有内容明显更短，已拒绝替换。"
      }
    }
    return nil
  }

  private static func hasTruncationMarker(in text: String) -> Bool {
    let normalized = text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalized.isEmpty else { return false }
    let suffix = String(normalized.suffix(160))
    let phrases = [
      "阅读全文", "继续阅读", "查看全文", "点击阅读", "read more",
      "continue reading", "view full post",
    ]
    return phrases.contains { suffix.contains($0) }
      || suffix.hasSuffix("…")
      || suffix.hasSuffix("...")
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func retryDelay(after cachedRecord: RSSArticleFullTextRecord?) -> TimeInterval {
    guard let cachedRecord,
          let previousRetryAfter = cachedRecord.retryAfter else {
      return retryDelay
    }
    let previousDelay = previousRetryAfter.timeIntervalSince(cachedRecord.attemptedAt)
    guard previousDelay > 0 else { return retryDelay }
    return min(maximumRetryDelay, max(retryDelay, previousDelay * 2))
  }
}
