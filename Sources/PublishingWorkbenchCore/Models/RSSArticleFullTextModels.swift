import Foundation

/// The outcome of an attempt to extract the original web page for an RSS
/// article.  A rejected extraction is a completed attempt whose quality gate
/// did not accept the result; a failed extraction did not produce a usable
/// result at all.
public enum RSSArticleFullTextStatus: String, Codable, Hashable, Sendable {
  case ready
  case rejected
  case failed
}

/// A durable, independent cache record for an article's original web page.
///
/// RSS feed payloads remain on ``RSSArticle``.  This record deliberately keeps
/// the extracted page and its validators separate so a later feed refresh
/// cannot overwrite a successful extraction. Rejected attempts may retain
/// candidate content for diagnostics, while a
/// ready record always has both renderable HTML and searchable plain text.
public struct RSSArticleFullTextRecord: Codable, Hashable, Identifiable, Sendable {
  public let articleID: String
  public let status: RSSArticleFullTextStatus
  public let contentHTML: String
  public let plainText: String
  public let sourceURL: URL?
  public let resolvedURL: URL?
  public let extractorIdentifier: String
  public let extractorVersion: String
  public let sourceETag: String?
  public let sourceLastModified: String?
  public let sourceContentHash: String?
  public let confidence: Double
  public let attemptedAt: Date
  public let retryAfter: Date?
  public let failureMessage: String?

  public var id: String { articleID }

  public static let defaultExtractorIdentifier = "unknown"
  public static let defaultExtractorVersion = "0"

  public init(
    articleID: String,
    status: RSSArticleFullTextStatus,
    contentHTML: String = "",
    plainText: String = "",
    sourceURL: URL? = nil,
    resolvedURL: URL? = nil,
    extractorIdentifier: String = RSSArticleFullTextRecord.defaultExtractorIdentifier,
    extractorVersion: String = RSSArticleFullTextRecord.defaultExtractorVersion,
    sourceETag: String? = nil,
    sourceLastModified: String? = nil,
    sourceContentHash: String? = nil,
    confidence: Double = 0,
    attemptedAt: Date = Date(),
    retryAfter: Date? = nil,
    failureMessage: String? = nil
  ) {
    let normalizedArticleID = articleID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedHTML = contentHTML
    let normalizedPlainText = plainText
    let hasContent = !normalizedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !normalizedPlainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // Keep the invariant that a ready record always has a payload.  An empty
    // ready result is a quality rejection rather than a cache hit.
    let normalizedStatus: RSSArticleFullTextStatus =
      status == .ready && !hasContent ? .rejected : status

    self.articleID = normalizedArticleID
    self.status = normalizedStatus
    self.contentHTML = normalizedHTML
    self.plainText = normalizedPlainText
    self.sourceURL = sourceURL
    self.resolvedURL = resolvedURL
    self.extractorIdentifier = Self.normalizedRequiredText(
      extractorIdentifier,
      fallback: Self.defaultExtractorIdentifier
    )
    self.extractorVersion = Self.normalizedRequiredText(
      extractorVersion,
      fallback: Self.defaultExtractorVersion
    )
    self.sourceETag = Self.normalizedOptionalText(sourceETag)
    self.sourceLastModified = Self.normalizedOptionalText(sourceLastModified)
    self.sourceContentHash = Self.normalizedOptionalText(sourceContentHash)
    self.confidence = Self.normalizedConfidence(confidence)
    self.attemptedAt = attemptedAt
    self.retryAfter = retryAfter
    self.failureMessage = Self.normalizedOptionalText(failureMessage)
  }

  /// Creates a successful extraction cache record.
  public static func ready(
    articleID: String,
    contentHTML: String,
    plainText: String,
    sourceURL: URL? = nil,
    resolvedURL: URL? = nil,
    extractorIdentifier: String = RSSArticleFullTextRecord.defaultExtractorIdentifier,
    extractorVersion: String = RSSArticleFullTextRecord.defaultExtractorVersion,
    sourceETag: String? = nil,
    sourceLastModified: String? = nil,
    sourceContentHash: String? = nil,
    confidence: Double,
    attemptedAt: Date = Date()
  ) -> RSSArticleFullTextRecord {
    RSSArticleFullTextRecord(
      articleID: articleID,
      status: .ready,
      contentHTML: contentHTML,
      plainText: plainText,
      sourceURL: sourceURL,
      resolvedURL: resolvedURL,
      extractorIdentifier: extractorIdentifier,
      extractorVersion: extractorVersion,
      sourceETag: sourceETag,
      sourceLastModified: sourceLastModified,
      sourceContentHash: sourceContentHash,
      confidence: confidence,
      attemptedAt: attemptedAt
    )
  }

  /// Creates a quality-gated rejection.  Rejections are persisted so callers
  /// can avoid repeatedly fetching a page that has already failed validation.
  public static func rejected(
    articleID: String,
    sourceURL: URL? = nil,
    resolvedURL: URL? = nil,
    extractorIdentifier: String = RSSArticleFullTextRecord.defaultExtractorIdentifier,
    extractorVersion: String = RSSArticleFullTextRecord.defaultExtractorVersion,
    sourceETag: String? = nil,
    sourceLastModified: String? = nil,
    sourceContentHash: String? = nil,
    confidence: Double = 0,
    attemptedAt: Date = Date(),
    retryAfter: Date? = nil,
    failureMessage: String? = nil,
    contentHTML: String = "",
    plainText: String = ""
  ) -> RSSArticleFullTextRecord {
    RSSArticleFullTextRecord(
      articleID: articleID,
      status: .rejected,
      contentHTML: contentHTML,
      plainText: plainText,
      sourceURL: sourceURL,
      resolvedURL: resolvedURL,
      extractorIdentifier: extractorIdentifier,
      extractorVersion: extractorVersion,
      sourceETag: sourceETag,
      sourceLastModified: sourceLastModified,
      sourceContentHash: sourceContentHash,
      confidence: confidence,
      attemptedAt: attemptedAt,
      retryAfter: retryAfter,
      failureMessage: failureMessage
    )
  }

  /// Creates a failed extraction.  Failed records may have no page payload,
  /// but retain validators and retry metadata when those are available.
  public static func failed(
    articleID: String,
    sourceURL: URL? = nil,
    resolvedURL: URL? = nil,
    extractorIdentifier: String = RSSArticleFullTextRecord.defaultExtractorIdentifier,
    extractorVersion: String = RSSArticleFullTextRecord.defaultExtractorVersion,
    sourceETag: String? = nil,
    sourceLastModified: String? = nil,
    sourceContentHash: String? = nil,
    confidence: Double = 0,
    attemptedAt: Date = Date(),
    retryAfter: Date? = nil,
    failureMessage: String? = nil,
    contentHTML: String = "",
    plainText: String = ""
  ) -> RSSArticleFullTextRecord {
    RSSArticleFullTextRecord(
      articleID: articleID,
      status: .failed,
      contentHTML: contentHTML,
      plainText: plainText,
      sourceURL: sourceURL,
      resolvedURL: resolvedURL,
      extractorIdentifier: extractorIdentifier,
      extractorVersion: extractorVersion,
      sourceETag: sourceETag,
      sourceLastModified: sourceLastModified,
      sourceContentHash: sourceContentHash,
      confidence: confidence,
      attemptedAt: attemptedAt,
      retryAfter: retryAfter,
      failureMessage: failureMessage
    )
  }

  private static func normalizedRequiredText(_ value: String, fallback: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? fallback : normalized
  }

  private static func normalizedOptionalText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func normalizedConfidence(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(1, max(0, value))
  }
}
