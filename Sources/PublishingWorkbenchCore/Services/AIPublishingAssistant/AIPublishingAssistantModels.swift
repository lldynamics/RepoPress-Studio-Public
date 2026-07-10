import Foundation

public enum AIPublishingActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case publishingReadiness
  case continueArticle
  case draftOpening
  case sharpenOpeningSelection
  case draftOpeningHooks
  case draftFullArticle
  case suggestArticleOutline
  case compareWritingAngles
  case expandOutlineToDraft
  case draftConclusion
  case draftArticleTLDR
  case draftArticleFAQ
  case draftReaderQuestions
  case draftTransitionSection
  case draftExampleSection
  case draftStepByStepGuide
  case draftTutorialVersion
  case draftChecklistSection
  case draftTroubleshootingSection
  case draftCodeExample
  case draftMermaidDiagram
  case draftGlossary
  case draftReferencesSection
  case draftInterviewQA
  case reorganizeStructure
  case draftCounterpointSection
  case draftCaseStudySection
  case extractArticleKeyPoints
  case extractArticleActionItems
  case rewriteSelection
  case polishSelection
  case expandSelection
  case continueAfterSelection
  case condenseSelection
  case removeRedundancySelection
  case checklistSelection
  case comparisonTableSelection
  case explainSelection
  case simplifySelection
  case summarizeSelection
  case translateSelectionToChinese
  case translateSelectionToEnglish
  case draftBilingualRewrite
  case fixSelectionGrammar
  case rewriteSelectionReaderFriendly
  case rewriteSelectionFormal
  case rewriteSelectionCasual
  case rewriteSelectionTechnical
  case titleSummaryTags
  case suggestTitles
  case suggestSlug
  case suggestSummary
  case suggestTags
  case draftFrontMatterPack
  case draftBilingualMetadata
  case privacyReview
  case reviewContentGaps
  case flagUnsupportedClaims
  case draftSourceChecklist
  case suggestInternalLinks
  case auditLinkQuality
  case auditImagePrivacy
  case reviewSSGCompatibility
  case reviewSEOReadability
  case reviewReaderClarity
  case reviewTechnicalAccuracy
  case draftImageAltCaptions
  case draftSocialShare
  case draftPublishAssetPack
  case draftPullQuotes
  case draftPublishNote
  case draftNewsletterSummary
  case draftCoverImagePrompt
  case draftCrossPlatformAnnouncement
  case draftShortVideoScript
  case suggestSeriesPlan
  case draftContentRefreshPlan
  case draftUpdateNote
  case draftCommentReply
  case pullRequestDescription

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .publishingReadiness:
      return "发布准备建议"
    case .continueArticle:
      return "续写正文"
    case .draftOpening:
      return "生成开头"
    case .sharpenOpeningSelection:
      return "优化开头段"
    case .draftOpeningHooks:
      return "生成开头钩子"
    case .draftFullArticle:
      return "生成全文初稿"
    case .suggestArticleOutline:
      return "生成大纲"
    case .compareWritingAngles:
      return "写作角度对比"
    case .expandOutlineToDraft:
      return "按大纲扩写"
    case .draftConclusion:
      return "生成结尾"
    case .draftArticleTLDR:
      return "生成 TL;DR"
    case .draftArticleFAQ:
      return "生成 FAQ"
    case .draftReaderQuestions:
      return "生成读者问题"
    case .draftTransitionSection:
      return "生成过渡段"
    case .draftExampleSection:
      return "生成示例小节"
    case .draftStepByStepGuide:
      return "生成步骤指南"
    case .draftTutorialVersion:
      return "改成教程版"
    case .draftChecklistSection:
      return "生成检查清单"
    case .draftTroubleshootingSection:
      return "生成故障排查"
    case .draftCodeExample:
      return "生成代码示例"
    case .draftMermaidDiagram:
      return "生成 Mermaid 图示"
    case .draftGlossary:
      return "生成术语表"
    case .draftReferencesSection:
      return "生成参考资料清单"
    case .draftInterviewQA:
      return "生成访谈问答"
    case .reorganizeStructure:
      return "结构重排建议"
    case .draftCounterpointSection:
      return "生成反方观点"
    case .draftCaseStudySection:
      return "生成案例小节"
    case .extractArticleKeyPoints:
      return "提取要点"
    case .extractArticleActionItems:
      return "提取行动项"
    case .rewriteSelection:
      return "改写选中文本"
    case .polishSelection:
      return "润色选中文本"
    case .expandSelection:
      return "扩写选中文本"
    case .continueAfterSelection:
      return "续写选区后文"
    case .condenseSelection:
      return "压缩选中文本"
    case .removeRedundancySelection:
      return "删减选区冗余"
    case .checklistSelection:
      return "选区转清单"
    case .comparisonTableSelection:
      return "选区转对比表"
    case .explainSelection:
      return "解释选中文本"
    case .simplifySelection:
      return "降低理解门槛"
    case .summarizeSelection:
      return "选区摘要"
    case .translateSelectionToChinese:
      return "选区翻译中文"
    case .translateSelectionToEnglish:
      return "选区翻译英文"
    case .draftBilingualRewrite:
      return "选区双语改写"
    case .fixSelectionGrammar:
      return "修正选区语法"
    case .rewriteSelectionReaderFriendly:
      return "读者友好改写"
    case .rewriteSelectionFormal:
      return "正式语气改写"
    case .rewriteSelectionCasual:
      return "轻松语气改写"
    case .rewriteSelectionTechnical:
      return "技术语气改写"
    case .titleSummaryTags:
      return "标题摘要标签"
    case .suggestTitles:
      return "标题建议"
    case .suggestSlug:
      return "Slug 建议"
    case .suggestSummary:
      return "摘要建议"
    case .suggestTags:
      return "Tags 建议"
    case .draftFrontMatterPack:
      return "Front Matter 套餐"
    case .draftBilingualMetadata:
      return "中英元数据候选"
    case .privacyReview:
      return "公开风险检查"
    case .reviewContentGaps:
      return "内容缺口检查"
    case .flagUnsupportedClaims:
      return "事实边界提醒"
    case .draftSourceChecklist:
      return "来源补充清单"
    case .suggestInternalLinks:
      return "内链建议"
    case .auditLinkQuality:
      return "链接质量检查"
    case .auditImagePrivacy:
      return "图片隐私检查"
    case .reviewSSGCompatibility:
      return "SSG 兼容检查"
    case .reviewSEOReadability:
      return "SEO 与可读性检查"
    case .reviewReaderClarity:
      return "读者清晰度检查"
    case .reviewTechnicalAccuracy:
      return "技术准确性检查"
    case .draftImageAltCaptions:
      return "图片 alt/caption 建议"
    case .draftSocialShare:
      return "社交分享文案"
    case .draftPublishAssetPack:
      return "发布素材包"
    case .draftPullQuotes:
      return "可引用摘录"
    case .draftPublishNote:
      return "发布说明"
    case .draftNewsletterSummary:
      return "Newsletter 摘要"
    case .draftCoverImagePrompt:
      return "封面图提示词"
    case .draftCrossPlatformAnnouncement:
      return "跨平台发布摘要"
    case .draftShortVideoScript:
      return "短视频口播稿"
    case .suggestSeriesPlan:
      return "系列文章建议"
    case .draftContentRefreshPlan:
      return "旧文升级计划"
    case .draftUpdateNote:
      return "更新说明"
    case .draftCommentReply:
      return "评论回复草稿"
    case .pullRequestDescription:
      return "PR/MR 描述"
    }
  }
}

