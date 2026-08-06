import Foundation

public enum AIPublishingPromptLibraryScope: String, CaseIterable, Identifiable, Sendable {
  case all
  case writing
  case editing
  case publishing
  case distribution
  case maintenance

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .all:
      return "全部"
    case .writing:
      return AIPublishingQuickPromptGroup.writing.displayName
    case .editing:
      return AIPublishingQuickPromptGroup.editing.displayName
    case .publishing:
      return AIPublishingQuickPromptGroup.publishing.displayName
    case .distribution:
      return AIPublishingQuickPromptGroup.distribution.displayName
    case .maintenance:
      return AIPublishingQuickPromptGroup.maintenance.displayName
    }
  }

  public var systemImage: String {
    switch self {
    case .all:
      return "sparkles"
    case .writing:
      return AIPublishingQuickPromptGroup.writing.systemImage
    case .editing:
      return AIPublishingQuickPromptGroup.editing.systemImage
    case .publishing:
      return AIPublishingQuickPromptGroup.publishing.systemImage
    case .distribution:
      return AIPublishingQuickPromptGroup.distribution.systemImage
    case .maintenance:
      return AIPublishingQuickPromptGroup.maintenance.systemImage
    }
  }

  fileprivate func contains(_ group: AIPublishingQuickPromptGroup) -> Bool {
    switch self {
    case .all:
      return true
    case .writing:
      return group == .writing
    case .editing:
      return group == .editing
    case .publishing:
      return group == .publishing
    case .distribution:
      return group == .distribution
    case .maintenance:
      return group == .maintenance
    }
  }
}

public struct AIPublishingPromptLibrarySnapshot: Equatable, Sendable {
  public var selectedScope: AIPublishingPromptLibraryScope
  public var searchText: String
  public var recommendation: AIPublishingActionRecommendation?
  public var recommendedWorkflowGuides: [AIPublishingWorkflowGuide]
  public var workflowGuides: [AIPublishingWorkflowGuide]
  public var promptSections: [AIPublishingQuickPromptSection]
  public var spotlightActionSections: [AIPublishingEditorActionSection]
  public var editorActionSections: [AIPublishingEditorActionSection]

  public var hasVisibleContent: Bool {
    recommendation != nil
      || !recommendedWorkflowGuides.isEmpty
      || !workflowGuides.isEmpty
      || !promptSections.allSatisfy(\.prompts.isEmpty)
      || !spotlightActionSections.allSatisfy(\.actions.isEmpty)
      || !editorActionSections.allSatisfy(\.actions.isEmpty)
  }
}

public enum AIPublishingCapabilityCenterMode: String, CaseIterable, Identifiable, Sendable {
  case featured
  case all

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .featured:
      return "精选"
    case .all:
      return "全部能力"
    }
  }

  public var detail: String {
    switch self {
    case .featured:
      return "默认展示高频 AI 动作，保持聊天页轻量。"
    case .all:
      return "展开完整 AI 能力库；所有动作仍需手动点选才会运行。"
    }
  }
}

public struct AIPublishingCapabilityCenterSnapshot: Equatable, Sendable {
  public var mode: AIPublishingCapabilityCenterMode
  public var promptSections: [AIPublishingQuickPromptSection]
  public var editorActionSections: [AIPublishingEditorActionSection]

  public init(
    mode: AIPublishingCapabilityCenterMode,
    promptSections: [AIPublishingQuickPromptSection],
    editorActionSections: [AIPublishingEditorActionSection]
  ) {
    self.mode = mode
    self.promptSections = promptSections
    self.editorActionSections = editorActionSections
  }
}

public struct AIPublishingActionRecommendation: Equatable, Sendable {
  public var title: String
  public var description: String
  public var actions: [AIPublishingActionKind]

  public init(
    title: String,
    description: String,
    actions: [AIPublishingActionKind]
  ) {
    self.title = title
    self.description = description
    self.actions = actions
  }

  public var preferredScope: AIPublishingPromptLibraryScope {
    let groups = Set(actions.map(\.promptLibraryGroup))
    guard groups.count == 1, let group = groups.first else {
      return .all
    }
    return group.promptLibraryScope
  }
}

public struct AIPublishingEditorActionSection: Equatable, Identifiable, Sendable {
  public var group: AIPublishingQuickPromptGroup
  public var actions: [AIPublishingActionKind]

  public var id: AIPublishingQuickPromptGroup.ID {
    group.id
  }

  public init(
    group: AIPublishingQuickPromptGroup,
    actions: [AIPublishingActionKind]
  ) {
    self.group = group
    self.actions = actions
  }
}

public enum AIPublishingCapabilityCenterService {
  public static func snapshot(
    mode: AIPublishingCapabilityCenterMode
  ) -> AIPublishingCapabilityCenterSnapshot {
    switch mode {
    case .featured:
      return AIPublishingCapabilityCenterSnapshot(
        mode: mode,
        promptSections: AIPublishingQuickPrompt.featuredCapabilitySections,
        editorActionSections: editorActionSections(
          for: AIPublishingDefaultCapability.defaultActionKinds
        )
      )
    case .all:
      return AIPublishingCapabilityCenterSnapshot(
        mode: mode,
        promptSections: AIPublishingQuickPrompt.capabilitySections,
        editorActionSections: editorActionSections(for: AIPublishingActionKind.promptLibraryActions)
      )
    }
  }

  private static func editorActionSections(
    for actions: [AIPublishingActionKind]
  ) -> [AIPublishingEditorActionSection] {
    AIPublishingQuickPromptGroup.allCases.compactMap { group in
      let groupActions = actions.filter { $0.promptLibraryGroup == group }
      guard !groupActions.isEmpty else {
        return nil
      }
      return AIPublishingEditorActionSection(group: group, actions: groupActions)
    }
  }
}

