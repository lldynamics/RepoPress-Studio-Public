import Foundation

/// A task-resolved, privacy-bound transport. The request and its prepared
/// client seal are intentionally exposed to Core callers so an authorization gate
/// and a later agent round can reuse the exact normalized body without a
/// second normalization pass.
public struct AIPreparedPublishingChatTransport: Sendable {
  public let taskConfig: AIProviderConfig
  public let preparedRequest: AIPreparedAIChatCompletionRequest
  public let payload: AIPreparedOutboundPayload
  public let publishingRequest: AIPublishingChatRequest?
  public let generalRequest: AIChatRequest?

  init(
    taskConfig: AIProviderConfig,
    preparedRequest: AIPreparedAIChatCompletionRequest,
    payload: AIPreparedOutboundPayload,
    publishingRequest: AIPublishingChatRequest? = nil,
    generalRequest: AIChatRequest? = nil
  ) {
    self.taskConfig = taskConfig
    self.preparedRequest = preparedRequest
    self.payload = payload
    self.publishingRequest = publishingRequest
    self.generalRequest = generalRequest
  }

  func bindingAuthorizationDeadline(
    _ deadline: Date
  ) -> AIPreparedPublishingChatTransport {
    let boundRequest = preparedRequest.bindingAuthorizationDeadline(deadline)
    return AIPreparedPublishingChatTransport(
      taskConfig: taskConfig,
      preparedRequest: boundRequest,
      payload: payload.withPreparedRequest(boundRequest),
      publishingRequest: publishingRequest,
      generalRequest: generalRequest
    )
  }
}

public struct AIPublishingAssistantService: Sendable {
  let client: AIChatCompletionClient

  /// The transport message scan is stateless. Keep this adapter capture-free so
  /// the provider's `@Sendable` transform does not carry a privacy-service
  /// instance across the concurrency boundary.
  private static let transportMessageSanitizer:
    @Sendable ([AIChatMessage]) throws -> [AIChatMessage] = { messages in
      AIOutboundPayloadPrivacyService().sanitizedMessagesForTransport(messages)
    }

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
    let prepared = try client.prepareRequest(
      completion,
      config: taskConfig,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let result = try await client.completePrepared(prepared, config: taskConfig, apiKey: apiKey)
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: result.content,
      model: result.rawModel?.nilIfEmpty ?? taskConfig.normalizedModel,
      tokenUsage: result.tokenUsage,
      contextMode: request.contextMode,
      knowledgeCitations: request.knowledgeContext?.citations ?? []
    )
    return preparingProtectedEdit(in: message, request: request)
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
    let prepared = try client.prepareRequest(
      completion,
      config: taskConfig,
      purpose: .interactiveChat,
      mode: .streaming
    )
    let updates = try await client.streamPrepared(prepared, config: taskConfig, apiKey: apiKey)
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

  /// Sends a draft-independent request. This path intentionally has no
  /// `ArticleDraft` or `SiteProfile` parameter, so a general conversation can
  /// only transmit the context envelope assembled by the caller.
  public func reply(
    to request: AIChatRequest,
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
    let prepared = try client.prepareRequest(
      completion,
      config: taskConfig,
      purpose: .interactiveChat,
      mode: .nonStreaming
    )
    let result = try await client.completePrepared(prepared, config: taskConfig, apiKey: apiKey)
    return AIPublishingChatMessage(
      role: .assistant,
      content: result.content,
      model: result.rawModel?.nilIfEmpty ?? taskConfig.normalizedModel,
      tokenUsage: result.tokenUsage,
      contextMode: request.context.mode,
      knowledgeCitations: request.context.knowledgeContext?.citations ?? []
    )
  }

  public func streamReply(
    to request: AIChatRequest,
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
    let prepared = try client.prepareRequest(
      completion,
      config: taskConfig,
      purpose: .interactiveChat,
      mode: .streaming
    )
    let updates = try await client.streamPrepared(prepared, config: taskConfig, apiKey: apiKey)
    return AIPublishingChatReplyStream(
      initialMessage: AIPublishingChatMessage(
        role: .assistant,
        content: "",
        model: taskConfig.normalizedModel,
        contextMode: request.context.mode,
        knowledgeCitations: request.context.knowledgeContext?.citations ?? []
      ),
      updates: updates
    )
  }