public extension AIPublishingActionKind {
  var aiModelTaskKind: AIModelTaskKind {
    switch self {
    case .publishingReadiness, .privacyReview, .flagUnsupportedClaims, .auditLinkQuality,
      .auditImagePrivacy, .reviewSSGCompatibility, .reviewReaderClarity, .reviewTechnicalAccuracy:
      return .prePublishReview
    case .pullRequestDescription, .draftUpdateNote:
      return .publishCopy
    case .titleSummaryTags, .suggestTitles, .suggestSlug, .suggestSummary, .suggestTags,
      .draftFrontMatterPack, .draftBilingualMetadata:
      return .metadataRepair
    case .continueArticle, .draftOpening, .draftOpeningHooks, .draftFullArticle, .suggestArticleOutline,
      .compareWritingAngles, .expandOutlineToDraft, .draftConclusion, .draftArticleTLDR,
      .draftArticleFAQ, .draftReaderQuestions, .draftTransitionSection, .draftExampleSection,
      .draftStepByStepGuide, .draftTutorialVersion, .draftChecklistSection,
      .draftTroubleshootingSection, .draftCodeExample, .draftMermaidDiagram, .draftGlossary,
      .draftReferencesSection, .draftInterviewQA, .reorganizeStructure,
      .draftCounterpointSection, .draftCaseStudySection,
      .extractArticleKeyPoints, .extractArticleActionItems,
      .reviewContentGaps, .draftSourceChecklist, .reviewSEOReadability:
      return .articleStructure
    case .suggestInternalLinks, .suggestSeriesPlan, .draftContentRefreshPlan:
      return .articleRelations
    case .draftImageAltCaptions:
      return .imageAltCaption
    case .draftSocialShare, .draftPublishAssetPack, .draftPullQuotes,
      .draftPublishNote, .draftNewsletterSummary, .draftCoverImagePrompt,
      .draftCrossPlatformAnnouncement, .draftShortVideoScript, .draftCommentReply:
      return .publishCopy
    case .rewriteSelection, .polishSelection, .expandSelection, .continueAfterSelection,
      .condenseSelection, .removeRedundancySelection, .checklistSelection,
      .comparisonTableSelection, .explainSelection, .simplifySelection, .summarizeSelection,
      .sharpenOpeningSelection, .translateSelectionToChinese, .translateSelectionToEnglish,
      .draftBilingualRewrite, .fixSelectionGrammar,
      .rewriteSelectionReaderFriendly, .rewriteSelectionFormal, .rewriteSelectionCasual,
      .rewriteSelectionTechnical:
      return .textEditing
    }
  }
}