public struct AIPublishingActionMenuItem: Equatable, Identifiable, Sendable {
  public var kind: AIPublishingActionKind
  public var systemImage: String

  public var id: AIPublishingActionKind.ID {
    kind.id
  }

  public init(kind: AIPublishingActionKind, systemImage: String) {
    self.kind = kind
    self.systemImage = systemImage
  }
}

public enum AIPublishingPromptLibraryService {
  public static func snapshot(
    selectedScope: AIPublishingPromptLibraryScope = .all,
    searchText: String = "",
    recommendation: AIPublishingActionRecommendation? = nil
  ) -> AIPublishingPromptLibrarySnapshot {
    let query = searchText.trimmedForPublishing
    let visibleRecommendation = visibleRecommendation(
      recommendation,
      selectedScope: selectedScope,
      query: query
    )
    let recommendedWorkflowGuides = recommendedWorkflowGuides(
      selectedScope: selectedScope,
      query: query,
      recommendation: recommendation
    )
    let recommendedActionSet = Set(visibleRecommendation?.actions ?? [])
    let guides = AIPublishingWorkflowGuide.featuredGuides.filter {
      selectedScope.matches($0)
        && matchesWorkflowGuide($0, query: query)
        && !recommendedWorkflowGuides.contains($0)
    }
    let sections: [AIPublishingQuickPromptSection] = AIPublishingQuickPrompt.capabilitySections.compactMap { section in
      guard selectedScope.contains(section.group) else {
        return nil
      }
      let prompts = section.prompts.filter { matchesPrompt($0, query: query) }
      guard !prompts.isEmpty else {
        return nil
      }
      return AIPublishingQuickPromptSection(group: section.group, prompts: prompts)
    }
    let spotlightActionSections = spotlightActionSections(
      selectedScope: selectedScope,
      query: query,
      excludedActions: recommendedActionSet
    )
    let spotlightActionSet = Set(spotlightActionSections.flatMap(\.actions))
    let editorActionSections: [AIPublishingEditorActionSection] = AIPublishingQuickPromptGroup.allCases.compactMap { group in
      guard selectedScope.contains(group) else {
        return nil
      }
      let actions = AIPublishingActionKind.promptLibraryActions.filter { action in
        action.promptLibraryGroup == group
          && (!query.isEmpty || !action.isCompactMenuVariant)
          && matchesEditorAction(action, query: query)
          && !recommendedActionSet.contains(action)
          && !spotlightActionSet.contains(action)
      }
      guard !actions.isEmpty else {
        return nil
      }
      return AIPublishingEditorActionSection(group: group, actions: actions)
    }

    return AIPublishingPromptLibrarySnapshot(
      selectedScope: selectedScope,
      searchText: query,
      recommendation: visibleRecommendation,
      recommendedWorkflowGuides: recommendedWorkflowGuides,
      workflowGuides: guides,
      promptSections: sections,
      spotlightActionSections: spotlightActionSections,
      editorActionSections: editorActionSections
    )
  }

  public static func snapshot(
    selectedScope: AIPublishingPromptLibraryScope = .all,
    searchText: String = "",
    selectedText: String? = nil,
    draft: ArticleDraft
  ) -> AIPublishingPromptLibrarySnapshot {
    snapshot(
      selectedScope: selectedScope,
      searchText: searchText,
      recommendation: AIPublishingActionRecommendationService.recommendation(
        selectedText: selectedText,
        draft: draft
      )
    )
  }

  private static func visibleRecommendation(
    _ recommendation: AIPublishingActionRecommendation?,
    selectedScope: AIPublishingPromptLibraryScope,
    query: String
  ) -> AIPublishingActionRecommendation? {
    guard query.isEmpty, var recommendation else {
      return nil
    }
    recommendation.actions = recommendation.actions.filter(selectedScope.contains)
    return recommendation.actions.isEmpty ? nil : recommendation
  }

  private static func recommendedWorkflowGuides(
    selectedScope: AIPublishingPromptLibraryScope,
    query: String,
    recommendation: AIPublishingActionRecommendation?
  ) -> [AIPublishingWorkflowGuide] {
    guard query.isEmpty else {
      return []
    }

    let targetScope = selectedScope == .all
      ? (recommendation?.preferredScope ?? .all)
      : selectedScope

    return recommendedWorkflowGuideIDs(for: targetScope).compactMap { guideID in
      let guide = AIPublishingWorkflowGuide.featuredGuides.first { $0.id == guideID }
      guard let guide, selectedScope == .all || selectedScope.matches(guide) else {
        return nil
      }
      return guide
    }
  }

  private static func recommendedWorkflowGuideIDs(
    for scope: AIPublishingPromptLibraryScope
  ) -> [AIPublishingWorkflowGuide.ID] {
    switch scope {
    case .editing:
      return ["selection-rewrite", "selection-to-structure", "bilingual-release-kit"]
    case .publishing:
      return ["front-matter-pack", "publish-readiness", "evidence-and-reader-review"]
    case .distribution:
      return ["distribution-pack", "multi-channel-distribution", "refresh-and-series-plan"]
    case .maintenance:
      return ["site-maintenance-assistant", "refresh-and-series-plan", "evidence-and-reader-review"]
    case .writing:
      return ["idea-to-draft", "draft-to-finished-article", "technical-explainer-kit"]
    case .all:
      return ["idea-to-draft", "selection-rewrite", "publish-readiness", "distribution-pack"]
    }
  }

