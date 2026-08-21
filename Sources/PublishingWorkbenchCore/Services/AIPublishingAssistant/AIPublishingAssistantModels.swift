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

  /// Legacy micro-actions remain decodable for saved workflows, but should not
  /// occupy the compact editor action menu alongside the converged actions.
  public var isCompactMenuVariant: Bool {
    switch self {
    case .draftOpeningHooks,
      .sharpenOpeningSelection,
      .polishSelection,
      .rewriteSelectionReaderFriendly,
      .rewriteSelectionFormal,
      .rewriteSelectionCasual,
      .rewriteSelectionTechnical:
      return true
    default:
      return false
    }
  }

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

extension AIPublishingActionKind {
  public var aiModelTaskKind: AIModelTaskKind {
    switch self {
    case .publishingReadiness, .privacyReview, .flagUnsupportedClaims, .auditLinkQuality,
      .auditImagePrivacy, .reviewSSGCompatibility, .reviewReaderClarity, .reviewTechnicalAccuracy:
      return .prePublishReview
    case .pullRequestDescription, .draftUpdateNote:
      return .publishCopy
    case .titleSummaryTags, .suggestTitles, .suggestSlug, .suggestSummary, .suggestTags,
      .draftFrontMatterPack, .draftBilingualMetadata:
      return .metadataRepair
    case .continueArticle, .draftOpening, .draftOpeningHooks, .draftFullArticle,
      .suggestArticleOutline,
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
  /// Optional converged configuration. `kind` remains the canonical legacy
  /// action so existing result handling and saved workflows stay compatible.
  public var convergence: AIPublishingActionConvergence?
  public var draft: ArticleDraft
  public var profile: SiteProfile
  public var selectedText: String?
  public var preflightIssues: [PreflightIssue]
  public var publishPackage: PublishPackage?
  public var remoteReviewDraft: RemoteReviewDraft?
  public var workflowContext: AIPublishingWorkflowContext?
  public var knowledgeContext: KnowledgeContextSnapshot?

  public init(
    kind: AIPublishingActionKind,
    draft: ArticleDraft,
    profile: SiteProfile,
    convergence: AIPublishingActionConvergence? = nil,
    selectedText: String? = nil,
    preflightIssues: [PreflightIssue] = [],
    publishPackage: PublishPackage? = nil,
    remoteReviewDraft: RemoteReviewDraft? = nil,
    workflowContext: AIPublishingWorkflowContext? = nil,
    knowledgeContext: KnowledgeContextSnapshot? = nil
  ) {
    self.kind = kind
    self.convergence = convergence
    self.draft = draft
    self.profile = profile
    self.selectedText = selectedText
    self.preflightIssues = preflightIssues
    self.publishPackage = publishPackage
    self.remoteReviewDraft = remoteReviewDraft
    self.workflowContext = workflowContext
    self.knowledgeContext = knowledgeContext
  }
}

public struct AIPublishingActionResult: Hashable, Sendable {
  public var kind: AIPublishingActionKind
  public var content: String
  public var providerName: String
  public var model: String
  public var knowledgeCitations: [KnowledgeCitation]

  public init(
    kind: AIPublishingActionKind,
    content: String,
    providerName: String = "",
    model: String = "",
    knowledgeCitations: [KnowledgeCitation] = []
  ) {
    self.kind = kind
    self.content = content
    self.providerName = providerName
    self.model = model
    self.knowledgeCitations = knowledgeCitations
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

public enum AIPublishingChatReviewDecisionChoice: String, Codable, Hashable, Sendable {
  case accepted
  case rejected
}

/// A conversation-bound decision for one Agent-proposed content mutation.
/// This is persisted beside the chat message for auditability and is never
/// included in the model transcript.
public struct AIPublishingChatReviewDecision: Codable, Hashable, Sendable {
  public var choice: AIPublishingChatReviewDecisionChoice
  public var planID: UUID
  public var stepID: UUID
  public var toolCallID: String?
  public var decidedAt: Date
  public var previewBaselineFingerprint: String?

  public init(
    choice: AIPublishingChatReviewDecisionChoice,
    planID: UUID,
    stepID: UUID,
    toolCallID: String? = nil,
    decidedAt: Date = Date(),
    previewBaselineFingerprint: String? = nil
  ) {
    self.choice = choice
    self.planID = planID
    self.stepID = stepID
    self.toolCallID = toolCallID?.trimmedForPublishing.nilIfEmpty
    self.decidedAt = decidedAt
    self.previewBaselineFingerprint = previewBaselineFingerprint?.trimmedForPublishing.nilIfEmpty
  }
}

/// Durable state for an Agent round paused at a native review boundary.
/// Credentials, outbound approvals, nonces, and transport authorizations are
/// intentionally excluded. A phase that may already have contacted the model
/// is never eligible for automatic replay after relaunch.
public struct AIPublishingChatAgentPromptRevision: Codable, Hashable, Sendable {
  public var connectionProfileID: UUID?
  public var agentMode: AIConversationAgentMode
  public var contextMode: AIPublishingChatContextMode
  public var knowledgePolicy: KnowledgeRetrievalPolicy
  public var modelGrade: AIChatModelGrade
  public var reasoningLevel: AIChatReasoningLevel
  public var selectedModel: String
  public var focusedParagraphID: String?

  public init(
    connectionProfileID: UUID? = nil,
    agentMode: AIConversationAgentMode = .inheritConnection,
    contextMode: AIPublishingChatContextMode = .site,
    knowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    modelGrade: AIChatModelGrade = .standard,
    reasoningLevel: AIChatReasoningLevel = .deep,
    selectedModel: String = "",
    focusedParagraphID: String? = nil
  ) {
    self.connectionProfileID = connectionProfileID
    self.agentMode = agentMode
    self.contextMode = contextMode
    self.knowledgePolicy = knowledgePolicy
    self.modelGrade = modelGrade
    self.reasoningLevel = reasoningLevel
    self.selectedModel = selectedModel.trimmedForPublishing
    self.focusedParagraphID = focusedParagraphID?.nilIfEmpty
  }

  public init(conversation: AIConversation) {
    self.init(
      connectionProfileID: conversation.connectionProfileID,
      agentMode: conversation.agentMode,
      contextMode: conversation.contextMode,
      knowledgePolicy: conversation.knowledgePolicy,
      modelGrade: conversation.modelGrade,
      reasoningLevel: conversation.reasoningLevel,
      selectedModel: conversation.selectedModel,
      focusedParagraphID: conversation.focusedParagraphID
    )
  }
}

public enum AIPublishingChatAgentContinuationPhase: String, Codable, Hashable, Sendable {
  case awaitingReview
  case applyingDecision
  case resuming
  case sending
  case deliveryUncertain
  case cancelled
  case abandonedAfterDeliveryUncertain

  /// A terminal continuation is retained as audit history but must never be
  /// resumed or treated as pending work after a reload.
  public var isTerminal: Bool {
    switch self {
    case .cancelled, .abandonedAfterDeliveryUncertain:
      return true
    case .awaitingReview, .applyingDecision, .resuming, .sending,
      .deliveryUncertain:
      return false
    }
  }

  /// Whether retention and destructive chat operations must keep treating the
  /// continuation as pending user disposition. This intentionally covers
  /// every non-terminal phase, not just the uncertain-delivery phase.
  public var requiresExplicitDisposition: Bool { !isTerminal }

  public var allowsAutomaticResume: Bool {
    self == .awaitingReview
  }
}

public struct AIPublishingChatAgentContinuation: Codable, Hashable, Identifiable, Sendable {
  public static let currentSchemaVersion = 3
  public static let maximumEncodedByteCount = 1_500_000

  public var schemaVersion: Int
  public var id: UUID
  public var ownerConversationID: UUID
  public var ownerScope: AIConversationScope
  public var ownerMessageID: UUID
  public var planID: UUID
  public var phase: AIPublishingChatAgentContinuationPhase
  public var revision: Int
  public var activeStepID: UUID?
  public var resumeAttemptID: UUID?
  public var requestTemplate: AIChatCompletionRequest
  public var checkpoint: WorkbenchAIAgentLoopCheckpoint
  public var resolutions: [WorkbenchAIAgentToolResolution]
  public var providerConfig: AIProviderConfig
  public var taskConfig: AIProviderConfig
  public var promptRevision: AIPublishingChatAgentPromptRevision?
  /// The exact knowledge sources included in the first model-facing prompt.
  /// These are persisted independently from the prompt revision so a resumed
  /// Agent can re-check source authorization without re-running retrieval.
  public var knowledgeAuthorizationBindings: [KnowledgeAuthorizationBinding]
  public var reviewDraftFingerprint: String?
  public var reviewDraftUpdatedAt: Date?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    schemaVersion: Int = AIPublishingChatAgentContinuation.currentSchemaVersion,
    id: UUID = UUID(),
    ownerConversationID: UUID,
    ownerScope: AIConversationScope,
    ownerMessageID: UUID,
    planID: UUID,
    phase: AIPublishingChatAgentContinuationPhase = .awaitingReview,
    revision: Int = 0,
    activeStepID: UUID? = nil,
    resumeAttemptID: UUID? = nil,
    requestTemplate: AIChatCompletionRequest,
    checkpoint: WorkbenchAIAgentLoopCheckpoint,
    resolutions: [WorkbenchAIAgentToolResolution] = [],
    providerConfig: AIProviderConfig,
    taskConfig: AIProviderConfig,
    promptRevision: AIPublishingChatAgentPromptRevision,
    reviewDraftFingerprint: String,
    reviewDraftUpdatedAt: Date,
    knowledgeAuthorizationBindings: [KnowledgeAuthorizationBinding] = [],
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.ownerConversationID = ownerConversationID
    self.ownerScope = ownerScope
    self.ownerMessageID = ownerMessageID
    self.planID = planID
    self.phase = phase
    self.revision = max(0, revision)
    self.activeStepID = activeStepID
    self.resumeAttemptID = resumeAttemptID
    self.requestTemplate = requestTemplate
    self.checkpoint = checkpoint
    self.resolutions = resolutions
    self.providerConfig = providerConfig
    self.taskConfig = taskConfig
    self.promptRevision = promptRevision
    self.knowledgeAuthorizationBindings = knowledgeAuthorizationBindings
    self.reviewDraftFingerprint = reviewDraftFingerprint.trimmedForPublishing.nilIfEmpty
    self.reviewDraftUpdatedAt = reviewDraftUpdatedAt
    self.createdAt = createdAt
    self.updatedAt = max(updatedAt ?? createdAt, createdAt)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case ownerConversationID
    case ownerScope
    case ownerMessageID
    case planID
    case phase
    case revision
    case activeStepID
    case resumeAttemptID
    case requestTemplate
    case checkpoint
    case resolutions
    case providerConfig
    case taskConfig
    case promptRevision
    case knowledgeAuthorizationBindings
    case reviewDraftFingerprint
    case reviewDraftUpdatedAt
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    id = try container.decode(UUID.self, forKey: .id)
    ownerConversationID = try container.decode(UUID.self, forKey: .ownerConversationID)
    ownerScope = try container.decode(AIConversationScope.self, forKey: .ownerScope)
    ownerMessageID = try container.decode(UUID.self, forKey: .ownerMessageID)
    planID = try container.decode(UUID.self, forKey: .planID)

    let decodedPhase = try container.decode(
      AIPublishingChatAgentContinuationPhase.self,
      forKey: .phase
    )
    // A snapshot can be written after the model/tool boundary but before the
    // process exits. Those transient phases are never safe to replay after
    // decoding because the provider or local executor may already have seen
    // the request. Recover them as an explicit, non-replayable uncertainty.
    let recoveredFromTransientPhase: Bool
    switch decodedPhase {
    case .applyingDecision, .resuming, .sending:
      phase = .deliveryUncertain
      recoveredFromTransientPhase = true
    case .awaitingReview, .deliveryUncertain, .cancelled,
      .abandonedAfterDeliveryUncertain:
      phase = decodedPhase
      recoveredFromTransientPhase = false
    }
    revision = try container.decode(Int.self, forKey: .revision)
    let decodedActiveStepID = try container.decodeIfPresent(UUID.self, forKey: .activeStepID)
    activeStepID = recoveredFromTransientPhase ? nil : decodedActiveStepID
    resumeAttemptID = try container.decodeIfPresent(UUID.self, forKey: .resumeAttemptID)
    requestTemplate = try container.decode(AIChatCompletionRequest.self, forKey: .requestTemplate)
    checkpoint = try container.decode(WorkbenchAIAgentLoopCheckpoint.self, forKey: .checkpoint)
    resolutions = try container.decode(
      [WorkbenchAIAgentToolResolution].self,
      forKey: .resolutions
    )
    providerConfig = try container.decode(AIProviderConfig.self, forKey: .providerConfig)
    taskConfig = try container.decode(AIProviderConfig.self, forKey: .taskConfig)
    promptRevision = try container.decodeIfPresent(
      AIPublishingChatAgentPromptRevision.self,
      forKey: .promptRevision
    )
    // Continuations written before source authorization bindings existed are
    // intentionally decoded without authority and rejected by the v3 schema
    // check below; no legacy continuation is silently replayable.
    knowledgeAuthorizationBindings = try container.decodeIfPresent(
      [KnowledgeAuthorizationBinding].self,
      forKey: .knowledgeAuthorizationBindings
    ) ?? []
    reviewDraftFingerprint = try container.decodeIfPresent(
      String.self,
      forKey: .reviewDraftFingerprint
    )
    reviewDraftUpdatedAt = try container.decodeIfPresent(
      Date.self,
      forKey: .reviewDraftUpdatedAt
    )
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(id, forKey: .id)
    try container.encode(ownerConversationID, forKey: .ownerConversationID)
    try container.encode(ownerScope, forKey: .ownerScope)
    try container.encode(ownerMessageID, forKey: .ownerMessageID)
    try container.encode(planID, forKey: .planID)
    try container.encode(phase, forKey: .phase)
    try container.encode(revision, forKey: .revision)
    try container.encodeIfPresent(activeStepID, forKey: .activeStepID)
    try container.encodeIfPresent(resumeAttemptID, forKey: .resumeAttemptID)
    try container.encode(requestTemplate, forKey: .requestTemplate)
    try container.encode(checkpoint, forKey: .checkpoint)
    try container.encode(resolutions, forKey: .resolutions)
    try container.encode(providerConfig, forKey: .providerConfig)
    try container.encode(taskConfig, forKey: .taskConfig)
    try container.encodeIfPresent(promptRevision, forKey: .promptRevision)
    try container.encode(
      knowledgeAuthorizationBindings,
      forKey: .knowledgeAuthorizationBindings
    )
    try container.encodeIfPresent(reviewDraftFingerprint, forKey: .reviewDraftFingerprint)
    try container.encodeIfPresent(reviewDraftUpdatedAt, forKey: .reviewDraftUpdatedAt)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  public var isValidForPersistence: Bool {
    guard schemaVersion == Self.currentSchemaVersion,
      checkpoint.schemaVersion == WorkbenchAIAgentLoopCheckpoint.currentSchemaVersion,
      ownerScope.draftID != nil,
      promptRevision != nil,
      reviewDraftFingerprint?.trimmedForPublishing.nilIfEmpty != nil,
      reviewDraftUpdatedAt != nil,
      checkpoint.pendingCalls.count <= WorkbenchAutomationPlan.maximumStepCount,
      resolutions.count <= checkpoint.pendingCalls.count,
      resolutions.allSatisfy({
        $0.content.utf8.count <= WorkbenchAIAgentToolResolution.maximumContentByteCount
      })
    else {
      return false
    }
    let pendingIDs = Set(checkpoint.pendingCalls.map(\.toolCallID))
    let resolutionIDs = resolutions.map(\.toolCallID)
    guard Set(resolutionIDs).count == resolutionIDs.count,
      Set(resolutionIDs).isSubset(of: pendingIDs)
    else {
      return false
    }
    return (try? JSONEncoder().encode(self).count).map {
      $0 <= Self.maximumEncodedByteCount
    } ?? false
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
  public var contextReferences: [AIContextReference]
  public var knowledgeCitations: [KnowledgeCitation]
  public var toolRuns: [WorkbenchAIAgentToolRunRecord]
  public var reviewDecisions: [AIPublishingChatReviewDecision]
  public var agentContinuation: AIPublishingChatAgentContinuation?
  public var automationPlan: WorkbenchAutomationPlan?
  public var structuredEditPayload: AIPublishingChatStructuredEditPayload?
  public var translationDraftPlan: AITranslationDraftPlan?
  public var followUpSuggestions: [AIChatFollowUpSuggestion]
  public var allowsDraftAppend: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    role: AIPublishingChatRole,
    content: String,
    model: String? = nil,
    tokenUsage: AIChatTokenUsage? = nil,
    contextMode: AIPublishingChatContextMode = .site,
    imageAttachments: [AIChatImageAttachment] = [],
    contextReferences: [AIContextReference] = [],
    knowledgeCitations: [KnowledgeCitation] = [],
    toolRuns: [WorkbenchAIAgentToolRunRecord] = [],
    reviewDecisions: [AIPublishingChatReviewDecision] = [],
    agentContinuation: AIPublishingChatAgentContinuation? = nil,
    automationPlan: WorkbenchAutomationPlan? = nil,
    structuredEditPayload: AIPublishingChatStructuredEditPayload? = nil,
    translationDraftPlan: AITranslationDraftPlan? = nil,
    followUpSuggestions: [AIChatFollowUpSuggestion] = [],
    allowsDraftAppend: Bool = true,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.model = model
    self.tokenUsage = tokenUsage
    self.contextMode = contextMode
    self.imageAttachments = imageAttachments
    self.contextReferences = contextReferences
    self.knowledgeCitations = knowledgeCitations
    self.toolRuns = toolRuns
    self.reviewDecisions = reviewDecisions
    self.agentContinuation = agentContinuation?.isValidForPersistence == true
      ? agentContinuation : nil
    self.automationPlan = automationPlan
    self.structuredEditPayload = structuredEditPayload
    self.translationDraftPlan = translationDraftPlan
    self.followUpSuggestions = followUpSuggestions
    self.allowsDraftAppend = allowsDraftAppend
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
    case contextReferences
    case knowledgeCitations
    case toolRuns
    case reviewDecisions
    case agentContinuation
    case automationPlan
    case structuredEditPayload
    case translationDraftPlan
    case followUpSuggestions
    case allowsDraftAppend
    case createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    role = try container.decode(AIPublishingChatRole.self, forKey: .role)
    content = try container.decode(String.self, forKey: .content)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    tokenUsage = try container.decodeIfPresent(AIChatTokenUsage.self, forKey: .tokenUsage)
    contextMode =
      try container.decodeIfPresent(AIPublishingChatContextMode.self, forKey: .contextMode) ?? .site
    imageAttachments =
      try container.decodeIfPresent([AIChatImageAttachment].self, forKey: .imageAttachments) ?? []
    contextReferences =
      try container.decodeIfPresent([AIContextReference].self, forKey: .contextReferences) ?? []
    knowledgeCitations =
      try container.decodeIfPresent([KnowledgeCitation].self, forKey: .knowledgeCitations) ?? []
    toolRuns =
      try container.decodeIfPresent([WorkbenchAIAgentToolRunRecord].self, forKey: .toolRuns) ?? []
    reviewDecisions = try container.decodeIfPresent(
      [AIPublishingChatReviewDecision].self,
      forKey: .reviewDecisions
    ) ?? []
    let decodedContinuation = try container.decodeIfPresent(
      AIPublishingChatAgentContinuation.self,
      forKey: .agentContinuation
    )
    agentContinuation = decodedContinuation?.isValidForPersistence == true
      ? decodedContinuation : nil
    automationPlan = try container.decodeIfPresent(
      WorkbenchAutomationPlan.self, forKey: .automationPlan)
    structuredEditPayload =
      try container.decodeIfPresent(
        AIPublishingChatStructuredEditPayload.self,
        forKey: .structuredEditPayload
      )
    translationDraftPlan =
      try container.decodeIfPresent(
        AITranslationDraftPlan.self,
        forKey: .translationDraftPlan
      )
    followUpSuggestions =
      try container.decodeIfPresent(
        [AIChatFollowUpSuggestion].self,
        forKey: .followUpSuggestions
      ) ?? []
    allowsDraftAppend = try container.decodeIfPresent(Bool.self, forKey: .allowsDraftAppend) ?? true
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
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
    title =
      try container.decodeIfPresent(String.self, forKey: .title)?
      .trimmedForPublishing
      .nilIfEmpty ?? "自定义提示"
    prompt = try container.decode(String.self, forKey: .prompt).trimmedForPublishing
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
  }
}

/// The mutable state shared by an active AI conversation and its persisted
/// ``AIConversation`` record.
public struct AIPublishingChatSessionState: Hashable, Sendable {
  public var conversationTitle: String?
  public var messages: [AIPublishingChatMessage]
  public var contextMode: AIPublishingChatContextMode
  public var knowledgePolicy: KnowledgeRetrievalPolicy
  public var modelGrade: AIChatModelGrade
  public var reasoningLevel: AIChatReasoningLevel
  public var selectedModel: String
  public var focusedParagraphID: String?

  public init(
    conversationTitle: String? = nil,
    messages: [AIPublishingChatMessage] = [],
    contextMode: AIPublishingChatContextMode = .site,
    knowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    modelGrade: AIChatModelGrade = .standard,
    reasoningLevel: AIChatReasoningLevel = .deep,
    selectedModel: String = "",
    focusedParagraphID: String? = nil
  ) {
    self.conversationTitle = conversationTitle?.trimmedForPublishing.nilIfEmpty
    self.messages = messages
    self.contextMode = contextMode
    self.knowledgePolicy = knowledgePolicy
    self.modelGrade = modelGrade
    self.reasoningLevel = reasoningLevel
    self.selectedModel = selectedModel
    self.focusedParagraphID = focusedParagraphID
  }

  public var shouldCache: Bool {
    conversationTitle?.nilIfEmpty != nil
      || !messages.isEmpty
      || contextMode != .site
      || knowledgePolicy != .automatic
      || modelGrade != .standard
      || reasoningLevel != .deep
      || !selectedModel.trimmedForPublishing.isEmpty
      || focusedParagraphID?.nilIfEmpty != nil
  }

  public var imageAttachmentByteCount: Int64 {
    AIChatImageAttachmentBudget.byteCount(messages)
  }

  public func prepared(
    maxMessagesPerConversation: Int = 80,
    maxTotalImageBytes: Int64 = 8_000_000,
    maxTotalTextCharacters: Int = 250_000
  ) -> AIPublishingChatSessionState {
    var prepared = self
    prepared.conversationTitle = prepared.conversationTitle?.trimmedForPublishing.nilIfEmpty
    if prepared.messages.count > maxMessagesPerConversation {
      prepared.messages = Array(prepared.messages.suffix(maxMessagesPerConversation))
    }
    prepared.trimMessageContentToFit(
      maxTotalTextCharacters: maxTotalTextCharacters
    )
    prepared.trimImageAttachmentsToFit(maxTotalImageBytes: maxTotalImageBytes)
    return prepared
  }

  private mutating func trimMessageContentToFit(
    maxTotalTextCharacters: Int
  ) {
    guard maxTotalTextCharacters > 0 else {
      messages = []
      return
    }

    var remainingCharacters = maxTotalTextCharacters
    var retainedMessages: [AIPublishingChatMessage] = []
    retainedMessages.reserveCapacity(messages.count)

    // Keep the newest exchange history. If one message alone exceeds the
    // budget, retain its beginning so the response remains readable.
    for message in messages.reversed() {
      guard remainingCharacters > 0 else { break }
      var retained = message
      if retained.content.count > remainingCharacters {
        retained.content = String(retained.content.prefix(remainingCharacters))
      }
      remainingCharacters -= retained.content.count
      retainedMessages.append(retained)
    }
    messages = Array(retainedMessages.reversed())
  }

  private mutating func trimImageAttachmentsToFit(maxTotalImageBytes: Int64) {
    guard maxTotalImageBytes >= 0 else {
      messages = messages.map { message in
        var trimmed = message
        trimmed.imageAttachments = []
        return trimmed
      }
      return
    }

    var remainingBytes = maxTotalImageBytes
    // Keep the newest images while preserving message text.
    for index in messages.indices.reversed() {
      let byteCount = AIChatImageAttachmentBudget.byteCount(messages[index].imageAttachments)
      if byteCount <= remainingBytes {
        remainingBytes -= byteCount
      } else {
        messages[index].imageAttachments = []
      }
    }
  }
}

/// The complete, inspectable context that is sent with one AI request.
///
/// The preview shown by the UI and the transport builder both consume this
/// value. `includesImplicitArticleContext` is deliberately explicit so a
/// general request cannot silently acquire the current draft later in the
/// pipeline.
public struct AIContextEnvelope: Hashable, Sendable {
  public var mode: AIPublishingChatContextMode
  public var knowledgePolicy: KnowledgeRetrievalPolicy
  public var explicitContextReferences: [AIContextReference]
  public var explicitContextPrompt: String?
  public var knowledgeContext: KnowledgeContextSnapshot?
  public var transmissionSummary: AIContextTransmissionSummary
  public var includesImplicitArticleContext: Bool

  public init(
    mode: AIPublishingChatContextMode,
    knowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    explicitContextReferences: [AIContextReference] = [],
    explicitContextPrompt: String? = nil,
    knowledgeContext: KnowledgeContextSnapshot? = nil,
    includesImplicitArticleContext: Bool,
    transmissionSummary: AIContextTransmissionSummary? = nil
  ) {
    self.mode = mode
    self.knowledgePolicy = knowledgePolicy
    self.explicitContextReferences = explicitContextReferences
    self.explicitContextPrompt = explicitContextPrompt?.trimmedForPublishing.nilIfEmpty
    self.knowledgeContext = knowledgeContext
    self.includesImplicitArticleContext = includesImplicitArticleContext
    self.transmissionSummary = transmissionSummary
      ?? AIContextTransmissionSummaryService.make(references: explicitContextReferences)
  }

  public static func general(
    knowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    explicitContextReferences: [AIContextReference] = [],
    explicitContextPrompt: String? = nil,
    knowledgeContext: KnowledgeContextSnapshot? = nil
  ) -> Self {
    Self(
      mode: .general,
      knowledgePolicy: knowledgePolicy,
      explicitContextReferences: explicitContextReferences,
      explicitContextPrompt: explicitContextPrompt,
      knowledgeContext: knowledgeContext,
      includesImplicitArticleContext: false
    )
  }
}

/// A draft-independent chat request. Article publishing requests retain their
/// existing `AIPublishingChatRequest` type and remain site/draft-specific.
public struct AIChatRequest: Sendable {
  public var messages: [AIPublishingChatMessage]
  public var context: AIContextEnvelope
  public var modelGrade: AIChatModelGrade
  public var reasoningLevel: AIChatReasoningLevel
  public var selectedModel: String?

  public init(
    messages: [AIPublishingChatMessage],
    context: AIContextEnvelope,
    modelGrade: AIChatModelGrade = .standard,
    reasoningLevel: AIChatReasoningLevel = .deep,
    selectedModel: String? = nil
  ) {
    self.messages = messages
    self.context = context
    self.modelGrade = modelGrade
    self.reasoningLevel = reasoningLevel
    self.selectedModel = selectedModel
  }
}

public struct AIPublishingChatRequest: Sendable {
  public var draft: ArticleDraft
  public var profile: SiteProfile
  public var messages: [AIPublishingChatMessage]
  public var contextMode: AIPublishingChatContextMode
  public var knowledgePolicy: KnowledgeRetrievalPolicy
  public var knowledgeContext: KnowledgeContextSnapshot?
  public var modelGrade: AIChatModelGrade
  public var reasoningLevel: AIChatReasoningLevel
  public var selectedModel: String?
  public var preflightIssues: [PreflightIssue]
  public var publishPackage: PublishPackage?
  public var remoteReviewDraft: RemoteReviewDraft?
  public var workflowContext: AIPublishingWorkflowContext?
  public var focusedParagraph: AIPublishingChatDraftParagraph?
  public var editorSelection: ActiveEditorSelection?
  public var explicitContextReferences: [AIContextReference]
  public var explicitContextPrompt: String?
  public var relatedSuggestions: [SiteRelationSuggestion]
  public var automationDraftVersions: [UUID: Date]

  public init(
    draft: ArticleDraft,
    profile: SiteProfile,
    messages: [AIPublishingChatMessage],
    contextMode: AIPublishingChatContextMode = .site,
    knowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    knowledgeContext: KnowledgeContextSnapshot? = nil,
    modelGrade: AIChatModelGrade = .standard,
    reasoningLevel: AIChatReasoningLevel = .deep,
    selectedModel: String? = nil,
    preflightIssues: [PreflightIssue] = [],
    publishPackage: PublishPackage? = nil,
    remoteReviewDraft: RemoteReviewDraft? = nil,
    workflowContext: AIPublishingWorkflowContext? = nil,
    focusedParagraph: AIPublishingChatDraftParagraph? = nil,
    editorSelection: ActiveEditorSelection? = nil,
    explicitContextReferences: [AIContextReference] = [],
    explicitContextPrompt: String? = nil,
    relatedSuggestions: [SiteRelationSuggestion] = [],
    automationDraftVersions: [UUID: Date] = [:]
  ) {
    self.draft = draft
    self.profile = profile
    self.messages = messages
    self.contextMode = contextMode
    self.knowledgePolicy = knowledgePolicy
    self.knowledgeContext = knowledgeContext
    self.modelGrade = modelGrade
    self.reasoningLevel = reasoningLevel
    self.selectedModel = selectedModel
    self.preflightIssues = preflightIssues
    self.publishPackage = publishPackage
    self.remoteReviewDraft = remoteReviewDraft
    self.workflowContext = workflowContext
    self.focusedParagraph = focusedParagraph
    self.editorSelection = editorSelection
    self.explicitContextReferences = explicitContextReferences
    self.explicitContextPrompt = explicitContextPrompt
    self.relatedSuggestions = relatedSuggestions
    var resolvedDraftVersions = automationDraftVersions
    resolvedDraftVersions[draft.id] = draft.updatedAt
    self.automationDraftVersions = resolvedDraftVersions
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
