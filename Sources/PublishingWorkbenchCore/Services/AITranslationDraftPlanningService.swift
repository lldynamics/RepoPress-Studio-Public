import Foundation
import PublishingCoreSupport

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
  case invalidTranslationLink

  public var errorDescription: String? {
    switch self {
    case .sourceBodyIsEmpty:
      return CoreL10n.text("原文章正文为空，无法创建全文翻译草稿。")
    case .targetLanguageIsEmpty:
      return CoreL10n.text("请选择有效的目标语言代码。")
    case .translatedTitleIsEmpty:
      return CoreL10n.text("翻译后的标题为空。")
    case .translatedBodyIsEmpty:
      return CoreL10n.text("翻译后的正文为空。")
    case .sourceDraftChanged:
      return CoreL10n.text("原文章已变化，请重新生成翻译。")
    case .destinationReusesSourceIdentity:
      return CoreL10n.text("翻译草稿不能复用原文章标识。")
    case .invalidTranslationLink:
      return CoreL10n.text("翻译计划中的文章关联不一致，请重新生成翻译。")
    }
  }
}

public enum AITranslationDraftPlanningService {
  public static func plan(
    source: ArticleDraft,
    profile: SiteProfile? = nil,
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
    guard isValidLanguageCode(language) else {
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
      languageCode: language,
      usesNativeTranslationPath: profile?.siteKind == .hugo || profile?.siteKind == .zola
    )
    let fingerprint = source.repositoryContentFingerprint
    let link = AITranslationDraftLink(
      sourceDraftID: source.id,
      translatedDraftID: destinationDraftID,
      targetLanguageCode: language,
      sourceContentFingerprint: fingerprint,
      createdAt: plannedAt,
      sourceMarkdownPath: profile?.markdownPath(for: source)
        ?? source.repositoryPath?.normalizedRelativePath().nilIfEmpty,
      sourceTranslationFingerprint: source.translationContentFingerprint
    )
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
      translationLink: link,
      softwareGuideID: nil,
      softwareGuideTemplateVersion: nil
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
    currentSource: ArticleDraft,
    profile: SiteProfile? = nil
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
    guard plan.link.sourceDraftID == currentSource.id,
      plan.link.translatedDraftID == plan.translatedDraft.id,
      plan.link.sourceContentFingerprint == plan.sourceContentFingerprint,
      plan.link.targetLanguageCode == plan.targetLanguageCode,
      isSafeSourceMarkdownPath(plan.link.sourceMarkdownPath)
    else {
      throw AITranslationDraftPlanningError.invalidTranslationLink
    }
    var translated = plan.translatedDraft
    var link = plan.link
    if link.sourceMarkdownPath == nil {
      link.sourceMarkdownPath =
        profile?.markdownPath(for: currentSource)
        ?? currentSource.repositoryPath?.normalizedRelativePath().nilIfEmpty
    }
    guard isSafeSourceMarkdownPath(link.sourceMarkdownPath) else {
      throw AITranslationDraftPlanningError.invalidTranslationLink
    }
    translated.translationLink = link
    return translated
  }

  private static func normalizedLanguageCode(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
  }

  private static func isValidLanguageCode(_ code: String) -> Bool {
    guard code.count <= 35 else { return false }
    return code.range(
      of: #"\A[a-z]{2,3}(?:-[a-z0-9]{2,8})*\z"#,
      options: .regularExpression
    ) != nil
  }

  private static func isSafeSourceMarkdownPath(_ path: String?) -> Bool {
    guard let path else { return true }
    let extensionName = (path as NSString).pathExtension.lowercased()
    return !path.isEmpty
      && !path.hasPrefix("/")
      && !path.contains("\\")
      && !path.contains("://")
      && !path.split(separator: "/").contains("..")
      && ["md", "markdown", "mdx"].contains(extensionName)
  }

  private static func destinationSlug(
    sourceSlug: String,
    translatedTitle: String,
    requestedSlug: String?,
    languageCode: String,
    usesNativeTranslationPath: Bool
  ) -> String {
    if let requested = requestedSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
      !requested.isEmpty
    {
      return SlugService.slug(from: requested)
    }
    let titleSlug = SlugService.slug(from: translatedTitle)
    let source = SlugService.slug(from: sourceSlug)
    if usesNativeTranslationPath { return titleSlug }
    if titleSlug != source { return titleSlug }
    return SlugService.slug(from: "\(source)-\(languageCode)")
  }
}