  private static func matchesWorkflowGuide(
    _ guide: AIPublishingWorkflowGuide,
    query: String
  ) -> Bool {
    guard !query.isEmpty else {
      return true
    }
    let values = [
      guide.id,
      guide.title,
      guide.description,
      guide.actionPreview,
    ] + guide.prompts.flatMap { prompt in
      [prompt.rawValue, prompt.displayName, prompt.group.displayName]
    }
    return values.contains { matches($0, query: query) }
  }

  private static func matchesPrompt(
    _ prompt: AIPublishingQuickPrompt,
    query: String
  ) -> Bool {
    guard !query.isEmpty else {
      return true
    }
    return [
      prompt.rawValue,
      prompt.displayName,
      prompt.group.displayName,
      prompt.group.detail,
    ].contains { matches($0, query: query) }
  }

  private static func matchesEditorAction(
    _ action: AIPublishingActionKind,
    query: String
  ) -> Bool {
    guard !query.isEmpty else {
      return true
    }
    return [
      action.rawValue,
      action.displayName,
      action.promptLibraryDescription,
      action.promptLibraryGroup.displayName,
      action.promptLibraryGroup.detail,
    ].contains { matches($0, query: query) }
  }

  private static func spotlightActionSections(
    selectedScope: AIPublishingPromptLibraryScope,
    query: String,
    excludedActions: Set<AIPublishingActionKind>
  ) -> [AIPublishingEditorActionSection] {
    AIPublishingWritingActionCatalog.promptLibrarySpotlightSections.compactMap { section in
      guard selectedScope.contains(section.group) else {
        return nil
      }
      let actions = section.actions.filter { action in
        selectedScope.contains(action)
          && matchesEditorAction(action, query: query)
          && !excludedActions.contains(action)
      }
      guard !actions.isEmpty else {
        return nil
      }
      return AIPublishingEditorActionSection(group: section.group, actions: actions)
    }
  }

  private static func matches(_ value: String, query: String) -> Bool {
    value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}

public enum AIPublishingActionRecommendationService {
  public static func recommendation(
    selectedText: String? = nil,
    draft: ArticleDraft
  ) -> AIPublishingActionRecommendation {
    if hasText(selectedText) {
      return AIPublishingActionRecommendation(
        title: "推荐动作",
        description: "当前选区可直接改写、压缩或翻译。",
        actions: AIPublishingWritingActionCatalog.selectedTextRecommendedEditorActions.map(\.kind)
      )
    }

    if hasText(draft.bodyMarkdown) {
      return AIPublishingActionRecommendation(
        title: "推荐动作",
        description: "当前正文可续写、生成元数据、引用资料并做发布检查。",
        actions: [
          .continueArticle,
          .draftFrontMatterPack,
          .publishingReadiness,
          .draftReferencesSection,
        ]
      )
    }

    if hasText(draft.title) || hasText(draft.summary) {
      return AIPublishingActionRecommendation(
        title: "推荐动作",
        description: "当前标题或摘要可生成元数据并进入发布检查。",
        actions: [
          .draftFrontMatterPack,
          .publishingReadiness,
        ]
      )
    }

    return AIPublishingActionRecommendation(
      title: "推荐动作",
      description: "可先自由提问，或写下标题、摘要和正文后使用默认动作。",
      actions: []
    )
  }

  private static func hasText(_ value: String?) -> Bool {
    !(value ?? "").trimmedForPublishing.isEmpty
  }
}

public enum AIPublishingWritingActionCatalog {
  public static let promptLibrarySpotlightSections: [AIPublishingEditorActionSection] = [
    AIPublishingEditorActionSection(
      group: .writing,
      actions: [
        .continueArticle,
        .draftOpening,
        .draftFullArticle,
        .compareWritingAngles,
        .expandOutlineToDraft,
        .draftArticleTLDR,
        .draftArticleFAQ,
        .draftReaderQuestions,
      ]
    ),
    AIPublishingEditorActionSection(
      group: .editing,
      actions: [
        .rewriteSelection,
        .fixSelectionGrammar,
        .translateSelectionToChinese,
        .translateSelectionToEnglish,
        .draftBilingualRewrite,
        .summarizeSelection,
      ]
    ),
    AIPublishingEditorActionSection(
      group: .publishing,
      actions: [
        .publishingReadiness,
        .reviewContentGaps,
        .reviewTechnicalAccuracy,
        .reviewSEOReadability,
        .suggestInternalLinks,
        .privacyReview,
        .auditLinkQuality,
        .reviewSSGCompatibility,
        .flagUnsupportedClaims,
        .draftSourceChecklist,
      ]
    ),
    AIPublishingEditorActionSection(
      group: .distribution,
      actions: [
        .draftImageAltCaptions,
        .draftSocialShare,
        .draftPublishAssetPack,
        .draftPullQuotes,
        .draftPublishNote,
        .draftNewsletterSummary,
        .draftCoverImagePrompt,
        .draftShortVideoScript,
      ]
    ),
    AIPublishingEditorActionSection(
      group: .maintenance,
      actions: [
        .suggestSeriesPlan,
        .draftContentRefreshPlan,
        .draftUpdateNote,
        .draftCommentReply,
      ]
    ),
  ]

