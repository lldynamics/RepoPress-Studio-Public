extension AIProviderPreset {
  public var capabilityDescriptors: [AIProviderCapabilityDescriptor] {
    AIProviderCapability.allCases.map {
      AIProviderCapabilityDescriptor(
        capability: $0,
        support: capabilitySupport(for: $0),
        evidenceState: capabilitySupport(for: $0) == .unknown ? .unknown : .staticInference
      )
    }
  }

  public func capabilityDescriptor(
    for capability: AIProviderCapability
  ) -> AIProviderCapabilityDescriptor {
    AIProviderCapabilityDescriptor(
      capability: capability,
      support: capabilitySupport(for: capability),
      evidenceState: capabilitySupport(for: capability) == .unknown ? .unknown : .staticInference
    )
  }

  public func capabilitySupport(
    for capability: AIProviderCapability
  ) -> AIProviderCapabilitySupport {
    switch capability {
    case .chat, .streamingResponse:
      switch self {
      case .custom:
        // A custom endpoint/model pair is not a trusted provider contract.
        // The connection ping can prove chat for this exact pair, and the
        // selected streaming probe can prove streaming, but the preset alone
        // must not make the runtime send stream=true.
        return .unknown
      case .codexAppServer, .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow,
        .moonshot, .zhipu, .openRouter, .local:
        // These presets retain the existing product contract that their
        // standard chat transport is statically trusted.
        return .supported
      }

    case .visionInput:
      switch self {
      case .codexAppServer:
        // The first App Server bridge deliberately transports text only.
        return .unsupported
      case .openAICompatible, .anthropic, .gemini, .siliconFlow, .moonshot, .zhipu:
        return .unknown
      case .deepSeek:
        return .unsupported
      case .openRouter, .local, .custom:
        return .unknown
      }

    case .reasoningControl:
      switch self {
      case .codexAppServer:
        // App Server exposes the account's model-specific reasoning levels;
        // the authenticated model list is the source of truth.
        return .supported
      case .deepSeek, .siliconFlow:
        return .supported
      case .gemini, .moonshot, .zhipu:
        return .supported
      case .anthropic:
        // Anthropic now uses the native Messages endpoint here, but native
        // thinking controls are not implemented yet. Keep this unknown until
        // a concrete capability probe can establish the supported contract.
        return .unknown
      case .openAICompatible:
        return .unsupported
      case .openRouter, .local, .custom:
        return .unknown
      }

    case .localService:
      switch self {
      case .local:
        return .supported
      case .custom:
        return .unknown
      case .codexAppServer, .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow,
        .moonshot, .zhipu, .openRouter:
        return .unsupported
      }

    case .modelDiscovery:
      switch self {
      case .local:
        return .supported
      case .codexAppServer:
        // App Server discovers account-available models through its own RPC,
        // not the OpenAI-compatible HTTP endpoint.
        return .supported
      case .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow, .moonshot, .zhipu,
        .openRouter:
        return .supported
      case .custom:
        return .unknown
      }

    }
  }
}

extension AIProviderPreset {
  public func capabilitySupport(
    for capability: AIProviderProtocolCapability
  ) -> AIProviderCapabilitySupport {
    switch capability {
    case .toolCalling:
      switch self {
      case .deepSeek, .siliconFlow, .anthropic, .gemini, .moonshot, .zhipu:
        return .supported
      case .codexAppServer:
        // The supported app-server protocol exposes host-owned dynamic tools.
        // RepoPress registers closed schemas and executes returned calls only
        // after its own allow-list and confirmation policy validate them.
        return .supported
      case .openAICompatible, .openRouter, .local, .custom:
        // OpenAI-compatible/local endpoints and routing providers can expose
        // models with different tool support. A preset name is not a probe.
        return .unknown
      }
    case .structuredOutput:
      // JSON object and JSON schema support varies by both endpoint and model,
      // so static presets do not claim verified support.
      return .unknown
    }
  }
}
