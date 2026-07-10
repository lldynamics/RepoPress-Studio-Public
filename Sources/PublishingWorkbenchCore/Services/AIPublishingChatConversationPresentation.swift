import Foundation

public enum AIPublishingChatConversationPresentation {
  public static func title(
    fromUserText text: String,
    fallbackTitle: String,
    maxLength: Int = 34
  ) -> String {
    let trimmed = text.trimmedForPublishing
    guard !trimmed.isEmpty else {
      return fallbackTitle
    }
    return clipped(trimmed, maxLength: maxLength)
  }

  public static func displayTitle(
    conversationTitle: String? = nil,
    messages: [AIPublishingChatMessage],
    draft: ArticleDraft,
    emptyTitle: String = "AI 对话",
    maxLength: Int = 34
  ) -> String {
    if let conversationTitle = conversationTitle?.trimmedForPublishing.nilIfEmpty {
      return clipped(conversationTitle, maxLength: maxLength)
    }

    if let firstUserMessage = messages
      .first(where: { $0.role == .user })
      .map(AIPublishingChatMessageCompositionService.displayContent(for:))?
      .nilIfEmpty {
      return title(
        fromUserText: firstUserMessage,
        fallbackTitle: emptyTitle,
        maxLength: maxLength
      )
    }

    return draft.title.nilIfEmpty ?? emptyTitle
  }

  public static func contextSummary(
    profile: SiteProfile,
    draft: ArticleDraft,
    contextMode: AIPublishingChatContextMode,
    selectedParagraphTitle: String? = nil
  ) -> String {
    guard contextMode == .site else {
      return "通用聊天 · 不读取当前文章或发布上下文"
    }

    let articleTitle = draft.title.nilIfEmpty ?? "未命名文章"
    if let selectedParagraphTitle = selectedParagraphTitle?.nilIfEmpty {
      return "\(profile.name) · \(articleTitle) · \(selectedParagraphTitle)"
    }
    return "\(profile.name) · \(profile.markdownPath(for: draft))"
  }

  public static func contextDetails(
    profile: SiteProfile,
    draft: ArticleDraft,
    visibleDrafts: [ArticleDraft],
    contextMode: AIPublishingChatContextMode,
    selectedParagraph: AIPublishingChatDraftParagraph? = nil,
    relatedSuggestionCount: Int = 0
  ) -> AIPublishingChatContextPresentation {
    let publicCandidateCount = visibleDrafts.filter { candidate in
      candidate.id != draft.id && candidate.visibility == .public
    }.count
    let resolvedRelatedSuggestionCount = contextMode == .site ? max(relatedSuggestionCount, 0) : 0
    let selectedParagraphPreview = selectedParagraph.map { paragraph in
      paragraph.text.trimmedForPublishing.clippedForAIContextPreview(maxLength: 180)
    }
    let basis: String
    switch contextMode {
    case .site:
      basis = selectedParagraph == nil ? "当前文章 + 用户问题" : "当前段落 + 当前文章 + 用户问题"
    case .general:
      basis = "当前对话消息"
    }

    return AIPublishingChatContextPresentation(
      title: draft.title.nilIfEmpty ?? "未命名文章",
      markdownPath: profile.markdownPath(for: draft),
      contextMode: contextMode,
      retrievalBasis: basis,
      publicCandidateCount: publicCandidateCount,
      relatedSuggestionCount: resolvedRelatedSuggestionCount,
      selectedParagraphTitle: selectedParagraph?.title,
      selectedParagraphPreview: selectedParagraphPreview
    )
  }

  public static func modelSummary(
    grade: AIChatModelGrade,
    config: AIProviderConfig,
    selectedModel: String
  ) -> String {
    let currentModel = grade == .custom ? selectedModel : config.normalizedModel
    let model = AIChatModelCatalog.model(
      for: grade,
      config: config,
      currentModel: currentModel
    )
    return "\(grade.title) · \(model)"
  }

  public static func archivedConversationPresentation(
    for conversation: AIPublishingChatArchivedConversation,
    config: AIProviderConfig
  ) -> AIPublishingArchivedChatConversationPresentation {
    let messageCountText = "\(conversation.messages.count) 条消息"
    let contextText = conversation.contextMode.displayName
    let modelText = modelSummary(
      grade: conversation.modelGrade,
      config: config,
      selectedModel: conversation.selectedModel
    )
    return AIPublishingArchivedChatConversationPresentation(
      id: conversation.id,
      title: archivedConversationTitle(for: conversation),
      messageCountText: messageCountText,
      contextText: contextText,
      modelText: modelText,
      subtitle: [messageCountText, contextText, modelText].joined(separator: " · ")
    )
  }

  private static func archivedConversationTitle(
    for conversation: AIPublishingChatArchivedConversation,
    emptyTitle: String = "AI 对话"
  ) -> String {
    if let title = conversation.title.nilIfEmpty,
       title != "新对话",
       title != "New Chat" {
      return title
    }

    if let firstUserMessage = conversation.messages
      .first(where: { $0.role == .user })
      .map(AIPublishingChatMessageCompositionService.displayContent(for:))?
      .nilIfEmpty {
      return title(fromUserText: firstUserMessage, fallbackTitle: emptyTitle)
    }

    return emptyTitle
  }