public struct AIPublishingActionRequest: Sendable {
  public var kind: AIPublishingActionKind
  public var draft: ArticleDraft
  public var profile: SiteProfile
  public var selectedText: String?
  public var preflightIssues: [PreflightIssue]
  public var publishPackage: PublishPackage?
  public var remoteReviewDraft: RemoteReviewDraft?
  public var workflowContext: AIPublishingWorkflowContext?

  public init(
    kind: AIPublishingActionKind,
    draft: ArticleDraft,
    profile: SiteProfile,
    selectedText: String? = nil,
    preflightIssues: [PreflightIssue] = [],
    publishPackage: PublishPackage? = nil,
    remoteReviewDraft: RemoteReviewDraft? = nil,
    workflowContext: AIPublishingWorkflowContext? = nil
  ) {
    self.kind = kind
    self.draft = draft
    self.profile = profile
    self.selectedText = selectedText
    self.preflightIssues = preflightIssues
    self.publishPackage = publishPackage
    self.remoteReviewDraft = remoteReviewDraft
    self.workflowContext = workflowContext
  }
}

public struct AIPublishingActionResult: Hashable, Sendable {
  public var kind: AIPublishingActionKind
  public var content: String
  public var providerName: String
  public var model: String

  public init(
    kind: AIPublishingActionKind,
    content: String,
    providerName: String = "",
    model: String = ""
  ) {
    self.kind = kind
    self.content = content
    self.providerName = providerName
    self.model = model
  }
}

public enum AIPublishingChatRole: String, Codable, Hashable, Sendable {
  case user
  case assistant

  public var displayName: String {
    switch self {
    case .user:
      return "你"
    case .assistant:
      return "AI"
    }
  }
}

public enum AIPublishingChatContextMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case site
  case general

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .site:
      return "站点上下文"
    case .general:
      return "通用聊天"
    }
  }

  public var detail: String {
    switch self {
    case .site:
      return "使用当前文章、发布检查和站点工作台上下文"
    case .general:
      return "不读取当前文章正文、仓库状态或发布检查"
    }
  }

  public var systemImage: String {
    switch self {
    case .site:
      return "doc.text.magnifyingglass"
    case .general:
      return "bubble.left.and.bubble.right"
    }
  }
}

public struct AIPublishingChatMessage: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var role: AIPublishingChatRole
  public var content: String
  public var model: String?
  public var tokenUsage: AIChatTokenUsage?
  public var contextMode: AIPublishingChatContextMode
  public var imageAttachments: [AIChatImageAttachment]
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    role: AIPublishingChatRole,
    content: String,
    model: String? = nil,
    tokenUsage: AIChatTokenUsage? = nil,
    contextMode: AIPublishingChatContextMode = .site,
    imageAttachments: [AIChatImageAttachment] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.model = model
    self.tokenUsage = tokenUsage
    self.contextMode = contextMode
    self.imageAttachments = imageAttachments
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case role
    case content
    case model
    case tokenUsage
    case contextMode
    case imageAttachments
    case createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    role = try container.decode(AIPublishingChatRole.self, forKey: .role)
    content = try container.decode(String.self, forKey: .content)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    tokenUsage = try container.decodeIfPresent(AIChatTokenUsage.self, forKey: .tokenUsage)
    contextMode = try container.decodeIfPresent(AIPublishingChatContextMode.self, forKey: .contextMode) ?? .site
    imageAttachments = try container.decodeIfPresent([AIChatImageAttachment].self, forKey: .imageAttachments) ?? []
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}