  /// Builds and privacy-binds the final article chat transport. The client
  /// performs provider normalization first, then the privacy transform
  /// redacts normalized messages before canonical encoding.
  func prepareTransport(
    for request: AIPublishingChatRequest,
    config: AIProviderConfig,
    privacyService: AIOutboundPayloadPrivacyService,
    transportVariant: AIOutboundPayloadTransportVariant? = nil,
    contextCounts: [AIOutboundPayloadContextCount] = [],
    contextBindingValues: [String] = [],
    now: Date = Date(),
    nonce: UUID = UUID()
  ) throws -> AIPreparedPublishingChatTransport {
    let taskConfig = try resolvedChatTaskConfig(
      for: request, config: privacyService.sanitizedProviderConfig(config))
    let variant = transportVariant ?? preferredTransportVariant(for: taskConfig)
    let completion = chatCompletionRequest(for: request, taskConfig: taskConfig)
    let preparedRequest = try client.prepareRequest(
      completion,
      config: taskConfig,
      purpose: .interactiveChat,
      mode: variant == .stream ? .streaming : .nonStreaming,
      transformMessages: Self.transportMessageSanitizer
    )
    let payload = privacyService.prepare(
      preparedRequest: preparedRequest,
      taskConfig: taskConfig,
      contextCounts: contextCounts.isEmpty
        ? outboundContextCounts(
          references: request.explicitContextReferences,
          hasAutomaticKnowledge: request.knowledgeContext?.citations.isEmpty == false,
          includesImplicitArticleContext: request.contextMode == .site,
          conversationMessageCount: request.messages.suffix(12).count
        )
        : contextCounts,
      contextBindingValues: contextBindingValues.isEmpty
        ? outboundContextBindingValues(
          references: request.explicitContextReferences,
          contextMode: request.contextMode,
          knowledgePolicy: request.knowledgePolicy,
          reasoningLevel: request.reasoningLevel,
          modelGrade: request.modelGrade,
          includesImplicitArticleContext: request.contextMode == .site,
          transportVariant: variant,
          config: taskConfig
        )
        : contextBindingValues,
      now: now,
      nonce: nonce
    )
    return AIPreparedPublishingChatTransport(
      taskConfig: taskConfig,
      preparedRequest: preparedRequest,
      payload: payload,
      publishingRequest: request
    )
  }

  /// Builds a general-chat transport using the same exact preparation path.
  func prepareTransport(
    for request: AIChatRequest,
    config: AIProviderConfig,
    privacyService: AIOutboundPayloadPrivacyService,
    transportVariant: AIOutboundPayloadTransportVariant? = nil,
    contextCounts: [AIOutboundPayloadContextCount] = [],
    contextBindingValues: [String] = [],
    now: Date = Date(),
    nonce: UUID = UUID()
  ) throws -> AIPreparedPublishingChatTransport {
    let taskConfig = try resolvedChatTaskConfig(
      for: request, config: privacyService.sanitizedProviderConfig(config))
    let variant = transportVariant ?? preferredTransportVariant(for: taskConfig)
    let completion = chatCompletionRequest(for: request, taskConfig: taskConfig)
    let preparedRequest = try client.prepareRequest(
      completion,
      config: taskConfig,
      purpose: .interactiveChat,
      mode: variant == .stream ? .streaming : .nonStreaming,
      transformMessages: Self.transportMessageSanitizer
    )
    let payload = privacyService.prepare(
      preparedRequest: preparedRequest,
      taskConfig: taskConfig,
      contextCounts: contextCounts.isEmpty
        ? outboundContextCounts(
          references: request.context.explicitContextReferences,
          hasAutomaticKnowledge: request.context.knowledgeContext?.citations.isEmpty == false,
          includesImplicitArticleContext: false,
          conversationMessageCount: request.messages.suffix(12).count
        )
        : contextCounts,
      contextBindingValues: contextBindingValues.isEmpty
        ? outboundContextBindingValues(
          references: request.context.explicitContextReferences,
          contextMode: request.context.mode,
          knowledgePolicy: request.context.knowledgePolicy,
          reasoningLevel: request.reasoningLevel,
          modelGrade: request.modelGrade,
          includesImplicitArticleContext: false,
          transportVariant: variant,
          config: taskConfig
        )
        : contextBindingValues,
      now: now,
      nonce: nonce
    )
    return AIPreparedPublishingChatTransport(
      taskConfig: taskConfig,
      preparedRequest: preparedRequest,
      payload: payload,
      generalRequest: request
    )
  }