  public static func streamingStatus(tokenUsage: AIChatTokenUsage?) -> String {
    guard let tokenUsage else {
      return "AI 正在回复"
    }
    return "AI 正在回复 · \(tokenUsage.displayText)"
  }

  public static func configurationIssue(
    config: AIProviderConfig,
    aiTokenAvailability: KeychainTokenAvailability,
    grade: AIChatModelGrade,
    selectedModel: String
  ) -> String? {
    if grade == .custom && selectedModel.trimmedForPublishing.isEmpty {
      return "AI 模型名称为空，请先选择模型等级或填写模型名。"
    }

    let activeModel = AIChatModelCatalog.model(
      for: grade,
      config: config,
      currentModel: grade == .custom ? selectedModel : config.normalizedModel
    ).trimmedForPublishing
    guard !activeModel.isEmpty else {
      return "AI 模型名称为空，请先选择模型等级或填写模型名。"
    }

    guard !config.normalizedBaseURL.trimmedForPublishing.isEmpty else {
      return "AI API Base URL 为空，请先到设置里填写。"
    }

    if config.requiresAPIKey && !aiTokenAvailability.hasToken {
      return "AI API Key 未保存，请先到设置里保存当前 Profile 的 API Key。"
    }

    return nil
  }

  public static func sendReadiness(
    inputText: String,
    selectedImageCount: Int,
    isSending: Bool,
    config: AIProviderConfig,
    aiTokenAvailability: KeychainTokenAvailability,
    grade: AIChatModelGrade,
    selectedModel: String
  ) -> AIPublishingChatSendReadiness {
    let trimmedInput = inputText.trimmedForPublishing
    let configurationIssue = configurationIssue(
      config: config,
      aiTokenAvailability: aiTokenAvailability,
      grade: grade,
      selectedModel: selectedModel
    )
    let imageIssue: String?
    if selectedImageCount > 0 && !config.supportsImageInput {
      imageIssue = "\(config.normalizedDisplayName) 当前接口不支持图片输入，请切换到支持视觉输入的 OpenAI-compatible 模型。"
    } else {
      imageIssue = nil
    }
    return AIPublishingChatSendReadiness(
      trimmedInput: trimmedInput,
      configurationIssue: configurationIssue,
      imageAttachmentIssue: imageIssue,
      canSend: (!trimmedInput.isEmpty || selectedImageCount > 0)
        && !isSending
        && configurationIssue == nil
        && imageIssue == nil
    )
  }

  private static func clipped(_ text: String, maxLength: Int) -> String {
    guard text.count > maxLength else {
      return text
    }
    return "\(text.prefix(maxLength))..."
  }
}

public struct AIPublishingChatSendReadiness: Equatable, Sendable {
  public var trimmedInput: String
  public var configurationIssue: String?
  public var imageAttachmentIssue: String?
  public var canSend: Bool

  public init(
    trimmedInput: String,
    configurationIssue: String?,
    imageAttachmentIssue: String?,
    canSend: Bool
  ) {
    self.trimmedInput = trimmedInput
    self.configurationIssue = configurationIssue
    self.imageAttachmentIssue = imageAttachmentIssue
    self.canSend = canSend
  }
}

public struct AIPublishingChatImageImportPresentation: Equatable, Sendable {
  public var importedCount: Int
  public var selectedCount: Int
  public var skippedSelectionCount: Int
  public var skippedSizeCount: Int
  public var message: String

  public init(
    importedCount: Int,
    selectedCount: Int,
    skippedSelectionCount: Int,
    skippedSizeCount: Int = 0,
    message: String
  ) {
    self.importedCount = importedCount
    self.selectedCount = selectedCount
    self.skippedSelectionCount = skippedSelectionCount
    self.skippedSizeCount = skippedSizeCount
    self.message = message
  }
}

public enum AIPublishingChatImageAttachmentPresentation {
  public static let maxSelectedImageCount = 4
  public static let maxAttachmentBytes = 8 * 1_024 * 1_024

  public static func maximumSelectionMessage(
    maxSelectedImageCount: Int = Self.maxSelectedImageCount
  ) -> String {
    "一次最多附加 \(maxSelectedImageCount) 张图片给 AI。"
  }

  public static func isWithinAttachmentSizeLimit(_ byteSize: Int64) -> Bool {
    byteSize <= Int64(maxAttachmentBytes)
  }

  public static func attachmentSizeLimitText(
    maxAttachmentBytes: Int = Self.maxAttachmentBytes
  ) -> String {
    String(format: "%.1f MB", Double(maxAttachmentBytes) / 1_000_000)
  }