  public static let selectionActions: [AIPublishingActionMenuItem] = [
    AIPublishingActionMenuItem(kind: .rewriteSelection, systemImage: "wand.and.stars"),
    AIPublishingActionMenuItem(kind: .expandSelection, systemImage: "arrow.up.left.and.arrow.down.right"),
    AIPublishingActionMenuItem(kind: .continueAfterSelection, systemImage: "text.append"),
    AIPublishingActionMenuItem(kind: .condenseSelection, systemImage: "arrow.down.right.and.arrow.up.left"),
    AIPublishingActionMenuItem(kind: .removeRedundancySelection, systemImage: "eraser"),
    AIPublishingActionMenuItem(kind: .checklistSelection, systemImage: "checklist.checked"),
    AIPublishingActionMenuItem(kind: .comparisonTableSelection, systemImage: "tablecells"),
    AIPublishingActionMenuItem(kind: .explainSelection, systemImage: "text.bubble"),
    AIPublishingActionMenuItem(kind: .simplifySelection, systemImage: "textformat.abc"),
    AIPublishingActionMenuItem(kind: .summarizeSelection, systemImage: "text.badge.star"),
    AIPublishingActionMenuItem(kind: .translateSelectionToChinese, systemImage: "character.book.closed.zh"),
    AIPublishingActionMenuItem(kind: .translateSelectionToEnglish, systemImage: "character.book.closed"),
    AIPublishingActionMenuItem(kind: .draftBilingualRewrite, systemImage: "character.book.closed"),
    AIPublishingActionMenuItem(kind: .fixSelectionGrammar, systemImage: "checkmark.seal"),
  ]

  public static let selectedTextRecommendedEditorActions: [AIPublishingActionMenuItem] = [
    AIPublishingActionMenuItem(kind: .rewriteSelection, systemImage: "wand.and.stars"),
    AIPublishingActionMenuItem(kind: .condenseSelection, systemImage: "arrow.down.right.and.arrow.up.left"),
    AIPublishingActionMenuItem(kind: .translateSelectionToChinese, systemImage: "character.book.closed.zh"),
    AIPublishingActionMenuItem(kind: .translateSelectionToEnglish, systemImage: "character.book.closed"),
  ]

  public static let writingActions: [AIPublishingActionMenuItem] = [
    AIPublishingActionMenuItem(kind: .continueArticle, systemImage: "text.append"),
    AIPublishingActionMenuItem(kind: .draftOpening, systemImage: "text.line.first.and.arrowtriangle.forward"),
    AIPublishingActionMenuItem(kind: .draftFullArticle, systemImage: "doc.text"),
    AIPublishingActionMenuItem(kind: .suggestArticleOutline, systemImage: "list.bullet.rectangle"),
    AIPublishingActionMenuItem(kind: .compareWritingAngles, systemImage: "arrow.triangle.branch"),
    AIPublishingActionMenuItem(kind: .expandOutlineToDraft, systemImage: "text.insert"),
    AIPublishingActionMenuItem(kind: .draftConclusion, systemImage: "flag.checkered"),
    AIPublishingActionMenuItem(kind: .draftArticleTLDR, systemImage: "text.badge.star"),
    AIPublishingActionMenuItem(kind: .draftArticleFAQ, systemImage: "questionmark.bubble"),
    AIPublishingActionMenuItem(kind: .draftReaderQuestions, systemImage: "questionmark.bubble"),
    AIPublishingActionMenuItem(kind: .draftTransitionSection, systemImage: "arrow.left.and.right.text.vertical"),
    AIPublishingActionMenuItem(kind: .draftExampleSection, systemImage: "lightbulb"),
    AIPublishingActionMenuItem(kind: .draftStepByStepGuide, systemImage: "list.number"),
    AIPublishingActionMenuItem(kind: .draftTutorialVersion, systemImage: "graduationcap"),
    AIPublishingActionMenuItem(kind: .draftChecklistSection, systemImage: "checklist.checked"),
    AIPublishingActionMenuItem(kind: .draftTroubleshootingSection, systemImage: "stethoscope"),
    AIPublishingActionMenuItem(kind: .draftCodeExample, systemImage: "chevron.left.forwardslash.chevron.right"),
    AIPublishingActionMenuItem(kind: .draftMermaidDiagram, systemImage: "point.3.connected.trianglepath.dotted"),
    AIPublishingActionMenuItem(kind: .draftGlossary, systemImage: "text.book.closed"),
    AIPublishingActionMenuItem(kind: .draftReferencesSection, systemImage: "books.vertical"),
    AIPublishingActionMenuItem(kind: .draftInterviewQA, systemImage: "person.2.wave.2"),
    AIPublishingActionMenuItem(kind: .reorganizeStructure, systemImage: "arrow.up.arrow.down"),
    AIPublishingActionMenuItem(kind: .draftCounterpointSection, systemImage: "arrow.left.arrow.right"),
    AIPublishingActionMenuItem(kind: .draftCaseStudySection, systemImage: "doc.text.magnifyingglass"),
    AIPublishingActionMenuItem(kind: .extractArticleKeyPoints, systemImage: "list.bullet.clipboard"),
    AIPublishingActionMenuItem(kind: .extractArticleActionItems, systemImage: "checklist.checked"),
  ]

