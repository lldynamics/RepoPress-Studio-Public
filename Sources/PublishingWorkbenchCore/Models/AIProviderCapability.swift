import Foundation

/// Stable identifiers for AI features the workbench can describe independently
/// from provider-specific marketing names.
public enum AIProviderCapability: String, Codable, CaseIterable, Identifiable, Sendable {
  case chat = "chat"
  case streamingResponse = "streaming_response"
  case visionInput = "vision_input"
  case reasoningControl = "reasoning_control"
  case localService = "local_service"
  case modelDiscovery = "model_discovery"

  public var id: String { rawValue }

  /// Source key for the Core target's localization table.
  public var localizationKey: String {
    switch self {
    case .chat:
      return "普通对话"
    case .streamingResponse:
      return "流式响应"
    case .visionInput:
      return "视觉输入"
    case .reasoningControl:
      return "推理控制"
    case .localService:
      return "本地服务"
    case .modelDiscovery:
      return "模型发现"
    }
  }

  public var displayName: String {
    CoreL10n.text(localizationKey)
  }
}

/// A conservative support result. `unknown` means the endpoint or selected
/// model must be checked before the feature is presented as available.
public enum AIProviderCapabilitySupport: String, Codable, CaseIterable, Identifiable, Sendable {
  case supported
  case unsupported
  case unknown

  public var id: String { rawValue }

  public var localizationKey: String {
    switch self {
    case .supported:
      return "支持"
    case .unsupported:
      return "不支持"
    case .unknown:
      return "未知"
    }
  }

  public var displayName: String {
    CoreL10n.text(localizationKey)
  }
}

public struct AIProviderCapabilityDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var capability: AIProviderCapability
  public var support: AIProviderCapabilitySupport

  public init(
    capability: AIProviderCapability,
    support: AIProviderCapabilitySupport
  ) {
    self.capability = capability
    self.support = support
  }

  public var id: AIProviderCapability { capability }
  public var key: String { capability.rawValue }
  public var displayName: String { capability.displayName }
  public var localizedTitle: String { capability.displayName }
  public var localizedSupportTitle: String { support.displayName }
}

public extension AIProviderPreset {
  var capabilityDescriptors: [AIProviderCapabilityDescriptor] {
    AIProviderCapability.allCases.map {
      AIProviderCapabilityDescriptor(
        capability: $0,
        support: capabilitySupport(for: $0)
      )
    }
  }

  func capabilityDescriptor(
    for capability: AIProviderCapability
  ) -> AIProviderCapabilityDescriptor {
    AIProviderCapabilityDescriptor(
      capability: capability,
      support: capabilitySupport(for: capability)
    )
  }

  func capabilitySupport(
    for capability: AIProviderCapability
  ) -> AIProviderCapabilitySupport {
    switch capability {
    case .chat, .streamingResponse:
      return .supported

    case .visionInput:
      switch self {
      case .openAICompatible:
        return .unknown
      case .deepSeek:
        return .unsupported
      case .openRouter, .local, .custom:
        return .unknown
      }

    case .reasoningControl:
      switch self {
      case .deepSeek:
        return .supported
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
      case .openAICompatible, .deepSeek, .openRouter:
        return .unsupported
      }

    case .modelDiscovery:
      switch self {
      case .local:
        return .supported
      case .custom:
        return .unknown
      case .openAICompatible, .deepSeek, .openRouter:
        return .unsupported
      }
    }
  }
}

public extension AIProviderConfig {
  var capabilityDescriptors: [AIProviderCapabilityDescriptor] {
    AIProviderCapability.allCases.map { capabilityDescriptor(for: $0) }
  }

  func capabilityDescriptor(
    for capability: AIProviderCapability
  ) -> AIProviderCapabilityDescriptor {
    AIProviderCapabilityDescriptor(
      capability: capability,
      support: capabilitySupport(for: capability)
    )
  }

  func capabilitySupport(
    for capability: AIProviderCapability
  ) -> AIProviderCapabilitySupport {
    switch capability {
    case .chat, .streamingResponse:
      guard chatCompletionsURL != nil, !normalizedModel.isEmpty else {
        return .unknown
      }
      return preset.capabilitySupport(for: capability)

    case .visionInput:
      if usesDeepSeekAPI {
        return .unsupported
      }
      return preset.capabilitySupport(for: capability)

    case .reasoningControl:
      if usesDeepSeekAPI {
        return .supported
      }
      return preset.capabilitySupport(for: capability)

    case .localService:
      if isLocalEndpoint {
        return .supported
      }
      if hasResolvedRemoteEndpoint {
        return .unsupported
      }
      return preset.capabilitySupport(for: capability)

    case .modelDiscovery:
      if preset == .local {
        if isLocalEndpoint {
          return .supported
        }
        return hasResolvedRemoteEndpoint ? .unsupported : .unknown
      }
      return preset.capabilitySupport(for: capability)
    }
  }

  private var hasResolvedRemoteEndpoint: Bool {
    guard let host = URL(string: normalizedBaseURL)?.host, !host.isEmpty else {
      return false
    }
    return !isLocalEndpoint
  }
}
