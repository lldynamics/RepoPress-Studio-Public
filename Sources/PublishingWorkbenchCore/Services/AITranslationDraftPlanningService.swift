import Foundation

public struct AITranslationDraftLink: Codable, Hashable, Sendable {
  public let sourceDraftID: ArticleDraft.ID
  public let translatedDraftID: ArticleDraft.ID
  public let targetLanguageCode: String
  public let sourceContentFingerprint: String
  public let createdAt: Date

  public init(
    sourceDraftID: ArticleDraft.ID,
    translatedDraftID: ArticleDraft.ID,
    targetLanguageCode: String,
    sourceContentFingerprint: String,
    createdAt: Date
  ) {
    self.sourceDraftID = sourceDraftID
    self.translatedDraftID = translatedDraftID
    self.targetLanguageCode = targetLanguageCode
    self.sourceContentFingerprint = sourceContentFingerprint
    self.createdAt = createdAt
  }
}

/// A pure plan for creating a linked translation as a new draft.
///
/// The source draft is represented only by identity and fingerprint. Applying
/// this plan returns `translatedDraft`; it never mutates or replaces the source.
public struct AITranslationDraftPlan: Codable, Hashable, Sendable {
  public let sourceDraftID: ArticleDraft.ID
  public let sourceContentFingerprint: String
  public let targetLanguageCode: String
  public let translatedDraft: ArticleDraft
  public let link: AITranslationDraftLink

  public init(
    sourceDraftID: ArticleDraft.ID,
    sourceContentFingerprint: String,
    targetLanguageCode: String,
    translatedDraft: ArticleDraft,
    link: AITranslationDraftLink
  ) {
    self.sourceDraftID = sourceDraftID
    self.sourceContentFingerprint = sourceContentFingerprint
    self.targetLanguageCode = targetLanguageCode
    self.translatedDraft = translatedDraft
    self.link = link
  }
}

public enum AITranslationDraftPlanningError: LocalizedError, Equatable, Sendable {
  case sourceBodyIsEmpty
  case targetLanguageIsEmpty
  case translatedTitleIsEmpty
  case translatedBodyIsEmpty
  case sourceDraftChanged
  case destinationReusesSourceIdentity

  public var errorDescription: String? {
    switch self {
    case .sourceBodyIsEmpty:
      return "原文章正文为空，无法创建全文翻译草稿。"
    case .targetLanguageIsEmpty:
      return "请选择目标语言。"
    case .translatedTitleIsEmpty:
      return "翻译后的标题为空。"
    case .translatedBodyIsEmpty:
      return "翻译后的正文为空。"
    case .sourceDraftChanged:
      return "原文章已变化，请重新生成翻译。"
    case .destinationReusesSourceIdentity:
      return "翻译草稿不能复用原文章标识。"
    }
  }
}

public enum AITranslationDraftPlanningService {
  public static func plan(
    source: ArticleDraft,
    targetLanguageCode: String,
    translatedTitle: String,
    translatedSummary: String,
    translatedBodyMarkdown: String,
    translatedSlug: String? = nil,
    destinationDraftID: ArticleDraft.ID = UUID(),
    plannedAt: Date = Date()
  ) throws -> AITranslationDraftPlan {
    let sourceBody = source.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sourceBody.isEmpty else {
      throw AITranslationDraftPlanningError.sourceBodyIsEmpty
    }
    let language = normalizedLanguageCode(targetLanguageCode)
    guard !language.isEmpty else {
      throw AITranslationDraftPlanningError.targetLanguageIsEmpty
    }
    let title = translatedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw AITranslationDraftPlanningError.translatedTitleIsEmpty
    }
    let body = translatedBodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      throw AITranslationDraftPlanningError.translatedBodyIsEmpty
    }
    guard destinationDraftID != source.id else {
      throw AITranslationDraftPlanningError.destinationReusesSourceIdentity
    }

    let slug = destinationSlug(
      sourceSlug: source.slug,
      translatedTitle: title,
      requestedSlug: translatedSlug,
      languageCode: language
    )
    let fingerprint = source.repositoryContentFingerprint
    let translatedDraft = ArticleDraft(
      id: destinationDraftID,
      siteProfileID: source.siteProfileID,
      scope: source.scope,
      title: title,
      date: source.date,
      slug: slug,
      tags: source.tags,
      categories: source.categories,
      authors: source.authors,
      draft: true,
      visibility: source.visibility,
      summary: translatedSummary.trimmingCharacters(in: .whitespacesAndNewlines),
      coverAttachmentID: source.coverAttachmentID,
      bodyMarkdown: body,
      attachments: source.attachments,
      status: .draft,
      createdAt: plannedAt,
      updatedAt: plannedAt,
      repositoryPath: nil,
      repositorySHA: nil,
      repositoryImportFingerprint: nil,
      reusedFromSourceSnapshot: nil,
      softwareGuideID: nil,
      softwareGuideTemplateVersion: nil
    )
    let link = AITranslationDraftLink(
      sourceDraftID: source.id,
      translatedDraftID: translatedDraft.id,
      targetLanguageCode: language,
      sourceContentFingerprint: fingerprint,
      createdAt: plannedAt
    )
    return AITranslationDraftPlan(
      sourceDraftID: source.id,
      sourceContentFingerprint: fingerprint,
      targetLanguageCode: language,
      translatedDraft: translatedDraft,
      link: link
    )
  }

  public static func materialize(
    _ plan: AITranslationDraftPlan,
    currentSource: ArticleDraft
  ) throws -> ArticleDraft {
    guard
      plan.sourceDraftID == currentSource.id,
      plan.sourceContentFingerprint == currentSource.repositoryContentFingerprint
    else {
      throw AITranslationDraftPlanningError.sourceDraftChanged
    }
    guard plan.translatedDraft.id != currentSource.id else {
      throw AITranslationDraftPlanningError.destinationReusesSourceIdentity
    }
    return plan.translatedDraft
  }

  private static func normalizedLanguageCode(_ value: String) -> String {
    String(
      value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "_", with: "-")
        .lowercased()
        .prefix(35)
    )
  }

  private static func destinationSlug(
    sourceSlug: String,
    translatedTitle: String,
    requestedSlug: String?,
    languageCode: String
  ) -> String {
    if let requested = requestedSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
      !requested.isEmpty
    {
      return SlugService.slug(from: requested)
    }
    let base = sourceSlug.trimmingCharacters(in: .whitespacesAndNewlines)
    if !base.isEmpty {
      return SlugService.slug(from: "\(base)-\(languageCode)")
    }
    return SlugService.slug(from: "\(translatedTitle)-\(languageCode)")
  }
}