  public static let publishingActions: [AIPublishingActionMenuItem] = [
    AIPublishingActionMenuItem(kind: .publishingReadiness, systemImage: "checkmark.shield"),
    AIPublishingActionMenuItem(kind: .suggestTitles, systemImage: "textformat.size"),
    AIPublishingActionMenuItem(kind: .suggestSlug, systemImage: "number"),
    AIPublishingActionMenuItem(kind: .suggestSummary, systemImage: "text.quote"),
    AIPublishingActionMenuItem(kind: .suggestTags, systemImage: "tag"),
    AIPublishingActionMenuItem(kind: .draftFrontMatterPack, systemImage: "list.bullet.rectangle.portrait"),
    AIPublishingActionMenuItem(kind: .draftBilingualMetadata, systemImage: "character.book.closed"),
    AIPublishingActionMenuItem(kind: .reviewContentGaps, systemImage: "rectangle.badge.questionmark"),
    AIPublishingActionMenuItem(kind: .flagUnsupportedClaims, systemImage: "exclamationmark.bubble"),
    AIPublishingActionMenuItem(kind: .draftSourceChecklist, systemImage: "checklist"),
    AIPublishingActionMenuItem(kind: .privacyReview, systemImage: "lock.shield"),
    AIPublishingActionMenuItem(kind: .suggestInternalLinks, systemImage: "link.badge.plus"),
    AIPublishingActionMenuItem(kind: .auditLinkQuality, systemImage: "link"),
    AIPublishingActionMenuItem(kind: .auditImagePrivacy, systemImage: "photo.badge.exclamationmark"),
    AIPublishingActionMenuItem(kind: .reviewSSGCompatibility, systemImage: "curlybraces"),
    AIPublishingActionMenuItem(kind: .reviewSEOReadability, systemImage: "magnifyingglass"),
    AIPublishingActionMenuItem(kind: .reviewReaderClarity, systemImage: "person.text.rectangle"),
    AIPublishingActionMenuItem(kind: .reviewTechnicalAccuracy, systemImage: "checkmark.seal"),
  ]

  public static let distributionActions: [AIPublishingActionMenuItem] = [
    AIPublishingActionMenuItem(kind: .draftImageAltCaptions, systemImage: "photo.on.rectangle.angled"),
    AIPublishingActionMenuItem(kind: .draftSocialShare, systemImage: "megaphone"),
    AIPublishingActionMenuItem(kind: .draftPublishAssetPack, systemImage: "shippingbox"),
    AIPublishingActionMenuItem(kind: .draftPullQuotes, systemImage: "quote.bubble"),
    AIPublishingActionMenuItem(kind: .draftPublishNote, systemImage: "arrow.up.doc"),
    AIPublishingActionMenuItem(kind: .draftNewsletterSummary, systemImage: "newspaper"),
    AIPublishingActionMenuItem(kind: .draftCoverImagePrompt, systemImage: "photo.artframe"),
    AIPublishingActionMenuItem(kind: .draftCrossPlatformAnnouncement, systemImage: "rectangle.3.group.bubble"),
    AIPublishingActionMenuItem(kind: .draftShortVideoScript, systemImage: "play.rectangle"),
    AIPublishingActionMenuItem(kind: .pullRequestDescription, systemImage: "doc.text"),
  ]

  public static let maintenanceActions: [AIPublishingActionMenuItem] = [
    AIPublishingActionMenuItem(kind: .suggestSeriesPlan, systemImage: "rectangle.stack.badge.plus"),
    AIPublishingActionMenuItem(kind: .draftContentRefreshPlan, systemImage: "arrow.triangle.2.circlepath"),
    AIPublishingActionMenuItem(kind: .draftUpdateNote, systemImage: "note.text"),
    AIPublishingActionMenuItem(kind: .draftCommentReply, systemImage: "bubble.left.and.bubble.right"),
  ]

  public static let articleActions: [AIPublishingActionMenuItem] = writingActions
    + publishingActions
    + distributionActions
    + maintenanceActions
}

private extension AIPublishingPromptLibraryScope {
  func matches(_ guide: AIPublishingWorkflowGuide) -> Bool {
    guide.prompts.contains { contains($0.group) }
  }

  func contains(_ action: AIPublishingActionKind) -> Bool {
    contains(action.promptLibraryGroup)
  }
}

private extension AIPublishingQuickPromptGroup {
  var promptLibraryScope: AIPublishingPromptLibraryScope {
    switch self {
    case .writing:
      return .writing
    case .editing:
      return .editing
    case .publishing:
      return .publishing
    case .distribution:
      return .distribution
    case .maintenance:
      return .maintenance
    }
  }
}

public extension AIPublishingActionKind {
  static let promptLibraryActions: [AIPublishingActionKind] = [
    .continueArticle,
    .draftOpening,
    .sharpenOpeningSelection,
    .draftOpeningHooks,
    .draftFullArticle,
    .suggestArticleOutline,
    .compareWritingAngles,
    .expandOutlineToDraft,
    .draftConclusion,
    .draftArticleTLDR,
    .draftArticleFAQ,
    .draftReaderQuestions,
    .draftTransitionSection,
    .draftExampleSection,
    .draftStepByStepGuide,
    .draftTutorialVersion,
    .draftChecklistSection,
    .draftTroubleshootingSection,
    .draftCodeExample,
    .draftMermaidDiagram,
    .draftGlossary,
    .draftReferencesSection,
    .draftInterviewQA,
    .reorganizeStructure,
    .draftCounterpointSection,
    .draftCaseStudySection,
    .extractArticleKeyPoints,
    .extractArticleActionItems,
    .rewriteSelection,
    .polishSelection,
    .expandSelection,
    .continueAfterSelection,
    .condenseSelection,
    .removeRedundancySelection,
    .checklistSelection,
    .comparisonTableSelection,
    .explainSelection,
    .simplifySelection,
    .summarizeSelection,
    .translateSelectionToChinese,
    .translateSelectionToEnglish,
    .draftBilingualRewrite,
    .fixSelectionGrammar,
    .rewriteSelectionReaderFriendly,
    .rewriteSelectionFormal,
    .rewriteSelectionCasual,
    .rewriteSelectionTechnical,
    .titleSummaryTags,
    .suggestTitles,
    .suggestSlug,
    .suggestSummary,
    .suggestTags,
    .draftFrontMatterPack,
    .draftBilingualMetadata,
    .publishingReadiness,
    .privacyReview,
    .reviewContentGaps,
    .flagUnsupportedClaims,
    .draftSourceChecklist,
    .suggestInternalLinks,
    .auditLinkQuality,
    .auditImagePrivacy,
    .reviewSSGCompatibility,
    .reviewSEOReadability,
    .reviewReaderClarity,
    .reviewTechnicalAccuracy,
    .draftImageAltCaptions,
    .draftSocialShare,
    .draftPublishAssetPack,
    .draftPullQuotes,
    .draftPublishNote,
    .draftNewsletterSummary,
    .draftCoverImagePrompt,
    .draftCrossPlatformAnnouncement,
    .draftShortVideoScript,
    .suggestSeriesPlan,
    .draftContentRefreshPlan,
    .draftUpdateNote,
    .draftCommentReply,
    .pullRequestDescription,
  ]