  public static func importPresentation(
    importedCount: Int,
    selectableImportedCount: Int? = nil,
    availableSelectionSlots: Int,
    maxSelectedImageCount: Int = Self.maxSelectedImageCount
  ) -> AIPublishingChatImageImportPresentation {
    let normalizedImportedCount = max(importedCount, 0)
    let normalizedSelectableCount = min(
      max(selectableImportedCount ?? normalizedImportedCount, 0),
      normalizedImportedCount
    )
    let normalizedAvailableSlots = max(availableSelectionSlots, 0)
    let selectedCount = min(normalizedSelectableCount, normalizedAvailableSlots)
    let skippedSelectionCount = max(0, normalizedSelectableCount - selectedCount)
    let skippedSizeCount = max(0, normalizedImportedCount - normalizedSelectableCount)
    let message: String

    if normalizedImportedCount == 0 {
      message = "没有可添加的图片文件。"
    } else if skippedSelectionCount == 0 && skippedSizeCount == 0 {
      message = "已添加 \(normalizedImportedCount) 张图片到当前文章，可随本次问题发送给 AI。"
    } else {
      var skippedReasons: [String] = []
      if skippedSelectionCount > 0 {
        skippedReasons.append("另有 \(skippedSelectionCount) 张因最多 \(maxSelectedImageCount) 张限制未附加")
      }
      if skippedSizeCount > 0 {
        skippedReasons.append("\(skippedSizeCount) 张超过 \(attachmentSizeLimitText())，未附加给 AI")
      }
      message = "已添加 \(normalizedImportedCount) 张图片到当前文章；本次已选 \(selectedCount) 张，\(skippedReasons.joined(separator: "，"))。"
    }

    return AIPublishingChatImageImportPresentation(
      importedCount: normalizedImportedCount,
      selectedCount: selectedCount,
      skippedSelectionCount: skippedSelectionCount,
      skippedSizeCount: skippedSizeCount,
      message: message
    )
  }
}

public struct AIPublishingArchivedChatConversationPresentation: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var messageCountText: String
  public var contextText: String
  public var modelText: String
  public var subtitle: String

  public init(
    id: UUID,
    title: String,
    messageCountText: String,
    contextText: String,
    modelText: String,
    subtitle: String
  ) {
    self.id = id
    self.title = title
    self.messageCountText = messageCountText
    self.contextText = contextText
    self.modelText = modelText
    self.subtitle = subtitle
  }
}

public struct AIPublishingChatMessageActionAvailability: Equatable, Sendable {
  public var canCopy: Bool
  public var canQuote: Bool
  public var canRegenerate: Bool
  public var canApplyToArticle: Bool

  public init(
    canCopy: Bool,
    canQuote: Bool,
    canRegenerate: Bool,
    canApplyToArticle: Bool
  ) {
    self.canCopy = canCopy
    self.canQuote = canQuote
    self.canRegenerate = canRegenerate
    self.canApplyToArticle = canApplyToArticle
  }
}

public enum AIPublishingChatMessageActionAvailabilityService {
  public static func availability(
    for message: AIPublishingChatMessage,
    isSending: Bool,
    configurationIssue: String?,
    hasSelectedDraft: Bool
  ) -> AIPublishingChatMessageActionAvailability {
    let hasTextContent = !message.content.trimmedForPublishing.isEmpty
    let hasDisplayContent = hasTextContent || !message.imageAttachments.isEmpty
    return AIPublishingChatMessageActionAvailability(
      canCopy: hasDisplayContent,
      canQuote: hasDisplayContent,
      canRegenerate: message.role == .assistant
        && !isSending
        && configurationIssue == nil
        && hasTextContent,
      canApplyToArticle: message.role == .assistant
        && message.contextMode == .site
        && hasSelectedDraft
        && hasTextContent
        && !isSending
    )
  }
}

public struct AIPublishingChatContextPresentation: Equatable, Sendable {
  public var title: String
  public var markdownPath: String
  public var contextMode: AIPublishingChatContextMode
  public var retrievalBasis: String
  public var publicCandidateCount: Int
  public var relatedSuggestionCount: Int
  public var selectedParagraphTitle: String?
  public var selectedParagraphPreview: String?

  public init(
    title: String,
    markdownPath: String,
    contextMode: AIPublishingChatContextMode,
    retrievalBasis: String,
    publicCandidateCount: Int,
    relatedSuggestionCount: Int = 0,
    selectedParagraphTitle: String? = nil,
    selectedParagraphPreview: String? = nil
  ) {
    self.title = title
    self.markdownPath = markdownPath
    self.contextMode = contextMode
    self.retrievalBasis = retrievalBasis
    self.publicCandidateCount = publicCandidateCount
    self.relatedSuggestionCount = relatedSuggestionCount
    self.selectedParagraphTitle = selectedParagraphTitle
    self.selectedParagraphPreview = selectedParagraphPreview
  }
}

private extension String {
  func clippedForAIContextPreview(maxLength: Int) -> String {
    guard count > maxLength else {
      return self
    }
    return "\(prefix(maxLength))..."
  }
}
