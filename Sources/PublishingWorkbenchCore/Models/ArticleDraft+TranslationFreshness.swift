import CryptoKit
import Foundation

extension ArticleDraft {
  /// Changes here affect the words a translator needs to review. Publication
  /// state, dates, tags and other repository metadata are intentionally excluded.
  public var translationContentFingerprint: String {
    let content = [title, summary, bodyMarkdown]
      .map { "\($0.utf8.count):\($0)" }.joined()
    let data = Data(content.utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The source is read live; translated drafts do not need to be rewritten
  /// when source content changes.
  public func translationFreshness(
    source: ArticleDraft?,
    profile: SiteProfile? = nil
  ) -> ArticleTranslationFreshness? {
    guard let translationLink else { return nil }
    guard let source, source.id == translationLink.sourceDraftID else {
      return .sourceMissing
    }
    guard source.siteProfileID == siteProfileID else { return .stale }
    if let fingerprint = translationLink.sourceTranslationFingerprint {
      guard source.translationContentFingerprint == fingerprint else { return .stale }
    } else {
      // Older links stored the repository fingerprint. Permit a change in
      // publication state alone without silently accepting content edits.
      guard source.matchesLegacyTranslationFingerprint(translationLink.sourceContentFingerprint)
      else { return .stale }
    }
    if let profile, let originalPath = translationLink.sourceMarkdownPath,
      profile.markdownPath(for: source) != originalPath
    {
      return .stale
    }
    return .current
  }

  /// Explicit review advances both the content baseline and the expected path.
  /// Missing or mismatched sources cannot be acknowledged.
  @discardableResult
  public mutating func markTranslationReviewed(
    source: ArticleDraft?,
    profile: SiteProfile? = nil
  ) -> Bool {
    guard let source, let link = translationLink,
      source.id == link.sourceDraftID,
      link.translatedDraftID == id,
      source.siteProfileID == siteProfileID
    else { return false }
    translationLink = AITranslationDraftLink(
      sourceDraftID: source.id,
      translatedDraftID: id,
      targetLanguageCode: link.targetLanguageCode,
      sourceContentFingerprint: source.repositoryContentFingerprint,
      createdAt: link.createdAt,
      sourceMarkdownPath: profile?.markdownPath(for: source) ?? link.sourceMarkdownPath,
      sourceTranslationFingerprint: source.translationContentFingerprint
    )
    return true
  }

  private func matchesLegacyTranslationFingerprint(_ fingerprint: String) -> Bool {
    if repositoryContentFingerprint == fingerprint { return true }
    var source = self
    for draftValue in [false, true] {
      source.draft = draftValue
      for status in DraftStatus.allCases {
        source.status = status
        if source.repositoryContentFingerprint == fingerprint { return true }
      }
    }
    return false
  }
}