  var promptLibraryGroup: AIPublishingQuickPromptGroup {
    switch self {
    case .continueArticle, .draftOpening, .draftOpeningHooks, .draftFullArticle, .suggestArticleOutline,
      .compareWritingAngles, .expandOutlineToDraft, .draftConclusion, .draftArticleTLDR, .draftArticleFAQ,
      .draftReaderQuestions, .draftTransitionSection, .draftExampleSection, .draftStepByStepGuide,
      .draftTutorialVersion, .draftChecklistSection, .draftTroubleshootingSection, .draftCodeExample,
      .draftMermaidDiagram, .draftGlossary, .draftReferencesSection, .draftInterviewQA,
      .reorganizeStructure, .draftCounterpointSection, .draftCaseStudySection,
      .extractArticleKeyPoints, .extractArticleActionItems:
      return .writing
    case .sharpenOpeningSelection, .rewriteSelection, .polishSelection, .expandSelection, .continueAfterSelection,
      .condenseSelection, .removeRedundancySelection, .checklistSelection,
      .comparisonTableSelection, .explainSelection, .simplifySelection, .summarizeSelection,
      .translateSelectionToChinese, .translateSelectionToEnglish, .draftBilingualRewrite, .fixSelectionGrammar,
      .rewriteSelectionReaderFriendly, .rewriteSelectionFormal, .rewriteSelectionCasual,
      .rewriteSelectionTechnical:
      return .editing
    case .titleSummaryTags, .suggestTitles, .suggestSlug, .suggestSummary, .suggestTags,
      .draftFrontMatterPack, .draftBilingualMetadata, .publishingReadiness, .privacyReview,
      .reviewContentGaps, .flagUnsupportedClaims, .draftSourceChecklist, .suggestInternalLinks,
      .auditLinkQuality, .auditImagePrivacy, .reviewSSGCompatibility, .reviewSEOReadability,
      .reviewReaderClarity, .reviewTechnicalAccuracy:
      return .publishing
    case .draftImageAltCaptions, .draftSocialShare, .draftPublishAssetPack,
      .draftPullQuotes, .draftPublishNote, .draftNewsletterSummary, .draftCoverImagePrompt,
      .draftCrossPlatformAnnouncement, .draftShortVideoScript, .pullRequestDescription:
      return .distribution
    case .suggestSeriesPlan, .draftContentRefreshPlan, .draftUpdateNote, .draftCommentReply:
      return .maintenance
    }
  }