public struct AIPublishingChatArchivedConversation: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var messages: [AIPublishingChatMessage]
  public var contextMode: AIPublishingChatContextMode
  public var modelGrade: AIChatModelGrade
  public var selectedModel: String
  public var focusedParagraphID: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    messages: [AIPublishingChatMessage],
    contextMode: AIPublishingChatContextMode,
    modelGrade: AIChatModelGrade,
    selectedModel: String,
    focusedParagraphID: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.contextMode = contextMode
    self.modelGrade = modelGrade
    self.selectedModel = selectedModel
    self.focusedParagraphID = focusedParagraphID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case messages
    case contextMode
    case modelGrade
    case selectedModel
    case focusedParagraphID
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    title = try container.decode(String.self, forKey: .title)
    messages = try container.decode([AIPublishingChatMessage].self, forKey: .messages)
    contextMode = try container.decodeIfPresent(AIPublishingChatContextMode.self, forKey: .contextMode) ?? .site
    modelGrade = try container.decodeIfPresent(AIChatModelGrade.self, forKey: .modelGrade) ?? .standard
    selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? ""
    focusedParagraphID = try container.decodeIfPresent(String.self, forKey: .focusedParagraphID)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
  }
}

public struct AIPublishingCustomPrompt: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var prompt: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    prompt: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title.trimmedForPublishing.nilIfEmpty ?? "自定义提示"
    self.prompt = prompt.trimmedForPublishing
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case prompt
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    title = try container.decodeIfPresent(String.self, forKey: .title)?
      .trimmedForPublishing
      .nilIfEmpty ?? "自定义提示"
    prompt = try container.decode(String.self, forKey: .prompt).trimmedForPublishing
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
  }
}

public struct AIPublishingChatSessionState: Codable, Hashable, Sendable {
  public var conversationTitle: String?
  public var messages: [AIPublishingChatMessage]
  public var contextMode: AIPublishingChatContextMode
  public var modelGrade: AIChatModelGrade
  public var selectedModel: String
  public var focusedParagraphID: String?
  public var archivedConversations: [AIPublishingChatArchivedConversation]

  public init(
    conversationTitle: String? = nil,
    messages: [AIPublishingChatMessage] = [],
    contextMode: AIPublishingChatContextMode = .site,
    modelGrade: AIChatModelGrade = .standard,
    selectedModel: String = "",
    focusedParagraphID: String? = nil,
    archivedConversations: [AIPublishingChatArchivedConversation] = []
  ) {
    self.conversationTitle = conversationTitle?.trimmedForPublishing.nilIfEmpty
    self.messages = messages
    self.contextMode = contextMode
    self.modelGrade = modelGrade
    self.selectedModel = selectedModel
    self.focusedParagraphID = focusedParagraphID
    self.archivedConversations = archivedConversations
  }

  public var shouldPersist: Bool {
    conversationTitle?.nilIfEmpty != nil
      || !messages.isEmpty
      || contextMode != .site
      || modelGrade != .standard
      || !selectedModel.trimmedForPublishing.isEmpty
      || focusedParagraphID?.nilIfEmpty != nil
      || !archivedConversations.isEmpty
  }

  public func prepared(
    maxArchivedConversations: Int = 20,
    maxMessagesPerConversation: Int = 80,
    maxTotalImageBytes: Int64 = 24_000_000
  ) -> AIPublishingChatSessionState {
    var prepared = self
    prepared.conversationTitle = prepared.conversationTitle?.trimmedForPublishing.nilIfEmpty
    if prepared.messages.count > maxMessagesPerConversation {
      prepared.messages = Array(prepared.messages.suffix(maxMessagesPerConversation))
    }
    prepared.archivedConversations = prepared.archivedConversations
      .filter { !$0.messages.isEmpty }
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(maxArchivedConversations)
      .map { conversation in
        var trimmed = conversation
        if trimmed.messages.count > maxMessagesPerConversation {
          trimmed.messages = Array(trimmed.messages.suffix(maxMessagesPerConversation))
      }
      return trimmed
    }
    prepared.trimImageAttachmentsToFit(maxTotalImageBytes: maxTotalImageBytes)
    return prepared
  }