  /// Prepares an already-assembled native agent round. This exact-body path
  /// never rebuilds high-level article context or normalizes messages twice.
  func prepareTransport(
    completion: AIChatCompletionRequest,
    taskConfig: AIProviderConfig,
    privacyService: AIOutboundPayloadPrivacyService,
    contextCounts: [AIOutboundPayloadContextCount] = [],
    contextBindingValues: [String] = [],
    now: Date = Date(),
    nonce: UUID = UUID()
  ) throws -> AIPreparedPublishingChatTransport {
    let sanitizedTaskConfig = privacyService.sanitizedProviderConfig(taskConfig)
    let preparedRequest = try client.prepareRequest(
      completion,
      config: sanitizedTaskConfig,
      purpose: .interactiveChat,
      mode: .nonStreaming,
      transformMessages: Self.transportMessageSanitizer
    )
    let payload = privacyService.prepare(
      preparedRequest: preparedRequest,
      taskConfig: sanitizedTaskConfig,
      contextCounts: contextCounts,
      contextBindingValues: contextBindingValues,
      now: now,
      nonce: nonce
    )
    return AIPreparedPublishingChatTransport(
      taskConfig: sanitizedTaskConfig,
      preparedRequest: preparedRequest,
      payload: payload
    )
  }

  func completePrepared(
    _ transport: AIPreparedPublishingChatTransport,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let result = try await completePreparedResult(transport, apiKey: apiKey)
    let contextMode =
      transport.publishingRequest?.contextMode
      ?? transport.generalRequest?.context.mode
      ?? .general
    return AIPublishingChatMessage(
      role: .assistant,
      content: result.content,
      model: result.rawModel?.nilIfEmpty ?? transport.taskConfig.normalizedModel,
      tokenUsage: result.tokenUsage,
      contextMode: contextMode,
      knowledgeCitations: transport.publishingRequest?.knowledgeContext?.citations
        ?? transport.generalRequest?.context.knowledgeContext?.citations
        ?? []
    )
  }

  /// Low-level result wrapper used by the agent loop when tool calls and the
  /// provider's raw model need to be inspected before a user-facing message
  /// is created.
  func completePreparedResult(
    _ transport: AIPreparedPublishingChatTransport,
    apiKey: String?
  ) async throws -> AIChatCompletionResult {
    try await client.completePrepared(
      transport.preparedRequest,
      config: transport.taskConfig,
      apiKey: apiKey
    )
  }

  func streamPrepared(
    _ transport: AIPreparedPublishingChatTransport,
    apiKey: String?
  ) async throws -> AIPublishingChatReplyStream {
    let updates = try await client.streamPrepared(
      transport.preparedRequest,
      config: transport.taskConfig,
      apiKey: apiKey
    )
    let contextMode =
      transport.publishingRequest?.contextMode
      ?? transport.generalRequest?.context.mode
      ?? .general
    return AIPublishingChatReplyStream(
      initialMessage: AIPublishingChatMessage(
        role: .assistant,
        content: "",
        model: transport.taskConfig.normalizedModel,
        contextMode: contextMode,
        knowledgeCitations: transport.publishingRequest?.knowledgeContext?.citations
          ?? transport.generalRequest?.context.knowledgeContext?.citations
          ?? []
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

  /// Applies only the protected edit post-processors used by the article
  /// editor. Marker-based automation plans are intentionally left to the
  /// native tool-calling agent path and are never parsed on ordinary replies.
  func preparingProtectedEdit(
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
    return message
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

  /// Resolves the final task model without reading credentials. Preview and
  /// agent callers use this before authorization so capability selection and model
  /// binding are identical to the eventual interactive request.
  func resolvedChatTaskConfig(
    for request: AIPublishingChatRequest,
    config: AIProviderConfig
  ) throws -> AIProviderConfig {
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

  func resolvedChatTaskConfig(
    for request: AIChatRequest,
    config: AIProviderConfig
  ) throws -> AIProviderConfig {
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

  func preferredTransportVariant(
    for config: AIProviderConfig
  ) -> AIOutboundPayloadTransportVariant {
    config.capabilitySupport(for: .streamingResponse) == .supported ? .stream : .complete
  }

  func chatCompletionRequest(
    for request: AIPublishingChatRequest,
    taskConfig: AIProviderConfig
  ) -> AIChatCompletionRequest {
    let reasoningOptions = request.reasoningLevel.requestOptions(for: taskConfig)
    return AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: chatMessages(for: request),
      temperature: 0.4,
      thinking: reasoningOptions?.thinking,
      reasoningEffort: reasoningOptions?.reasoningEffort
    )
  }

  func chatCompletionRequest(
    for request: AIChatRequest,
    taskConfig: AIProviderConfig
  ) -> AIChatCompletionRequest {
    let reasoningOptions = request.reasoningLevel.requestOptions(for: taskConfig)
    return AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: chatMessages(for: request),
      temperature: 0.4,
      thinking: reasoningOptions?.thinking,
      reasoningEffort: reasoningOptions?.reasoningEffort
    )
  }

  private func chatTaskConfig(
    for request: AIChatRequest,
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
