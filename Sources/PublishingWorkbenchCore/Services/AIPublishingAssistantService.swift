import Foundation

public struct AIPublishingAssistantService: Sendable {
  let client: AIChatCompletionClient

  public init(client: AIChatCompletionClient = AIChatCompletionClient()) {
    self.client = client
  }

  public func perform(
    _ request: AIPublishingActionRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingActionResult {
    if config.requiresAPIKey && apiKey?.nilIfEmpty == nil {
      throw AIPublishingAssistantError.missingAPIKey
    }
    let taskConfig = AIChatModelCatalog.config(
      for: request.kind.aiModelTaskKind, baseConfig: config)

    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: [
        AIChatMessage(role: "system", content: systemPrompt),
        AIChatMessage(role: "user", content: prompt(for: request)),
      ],
      temperature: 0.3
    )
    let result = try await client.complete(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .utilityTask
    )
    return AIPublishingActionResult(
      kind: request.kind,
      content: result.content,
      providerName: taskConfig.normalizedDisplayName,
      model: result.rawModel?.nilIfEmpty ?? taskConfig.normalizedModel,
      knowledgeCitations: request.knowledgeContext?.citations ?? []
    )
  }

  public func reply(
    to request: AIPublishingChatRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let taskConfig = try chatTaskConfig(for: request, config: config, apiKey: apiKey)
    let reasoningOptions = request.reasoningLevel.requestOptions(for: taskConfig)
    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: chatMessages(for: request),
      temperature: 0.4,
      thinking: reasoningOptions?.thinking,
      reasoningEffort: reasoningOptions?.reasoningEffort
    )
    let result = try await client.complete(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .interactiveChat
    )
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: result.content,
      model: result.rawModel?.nilIfEmpty ?? taskConfig.normalizedModel,
      tokenUsage: result.tokenUsage,
      contextMode: request.contextMode,
      knowledgeCitations: request.knowledgeContext?.citations ?? []
    )
    return preparingAutomationPlan(in: message, request: request)
  }

  public func streamReply(
    to request: AIPublishingChatRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatReplyStream {
    let taskConfig = try chatTaskConfig(for: request, config: config, apiKey: apiKey)
    let reasoningOptions = request.reasoningLevel.requestOptions(for: taskConfig)
    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: chatMessages(for: request),
      temperature: 0.4,
      thinking: reasoningOptions?.thinking,
      reasoningEffort: reasoningOptions?.reasoningEffort
    )
    let updates = try await client.stream(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .interactiveChat
    )
    return AIPublishingChatReplyStream(
      initialMessage: AIPublishingChatMessage(
        role: .assistant,
        content: "",
        model: taskConfig.normalizedModel,
        contextMode: request.contextMode,
        knowledgeCitations: request.knowledgeContext?.citations ?? []
      ),
      updates: updates
    )
  }

  public func preparingAutomationPlan(
    in message: AIPublishingChatMessage,
    request: AIPublishingChatRequest
  ) -> AIPublishingChatMessage {
    guard request.contextMode == .site else { return message }
    if let reformatReply = AIPublishingChatReformatService.prepareReply(
      message,
      request: request
    ) {
      return reformatReply
    }
    if let structuredEditReply = AIPublishingChatStructuredEditService.prepareReply(
      message,
      request: request
    ) {
      return structuredEditReply
    }
    if let translationDraftReply = AIPublishingChatTranslationDraftService.prepareReply(
      message,
      request: request
    ) {
      return translationDraftReply
    }
    if let directEditReply = AIPublishingChatDirectEditService.prepareReply(
      message,
      request: request
    ) {
      return directEditReply
    }
    let parsed = WorkbenchAutomationPlanParser.parse(
      message.content,
      currentDraft: request.draft,
      draftVersions: request.automationDraftVersions
    )
    guard let plan = parsed.plan else { return message }
    var prepared = message
    prepared.content = parsed.displayContent
    prepared.automationPlan = plan
    return prepared
  }

  private func chatTaskConfig(
    for request: AIPublishingChatRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) throws -> AIProviderConfig {
    if config.requiresAPIKey && apiKey?.nilIfEmpty == nil {
      throw AIPublishingAssistantError.missingAPIKey
    }
    guard let latestUserMessage = request.messages.last(where: { $0.role == .user }),
      latestUserMessage.content.nilIfEmpty != nil || !latestUserMessage.imageAttachments.isEmpty
    else {
      throw AIPublishingAssistantError.emptyChatMessage
    }
    if request.messages.contains(where: { !$0.imageAttachments.isEmpty }),
      !config.supportsImageInput
    {
      throw AIPublishingAssistantError.unsupportedImageAttachments(config.normalizedDisplayName)
    }

    var taskConfig = config
    let currentModel = request.selectedModel?.nilIfEmpty ?? config.normalizedModel
    taskConfig.model = AIChatModelCatalog.model(
      for: request.modelGrade,
      config: config,
      currentModel: currentModel
    )
    return taskConfig
  }

  private var systemPrompt: String {
    "你是 RepoPress Studio 的发布上下文助手。你不做泛聊天，只围绕当前文章、站点结构、front matter、SEO、公开风险、图片和发布说明给建议。只输出给用户的最终答复，不得展示思考、推理、权衡、草稿或内部决策过程；信息不足时直接、简短地说明。"
  }

}


public enum AIPublishingAssistantError: LocalizedError, Equatable {
  case dataSharingConsentRequired(providerName: String, destination: String)
  case missingAPIKey
  case emptyChatMessage
  case unsupportedImageAttachments(String)
  case emptyMetadataSuggestion
  case emptyImageTextTargets
  case emptyImageTextSuggestions

  public var errorDescription: String? {
    switch self {
    case .dataSharingConsentRequired(let providerName, let destination):
      return "发送前，请先在“设置 → AI 写作”中同意将内容发送给 \(providerName)（\(destination)）处理。"
    case .missingAPIKey:
      return "请先在 Settings 的 AI 页保存 API Key。"
    case .emptyChatMessage:
      return "请先输入要发送给 AI 的内容。"
    case .unsupportedImageAttachments(let providerName):
      return "\(providerName) 当前接口不支持图片输入，请切换到支持视觉输入的模型。"
    case .emptyMetadataSuggestion:
      return "AI 没有返回可应用的元数据建议。"
    case .emptyImageTextTargets:
      return "当前文章没有需要生成 alt/caption 的图片。"
    case .emptyImageTextSuggestions:
      return "AI 没有返回可应用的图片 alt/caption 建议。"
    }
  }
}