  var promptLibrarySystemImage: String {
    switch self {
    case .publishingReadiness:
      return "checkmark.shield"
    case .continueArticle, .continueAfterSelection:
      return "text.append"
    case .draftOpening, .sharpenOpeningSelection, .draftOpeningHooks:
      return "text.line.first.and.arrowtriangle.forward"
    case .draftFullArticle:
      return "doc.text"
    case .suggestArticleOutline:
      return "list.bullet.rectangle"
    case .compareWritingAngles:
      return "arrow.triangle.branch"
    case .expandOutlineToDraft:
      return "text.insert"
    case .draftConclusion:
      return "flag.checkered"
    case .draftArticleTLDR, .summarizeSelection:
      return "text.badge.star"
    case .draftArticleFAQ, .draftReaderQuestions:
      return "questionmark.bubble"
    case .draftTransitionSection:
      return "arrow.left.and.right.text.vertical"
    case .draftExampleSection:
      return "lightbulb"
    case .draftStepByStepGuide:
      return "list.number"
    case .draftTutorialVersion:
      return "graduationcap"
    case .draftChecklistSection:
      return "checklist"
    case .draftTroubleshootingSection:
      return "stethoscope"
    case .draftCodeExample:
      return "chevron.left.forwardslash.chevron.right"
    case .draftMermaidDiagram:
      return "point.3.connected.trianglepath.dotted"
    case .draftGlossary:
      return "character.book.closed"
    case .draftReferencesSection:
      return "books.vertical"
    case .draftInterviewQA:
      return "person.2.wave.2"
    case .reorganizeStructure:
      return "arrow.up.arrow.down"
    case .draftCounterpointSection:
      return "scale.3d"
    case .draftCaseStudySection:
      return "briefcase"
    case .extractArticleKeyPoints:
      return "list.bullet.clipboard"
    case .extractArticleActionItems, .checklistSelection:
      return "checklist.checked"
    case .rewriteSelection:
      return "wand.and.stars"
    case .polishSelection:
      return "sparkles"
    case .expandSelection:
      return "arrow.up.left.and.arrow.down.right"
    case .condenseSelection:
      return "arrow.down.right.and.arrow.up.left"
    case .removeRedundancySelection:
      return "eraser"
    case .comparisonTableSelection:
      return "tablecells"
    case .explainSelection:
      return "text.bubble"
    case .simplifySelection:
      return "textformat.abc"
    case .translateSelectionToChinese:
      return "character.book.closed.zh"
    case .translateSelectionToEnglish, .draftBilingualRewrite:
      return "character.book.closed"
    case .fixSelectionGrammar:
      return "checkmark.seal"
    case .rewriteSelectionReaderFriendly:
      return "person.text.rectangle"
    case .rewriteSelectionFormal:
      return "textformat"
    case .rewriteSelectionCasual:
      return "bubble.left.and.text.bubble.right"
    case .rewriteSelectionTechnical:
      return "chevron.left.forwardslash.chevron.right"
    case .titleSummaryTags:
      return "rectangle.and.pencil.and.ellipsis"
    case .suggestTitles:
      return "textformat.size"
    case .suggestSlug:
      return "number"
    case .suggestSummary:
      return "text.quote"
    case .suggestTags:
      return "tag"
    case .draftFrontMatterPack:
      return "list.bullet.rectangle.portrait"
    case .draftBilingualMetadata:
      return "character.book.closed"
    case .privacyReview:
      return "lock.shield"
    case .reviewContentGaps:
      return "rectangle.badge.questionmark"
    case .flagUnsupportedClaims:
      return "exclamationmark.bubble"
    case .draftSourceChecklist:
      return "checklist"
    case .suggestInternalLinks:
      return "link.badge.plus"
    case .auditLinkQuality:
      return "link"
    case .auditImagePrivacy:
      return "photo.badge.exclamationmark"
    case .reviewSSGCompatibility:
      return "curlybraces"
    case .reviewSEOReadability:
      return "magnifyingglass"
    case .reviewReaderClarity:
      return "person.text.rectangle"
    case .reviewTechnicalAccuracy:
      return "checkmark.seal"
    case .draftImageAltCaptions:
      return "photo.on.rectangle.angled"
    case .draftSocialShare:
      return "megaphone"
    case .draftPublishAssetPack:
      return "shippingbox"
    case .draftPullQuotes:
      return "quote.bubble"
    case .draftPublishNote:
      return "arrow.up.doc"
    case .draftNewsletterSummary:
      return "newspaper"
    case .draftCoverImagePrompt:
      return "photo.artframe"
    case .draftCrossPlatformAnnouncement:
      return "rectangle.3.group.bubble"
    case .draftShortVideoScript:
      return "play.rectangle"
    case .suggestSeriesPlan:
      return "rectangle.stack.badge.plus"
    case .draftContentRefreshPlan:
      return "arrow.triangle.2.circlepath"
    case .draftUpdateNote:
      return "note.text"
    case .draftCommentReply:
      return "bubble.left.and.bubble.right"
    case .pullRequestDescription:
      return "doc.text"
    }
  }

