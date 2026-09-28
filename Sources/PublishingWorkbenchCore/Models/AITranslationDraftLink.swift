import Foundation

/// Stored on the translated article. The source article remains independent;
/// callers resolve `sourceDraftID` against the current draft collection.
public struct AITranslationDraftLink: Codable, Hashable, Sendable {
  public let sourceDraftID: ArticleDraft.ID
  public let translatedDraftID: ArticleDraft.ID
  public let targetLanguageCode: String
  public let sourceContentFingerprint: String
  public let createdAt: Date
  /// The source's planned repository path when the translation was created.
  /// Optional so plans written before native translation paths still decode.
  public var sourceMarkdownPath: String?
  /// Nil identifies snapshots created before translation-only fingerprints.
  public var sourceTranslationFingerprint: String?

  public init(
    sourceDraftID: ArticleDraft.ID,
    translatedDraftID: ArticleDraft.ID,
    targetLanguageCode: String,
    sourceContentFingerprint: String,
    createdAt: Date,
    sourceMarkdownPath: String? = nil,
    sourceTranslationFingerprint: String? = nil
  ) {
    self.sourceDraftID = sourceDraftID
    self.translatedDraftID = translatedDraftID
    self.targetLanguageCode = targetLanguageCode
    self.sourceContentFingerprint = sourceContentFingerprint
    self.createdAt = createdAt
    self.sourceMarkdownPath = sourceMarkdownPath
    self.sourceTranslationFingerprint = sourceTranslationFingerprint
  }
}

public enum ArticleTranslationFreshness: String, Codable, Equatable, Sendable {
  case current
  case stale
  case sourceMissing
}
