import Foundation

public enum AIPublishingActionContextRequirement: Equatable, Sendable {
  case selectedText
  case selectedTextOrBody
  case selectedTextOrArticleSeed
  case body
  case articleSeed
}

public struct AIPublishingActionAvailabilityPresentation: Equatable, Sendable {
  public var isEnabled: Bool
  public var unavailableReason: String?

  public init(isEnabled: Bool, unavailableReason: String? = nil) {
    self.isEnabled = isEnabled
    self.unavailableReason = unavailableReason
  }
}

public enum AIPublishingActionAvailabilityService {
  private static let publishingWhitespace = CharacterSet.whitespacesAndNewlines

  public static func canRun(
    _ action: AIPublishingActionKind,
    selectedText: String? = nil,
    draft: ArticleDraft
  ) -> Bool {
    switch action.contextRequirement {
    case .selectedText:
      return hasSelectedText(selectedText)
    case .selectedTextOrBody:
      return hasSelectedText(selectedText) || hasBodyText(draft)
    case .selectedTextOrArticleSeed:
      return hasSelectedText(selectedText) || hasArticleSeedText(draft)
    case .body:
      return hasBodyText(draft)
    case .articleSeed:
      return hasArticleSeedText(draft)
    }
  }

  public static func presentation(
    for action: AIPublishingActionKind,
    selectedText: String? = nil,
    draft: ArticleDraft,
    isAIEnabled: Bool = true,
    activeAction: AIPublishingActionKind? = nil
  ) -> AIPublishingActionAvailabilityPresentation {
    let hasRequiredContext = canRun(action, selectedText: selectedText, draft: draft)
    let isEnabled = activeAction == nil && isAIEnabled && hasRequiredContext
    return AIPublishingActionAvailabilityPresentation(
      isEnabled: isEnabled,
      unavailableReason: unavailableReason(
        for: action,
        hasRequiredContext: hasRequiredContext,
        isAIEnabled: isAIEnabled,
        activeAction: activeAction
      )
    )
  }

  private static func hasSelectedText(_ selectedText: String?) -> Bool {
    guard let selectedText else { return false }
    return hasPublishingText(selectedText)
  }

  private static func hasBodyText(_ draft: ArticleDraft) -> Bool {
    hasPublishingText(draft.bodyMarkdown)
  }

  private static func hasArticleSeedText(_ draft: ArticleDraft) -> Bool {
    hasBodyText(draft)
      || hasPublishingText(draft.title)
      || hasPublishingText(draft.summary)
  }

  /// Checks the same whitespace set used by `trimmedForPublishing` without
  /// allocating a trimmed copy. The scan stops at the first meaningful scalar,
  /// so normal non-empty drafts are constant-time while whitespace-only input
  /// still has the unavoidable linear cost of proving that it is empty.
  private static func hasPublishingText(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      !publishingWhitespace.contains(scalar)
    }
  }

  private static func unavailableReason(
    for action: AIPublishingActionKind,
    hasRequiredContext: Bool,
    isAIEnabled: Bool,
    activeAction: AIPublishingActionKind?
  ) -> String? {
    guard activeAction == nil else {
      return CoreL10n.text("AI 正在处理")
    }

    guard isAIEnabled else {
      return CoreL10n.text("需要先启用 AI")
    }

    guard !hasRequiredContext else {
      return nil
    }

    switch action.contextRequirement {
    case .selectedText:
      return CoreL10n.text("需要先选择正文")
    case .selectedTextOrBody:
      return CoreL10n.text("需要选择正文或补充文章正文")
    case .selectedTextOrArticleSeed:
      return CoreL10n.text("需要选择正文或补充标题、摘要、正文")
    case .body:
      return CoreL10n.text("需要先补充文章正文")
    case .articleSeed:
      return CoreL10n.text("需要先补充标题、摘要或正文")
    }
  }
}

public extension AIPublishingActionKind {
  var contextRequirement: AIPublishingActionContextRequirement {
    switch self {
    case .rewriteSelection, .polishSelection, .expandSelection, .continueAfterSelection,
      .condenseSelection, .removeRedundancySelection, .checklistSelection,
      .comparisonTableSelection, .explainSelection, .simplifySelection, .summarizeSelection,
      .translateSelectionToChinese, .translateSelectionToEnglish, .draftBilingualRewrite,
      .fixSelectionGrammar, .rewriteSelectionReaderFriendly, .rewriteSelectionFormal,
      .rewriteSelectionCasual, .rewriteSelectionTechnical, .sharpenOpeningSelection:
      return .selectedText
    case .continueArticle, .draftConclusion, .extractArticleKeyPoints, .extractArticleActionItems:
      return .selectedTextOrBody
    case .draftOpening, .draftOpeningHooks, .draftFullArticle, .suggestArticleOutline,
      .compareWritingAngles, .expandOutlineToDraft, .draftArticleTLDR, .draftReaderQuestions,
      .draftTransitionSection, .draftExampleSection, .draftStepByStepGuide,
      .draftTutorialVersion, .draftChecklistSection, .draftTroubleshootingSection,
      .draftCodeExample, .draftMermaidDiagram, .draftGlossary, .draftReferencesSection,
      .draftInterviewQA, .reorganizeStructure, .draftCounterpointSection, .draftCaseStudySection:
      return .selectedTextOrArticleSeed
    case .draftArticleFAQ:
      return .body
    case .titleSummaryTags, .suggestTitles, .suggestSlug, .suggestSummary, .suggestTags,
      .draftFrontMatterPack, .draftBilingualMetadata, .publishingReadiness, .privacyReview,
      .reviewContentGaps, .flagUnsupportedClaims, .draftSourceChecklist, .suggestInternalLinks,
      .auditLinkQuality, .auditImagePrivacy, .reviewSSGCompatibility, .reviewSEOReadability,
      .reviewReaderClarity, .reviewTechnicalAccuracy, .draftImageAltCaptions,
      .draftSocialShare, .draftPublishAssetPack, .draftPullQuotes, .draftPublishNote,
      .draftNewsletterSummary, .draftCoverImagePrompt, .draftCrossPlatformAnnouncement,
      .draftShortVideoScript, .suggestSeriesPlan, .draftContentRefreshPlan,
      .draftUpdateNote, .draftCommentReply, .pullRequestDescription:
      return .articleSeed
    }
  }
}