  var promptLibraryDescription: String {
    switch self {
    case .publishingReadiness:
      return "围绕当前文章、发布包、检查结果和图片状态生成发布前建议。"
    case .continueArticle:
      return "基于当前正文或选区继续写后续正文。"
    case .draftOpening:
      return "生成可直接插入正文开头的导入小节。"
    case .sharpenOpeningSelection:
      return "优化选中的开头段，更快进入主题并保留事实边界。"
    case .draftOpeningHooks:
      return "生成多个可选开头钩子，帮助确定文章进入方式。"
    case .draftFullArticle:
      return "基于标题、摘要和正文种子生成完整 Markdown 初稿。"
    case .suggestArticleOutline:
      return "生成适合插入正文的文章大纲和小节要点。"
    case .compareWritingAngles:
      return "比较不同写作角度、目标读者、结构和风险。"
    case .expandOutlineToDraft:
      return "把现有大纲、要点或草稿骨架扩写成连续正文。"
    case .draftConclusion:
      return "生成克制、可插入的文章结尾和下一步行动。"
    case .draftArticleTLDR:
      return "生成可放在文章开头或结尾的 TL;DR 要点。"
    case .draftArticleFAQ:
      return "根据正文生成读者可能会问的 FAQ。"
    case .draftReaderQuestions:
      return "生成读者可能追问的问题和建议补充位置。"
    case .draftTransitionSection:
      return "生成连接两个主题的过渡段，补清上下文关系。"
    case .draftExampleSection:
      return "生成用于解释正文概念或流程的示例小节。"
    case .draftStepByStepGuide:
      return "把文章中的可操作内容整理成顺序步骤指南。"
    case .draftTutorialVersion:
      return "把当前文章改写成准备条件、步骤和验证方式更清楚的教程版。"
    case .draftChecklistSection:
      return "基于当前文章生成具体可检查的 Markdown 任务清单。"
    case .draftTroubleshootingSection:
      return "生成现象、原因、确认方式和处理建议的排障小节。"
    case .draftCodeExample:
      return "根据正文技术语境生成最小代码示例或待确认清单。"
    case .draftMermaidDiagram:
      return "基于正文已有关系生成 Mermaid 流程或结构图。"
    case .draftGlossary:
      return "提取关键术语并解释它们在本文里的含义。"
    case .draftReferencesSection:
      return "生成需要补充来源和验证问题的参考资料清单。"
    case .draftInterviewQA:
      return "把文章主题整理成访谈式问答小节。"
    case .reorganizeStructure:
      return "给出当前文章的结构重排建议和段落顺序。"
    case .draftCounterpointSection:
      return "补充反方观点、限制条件和不适用场景。"
    case .draftCaseStudySection:
      return "基于当前主题生成可核验边界清楚的案例分析小节。"
    case .extractArticleKeyPoints:
      return "提取当前文章中的关键事实、结论和限制条件。"
    case .extractArticleActionItems:
      return "把正文里的可执行内容整理成 Markdown 任务列表。"
    case .rewriteSelection:
      return "改写当前选区，保持 Markdown、链接和事实边界。"
    case .polishSelection:
      return "润色当前选区，让表达更自然、清楚、克制。"
    case .expandSelection:
      return "扩写选区，补充上下文、步骤和边界条件。"
    case .continueAfterSelection:
      return "根据选区续写后文，只输出要插入到选区后的内容。"
    case .condenseSelection:
      return "压缩选区，删除重复表达并保留关键信息。"
    case .removeRedundancySelection:
      return "删减选区里的冗余、重复和绕远表达。"
    case .checklistSelection:
      return "把选区整理成可执行 Markdown 检查清单。"
    case .comparisonTableSelection:
      return "把选区整理成 Markdown 对比表，缺失信息标待确认。"
    case .explainSelection:
      return "解释选区中的术语、前提和边界，适合插入到选区后。"
    case .simplifySelection:
      return "降低选区理解门槛，减少术语密度并增强衔接。"
    case .summarizeSelection:
      return "把选区压缩成保留关键事实和结论的摘要。"
    case .translateSelectionToChinese:
      return "把选区翻译成自然中文，保留 Markdown、代码和链接。"
    case .translateSelectionToEnglish:
      return "把选区翻译成自然英文，保留 Markdown、代码和链接。"
    case .draftBilingualRewrite:
      return "把选区整理成中英文两个版本，并保留 Markdown 结构。"
    case .fixSelectionGrammar:
      return "修正选区中的语法、拼写、标点和不通顺表达。"
    case .rewriteSelectionReaderFriendly:
      return "把选区改写得更适合第一次阅读的读者。"
    case .rewriteSelectionFormal:
      return "把选区改写为更正式、克制、适合公开发布的语气。"
    case .rewriteSelectionCasual:
      return "把选区改写为更轻松自然但仍适合个人网站的语气。"
    case .rewriteSelectionTechnical:
      return "把选区改写为更适合技术读者的表达。"
    case .titleSummaryTags:
      return "生成标题、摘要、slug 和 tags 候选。"
    case .suggestTitles:
      return "生成多个适合静态博客文章的标题候选。"
    case .suggestSlug:
      return "生成短、稳定、可读的 kebab-case slug 候选。"
    case .suggestSummary:
      return "生成适合列表页、RSS 和社交分享的一条摘要。"
    case .suggestTags:
      return "生成短、稳定、可复用的 tags 候选。"
    case .draftFrontMatterPack:
      return "生成标题、slug、摘要、tags 和待确认项的 Front Matter 套餐。"
    case .draftBilingualMetadata:
      return "生成中英文标题、摘要、社交描述、slug 和 tags 候选清单。"
    case .privacyReview:
      return "检查正文或选区里的公开风险、密钥、隐私和内部信息。"
    case .reviewContentGaps:
      return "找出文章缺口、影响、待补证据和建议插入位置。"
    case .flagUnsupportedClaims:
      return "标出缺少依据、过度概括或需要作者确认的事实边界。"
    case .draftSourceChecklist:
      return "生成需要补充来源、验证问题和保守表述的清单。"
    case .suggestInternalLinks:
      return "基于站点上下文生成保守的内链建议，不编造路径。"
    case .auditLinkQuality:
      return "检查链接引用质量，列出人工确认方式和保守改法。"
    case .auditImagePrivacy:
      return "基于图片引用、文件名和上下文检查可能公开的图片隐私风险。"
    case .reviewSSGCompatibility:
      return "检查 Hexo、Hugo、Zola、Astro、Jekyll 兼容风险。"
    case .reviewSEOReadability:
      return "检查标题、摘要、结构、首屏和读者理解门槛。"
    case .reviewReaderClarity:
      return "从读者角度找出卡点、缺少前提和过渡建议。"
    case .reviewTechnicalAccuracy:
      return "检查技术表述风险，标出待验证证据和保守改写。"
    case .draftImageAltCaptions:
      return "基于文章和图片上下文生成保守 alt/caption 建议。"
    case .draftSocialShare:
      return "生成多渠道社交分享文案和可选开头。"
    case .draftPublishAssetPack:
      return "生成 SEO、社交、摘录、Newsletter 和发布检查素材。"
    case .draftPullQuotes:
      return "提炼适合社交卡片或正文引用的保守摘录。"
    case .draftPublishNote:
      return "生成发布摘要、变更要点和 commit message 候选。"
    case .draftNewsletterSummary:
      return "生成适合邮件分发的一句话导读、要点和 CTA。"
    case .draftCoverImagePrompt:
      return "生成适合文章主题的封面图提示词方向。"
    case .draftCrossPlatformAnnouncement:
      return "生成网站、RSS、社交和提交信息的跨平台发布摘要。"
    case .draftShortVideoScript:
      return "生成 15、30、60 秒短视频口播稿版本。"
    case .suggestSeriesPlan:
      return "规划系列文章、复用标签和后续内链位置。"
    case .draftContentRefreshPlan:
      return "为旧文生成升级、补证据和回归检查计划。"
    case .draftUpdateNote:
      return "生成文章更新说明、影响范围和待验证事项。"
    case .draftCommentReply:
      return "生成感谢补充、澄清误解和引导继续阅读的评论回复草稿。"
    case .pullRequestDescription:
      return "基于当前发布上下文生成 PR/MR 描述和检查清单。"
    }
  }

  var requiresSelectedTextForBestResult: Bool {
    promptLibraryGroup == .editing
  }
}
