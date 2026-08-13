import Foundation

extension AIChatCompletionClient {
  func normalizedRequest(
    _ request: AIChatCompletionRequest,
    config: AIProviderConfig,
    purpose: AIProviderRequestPurpose
  ) throws -> AIChatCompletionRequest {
    let advancedSettings = config.resolvedAdvancedSettings
    let appliesInteractiveOverrides = purpose == .interactiveChat
    let requestedTemperature =
      appliesInteractiveOverrides
      ? (advancedSettings.normalizedTemperature ?? request.temperature)
      : request.temperature
    let requestOptions = config.chatRequestOptions(
      temperature: requestedTemperature,
      purpose: purpose
    )
    let reasoningSupport = config.capabilitySupport(for: .reasoningControl)
    let isCapabilityProbe = purpose == .capabilityProbe
    let canSendTools =
      isCapabilityProbe
      || config.capabilitySupport(for: .toolCalling) == .supported
    let canSendStructuredOutput =
      isCapabilityProbe
      || config.capabilitySupport(for: .structuredOutput) == .supported
    let canSendVision =
      isCapabilityProbe
      || config.capabilitySupport(for: .visionInput) == .supported
    let canSendReasoning = reasoningSupport == .supported
    let safeRequestOptions =
      canSendReasoning
      ? requestOptions
      : AIProviderChatRequestOptions(
        temperature: requestOptions.temperature,
        thinking: nil,
        reasoningEffort: nil
      )
    let explicitThinking = canSendReasoning ? request.thinking : nil
    let explicitReasoningEffort = canSendReasoning ? request.reasoningEffort : nil
    let hasExplicitReasoningOptions = explicitThinking != nil || explicitReasoningEffort != nil
    let advancedReasoningPreference =
      !canSendReasoning
      ? AIProviderReasoningPreference.automatic
      : advancedSettings.reasoningPreference
    let reasoningOptions = normalizedReasoningOptions(
      explicitThinking: explicitThinking,
      explicitReasoningEffort: explicitReasoningEffort,
      fallback: safeRequestOptions,
      preference: appliesInteractiveOverrides
        ? advancedReasoningPreference
        : .automatic,
      config: config
    )
    return AIChatCompletionRequest(
      model: config.requestModel(resolving: request.model),
      messages: try sanitizedMessages(
        appliesInteractiveOverrides
          ? messages(
            request.messages,
            appendingSystemPrompt: advancedSettings.normalizedSystemPrompt
          )
          : request.messages,
        canSendTools: canSendTools,
        canSendVision: canSendVision
      ),
      temperature: requestOptions.temperature,
      maximumOutputTokens: request.maximumOutputTokens
        ?? (appliesInteractiveOverrides
          ? advancedSettings.normalizedMaximumOutputTokens
          : nil),
      thinking: reasoningOptions.thinking,
      reasoningEffort: hasExplicitReasoningOptions
        ? explicitReasoningEffort
        : reasoningOptions.reasoningEffort,
      stream: request.stream,
      streamOptions: request.streamOptions,
      tools: canSendTools ? request.tools : nil,
      toolChoice: canSendTools ? request.toolChoice : nil,
      responseFormat: canSendStructuredOutput ? request.responseFormat : nil
    )
  }

  func sanitizedMessages(
    _ messages: [AIChatMessage],
    canSendTools: Bool,
    canSendVision: Bool
  ) throws -> [AIChatMessage] {
    if !canSendTools,
      messages.contains(where: hasToolProtocolHistory)
    {
      throw AIChatCompletionClientError.unsupportedToolHistory
    }

    return try messages.compactMap { message in
      var sanitized = message
      if !canSendVision,
        case .parts(let parts)? = sanitized.content
      {
        let textParts = parts.filter { $0.type != .imageURL }
        if textParts.isEmpty, parts.contains(where: { $0.type == .imageURL }) {
          throw AIChatCompletionClientError.imageContentRequiresVisionCapability
        }
        sanitized.content = textParts.isEmpty ? nil : .parts(textParts)
      }
      return sanitized
    }
  }

  private func hasToolProtocolHistory(_ message: AIChatMessage) -> Bool {
    message.role.lowercased() == "tool"
      || message.toolCalls != nil
      || message.toolCallID?.nilIfEmpty != nil
  }

  private func messages(
    _ messages: [AIChatMessage],
    appendingSystemPrompt systemPrompt: String
  ) -> [AIChatMessage] {
    guard !systemPrompt.isEmpty else { return messages }
    var updated = messages
    if let index = updated.firstIndex(where: { $0.role == "system" }),
      case .text(let existingPrompt)? = updated[index].content
    {
      updated[index].content = .text(
        [existingPrompt.trimmedForPublishing, systemPrompt]
          .filter { !$0.isEmpty }
          .joined(separator: "\n\n")
      )
    } else {
      updated.insert(AIChatMessage(role: "system", content: systemPrompt), at: 0)
    }
    return updated
  }

  private func normalizedReasoningOptions(
    explicitThinking: AIProviderThinkingOption?,
    explicitReasoningEffort: String?,
    fallback: AIProviderChatRequestOptions,
    preference: AIProviderReasoningPreference,
    config: AIProviderConfig
  ) -> AIProviderChatRequestOptions {
    if explicitThinking != nil || explicitReasoningEffort != nil {
      return AIProviderChatRequestOptions(
        temperature: fallback.temperature,
        thinking: explicitThinking ?? fallback.thinking,
        reasoningEffort: explicitReasoningEffort
      )
    }

    switch preference {
    case .automatic:
      return fallback
    case .disabled:
      return AIProviderChatRequestOptions(
        temperature: fallback.temperature,
        thinking: config.usesDeepSeekAPI
          ? AIProviderThinkingOption(type: "disabled")
          : nil,
        reasoningEffort: nil
      )
    case .low, .medium, .high:
      return AIProviderChatRequestOptions(
        temperature: fallback.temperature,
        thinking: config.usesDeepSeekAPI
          ? AIProviderThinkingOption(type: "enabled")
          : nil,
        reasoningEffort: preference.rawValue
      )
    }
  }
}