  private mutating func trimImageAttachmentsToFit(maxTotalImageBytes: Int64) {
    guard maxTotalImageBytes >= 0 else {
      messages = messages.map { message in
        var trimmed = message
        trimmed.imageAttachments = []
        return trimmed
      }
      archivedConversations = archivedConversations.map { conversation in
        var trimmed = conversation
        trimmed.messages = trimmed.messages.map { message in
          var message = message
          message.imageAttachments = []
          return message
        }
        return trimmed
      }
      return
    }

    var remainingBytes = maxTotalImageBytes
    // Keep the newest active/archived images and preserve message text when
    // reclaiming older image payloads from the persisted session.
    for index in messages.indices.reversed() {
      let byteCount = messages[index].imageAttachments.reduce(Int64(0)) { partial, attachment in
        partial + max(attachment.byteCount, Int64(attachment.data.count))
      }
      if byteCount <= remainingBytes {
        remainingBytes -= byteCount
      } else {
        messages[index].imageAttachments = []
      }
    }
    for conversationIndex in archivedConversations.indices {
      for messageIndex in archivedConversations[conversationIndex].messages.indices.reversed() {
        let byteCount = archivedConversations[conversationIndex].messages[messageIndex].imageAttachments.reduce(Int64(0)) { partial, attachment in
          partial + max(attachment.byteCount, Int64(attachment.data.count))
        }
        if byteCount <= remainingBytes {
          remainingBytes -= byteCount
        } else {
          archivedConversations[conversationIndex].messages[messageIndex].imageAttachments = []
        }
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case conversationTitle
    case messages
    case contextMode
    case modelGrade
    case selectedModel
    case focusedParagraphID
    case archivedConversations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)?
      .trimmedForPublishing
      .nilIfEmpty
    messages = try container.decodeIfPresent([AIPublishingChatMessage].self, forKey: .messages) ?? []
    contextMode = try container.decodeIfPresent(AIPublishingChatContextMode.self, forKey: .contextMode) ?? .site
    modelGrade = try container.decodeIfPresent(AIChatModelGrade.self, forKey: .modelGrade) ?? .standard
    selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? ""
    focusedParagraphID = try container.decodeIfPresent(String.self, forKey: .focusedParagraphID)
    archivedConversations = try container.decodeIfPresent(
      [AIPublishingChatArchivedConversation].self,
      forKey: .archivedConversations
    ) ?? []
  }
}

public struct AIPublishingChatRequest: Sendable {
  public var draft: ArticleDraft
  public var profile: SiteProfile
  public var messages: [AIPublishingChatMessage]
  public var contextMode: AIPublishingChatContextMode
  public var modelGrade: AIChatModelGrade
  public var selectedModel: String?
  public var preflightIssues: [PreflightIssue]
  public var publishPackage: PublishPackage?
  public var remoteReviewDraft: RemoteReviewDraft?
  public var workflowContext: AIPublishingWorkflowContext?
  public var focusedParagraph: AIPublishingChatDraftParagraph?
  public var relatedSuggestions: [SiteRelationSuggestion]

  public init(
    draft: ArticleDraft,
    profile: SiteProfile,
    messages: [AIPublishingChatMessage],
    contextMode: AIPublishingChatContextMode = .site,
    modelGrade: AIChatModelGrade = .standard,
    selectedModel: String? = nil,
    preflightIssues: [PreflightIssue] = [],
    publishPackage: PublishPackage? = nil,
    remoteReviewDraft: RemoteReviewDraft? = nil,
    workflowContext: AIPublishingWorkflowContext? = nil,
    focusedParagraph: AIPublishingChatDraftParagraph? = nil,
    relatedSuggestions: [SiteRelationSuggestion] = []
  ) {
    self.draft = draft
    self.profile = profile
    self.messages = messages
    self.contextMode = contextMode
    self.modelGrade = modelGrade
    self.selectedModel = selectedModel
    self.preflightIssues = preflightIssues
    self.publishPackage = publishPackage
    self.remoteReviewDraft = remoteReviewDraft
    self.workflowContext = workflowContext
    self.focusedParagraph = focusedParagraph
    self.relatedSuggestions = relatedSuggestions
  }
}

public struct AIPublishingWorkflowContext: Sendable {
  public var publishPreview: LocalPublishPreview?
  public var localSitePreviewPlan: LocalSitePreviewPlan?
  public var imageReport: ImageWorkbenchReport?

  public init(
    publishPreview: LocalPublishPreview? = nil,
    localSitePreviewPlan: LocalSitePreviewPlan? = nil,
    imageReport: ImageWorkbenchReport? = nil
  ) {
    self.publishPreview = publishPreview
    self.localSitePreviewPlan = localSitePreviewPlan
    self.imageReport = imageReport
  }
}

public struct AIPublishingChatReplyStream: Sendable {
  public var initialMessage: AIPublishingChatMessage
  public var updates: AsyncThrowingStream<AIChatStreamUpdate, Error>

  public init(
    initialMessage: AIPublishingChatMessage,
    updates: AsyncThrowingStream<AIChatStreamUpdate, Error>
  ) {
    self.initialMessage = initialMessage
    self.updates = updates
  }
}
