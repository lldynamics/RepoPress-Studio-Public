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
public enum AIProviderCapabilitySupport: String, Codable, CaseIterable, Hashable, Identifiable,
  Sendable
{
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

/// Transport-level OpenAI-compatible features. These stay separate from the
/// user-facing capability grid because support must be established for a
/// concrete endpoint/model pair before an agent runtime relies on it.
public enum AIProviderProtocolCapability: String, Codable, CaseIterable, Identifiable, Sendable {
  case toolCalling = "tool_calling"
  case structuredOutput = "structured_output"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .toolCalling:
      return CoreL10n.text("工具调用")
    case .structuredOutput:
      return CoreL10n.text("结构化输出")
    }
  }
}

public struct AIProviderCapabilityDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var capability: AIProviderCapability
  public var support: AIProviderCapabilitySupport
  public var evidenceState: AIProviderCapabilityEvidenceState
  public var probeOutcome: AIProviderCapabilityProbeOutcome?

  public init(
    capability: AIProviderCapability,
    support: AIProviderCapabilitySupport,
    evidenceState: AIProviderCapabilityEvidenceState = .unknown,
    probeOutcome: AIProviderCapabilityProbeOutcome? = nil
  ) {
    self.capability = capability
    self.support = support
    self.evidenceState = evidenceState
    self.probeOutcome = probeOutcome
  }

  public var id: AIProviderCapability { capability }
  public var key: String { capability.rawValue }
  public var displayName: String { capability.displayName }
  public var localizedTitle: String { capability.displayName }
  public var localizedSupportTitle: String { support.displayName }
  public var localizedEvidenceTitle: String { evidenceState.displayName }
}

public struct AIProviderProtocolCapabilityDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var capability: AIProviderProtocolCapability
  public var support: AIProviderCapabilitySupport
  public var evidenceState: AIProviderCapabilityEvidenceState
  public var probeOutcome: AIProviderCapabilityProbeOutcome?

  public init(
    capability: AIProviderProtocolCapability,
    support: AIProviderCapabilitySupport,
    evidenceState: AIProviderCapabilityEvidenceState = .unknown,
    probeOutcome: AIProviderCapabilityProbeOutcome? = nil
  ) {
    self.capability = capability
    self.support = support
    self.evidenceState = evidenceState
    self.probeOutcome = probeOutcome
  }

  public var id: AIProviderProtocolCapability { capability }
  public var key: String { capability.rawValue }
  public var displayName: String { capability.displayName }
  public var localizedTitle: String { capability.displayName }
  public var localizedSupportTitle: String { support.displayName }
  public var localizedEvidenceTitle: String { evidenceState.displayName }
}

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
      case .codexAppServer, .openAICompatible, .deepSeek, .openRouter, .local:
        // These presets retain the existing product contract that their
        // standard OpenAI-compatible chat transport is statically trusted.
        return .supported
      }

    case .visionInput:
      switch self {
      case .codexAppServer:
        // The first App Server bridge deliberately transports text only.
        return .unsupported
      case .openAICompatible:
        return .unknown
      case .deepSeek:
        return .unsupported
      case .openRouter, .local, .custom:
        return .unknown
      }

    case .reasoningControl:
      switch self {
      case .codexAppServer:
        return .unsupported
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
      case .codexAppServer, .openAICompatible, .deepSeek, .openRouter:
        return .unsupported
      }

    case .modelDiscovery:
      switch self {
      case .local:
        return .supported
      case .custom:
        return .unknown
      case .codexAppServer, .openAICompatible, .deepSeek, .openRouter:
        return .unsupported
      }

    }
  }
}

extension AIProviderConfig {
  public var capabilityDescriptors: [AIProviderCapabilityDescriptor] {
    AIProviderCapability.allCases.map { capabilityDescriptor(for: $0) }
  }

  public func capabilityDescriptor(
    for capability: AIProviderCapability,
    at date: Date = Date()
  ) -> AIProviderCapabilityDescriptor {
    let support = capabilitySupport(for: capability, at: date)
    let evidence = capabilityEvidence(for: capability, at: date)
    return AIProviderCapabilityDescriptor(
      capability: capability,
      support: support,
      evidenceState: capabilityEvidenceState(for: capability, at: date),
      probeOutcome: evidence?.outcome
    )
  }

  public var protocolCapabilityDescriptors: [AIProviderProtocolCapabilityDescriptor] {
    AIProviderProtocolCapability.allCases.map { protocolCapabilityDescriptor(for: $0) }
  }

  public func protocolCapabilityDescriptor(
    for capability: AIProviderProtocolCapability,
    at date: Date = Date()
  ) -> AIProviderProtocolCapabilityDescriptor {
    let evidence = capabilityEvidence(for: capability, at: date)
    return AIProviderProtocolCapabilityDescriptor(
      capability: capability,
      support: capabilitySupport(for: capability, at: date),
      evidenceState: capabilityEvidenceState(for: capability, at: date),
      probeOutcome: evidence?.outcome
    )
  }
}

extension AIProviderPreset {
  public func capabilitySupport(
    for capability: AIProviderProtocolCapability
  ) -> AIProviderCapabilitySupport {
    switch capability {
    case .toolCalling:
      switch self {
      case .deepSeek:
        return .supported
      case .codexAppServer:
        // App-level tool calls are not exposed to the local Codex process.
        return .unsupported
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
