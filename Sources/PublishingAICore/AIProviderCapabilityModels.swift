import Foundation
import PublishingCoreSupport

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

/// A deliberately small set of endpoint/model probes. A probe is an
/// observation request, not a declaration that a provider advertises a
/// feature globally.
public enum AIProviderCapabilityProbeKind: String, Codable, CaseIterable, Hashable, Identifiable,
  Sendable
{
  case chat
  case streamingResponse
  case toolCalling
  case structuredOutput
  case visionInput

  public var id: String { rawValue }

  public var capability: AIProviderCapability? {
    switch self {
    case .chat:
      return .chat
    case .streamingResponse:
      return .streamingResponse
    case .visionInput:
      return .visionInput
    case .toolCalling, .structuredOutput:
      return nil
    }
  }

  public var protocolCapability: AIProviderProtocolCapability? {
    switch self {
    case .toolCalling:
      return .toolCalling
    case .structuredOutput:
      return .structuredOutput
    case .chat, .streamingResponse, .visionInput:
      return nil
    }
  }

  public var displayName: String {
    switch self {
    case .chat:
      return CoreL10n.text("普通对话")
    case .streamingResponse:
      return CoreL10n.text("流式响应")
    case .toolCalling:
      return CoreL10n.text("工具调用")
    case .structuredOutput:
      return CoreL10n.text("结构化输出")
    case .visionInput:
      return CoreL10n.text("视觉输入")
    }
  }
}

extension AIProviderCapabilityProbeKind {
  public init?(capability: AIProviderCapability) {
    switch capability {
    case .chat:
      self = .chat
    case .streamingResponse:
      self = .streamingResponse
    case .visionInput:
      self = .visionInput
    case .reasoningControl, .localService, .modelDiscovery:
      return nil
    }
  }
}

/// Probe outcomes intentionally distinguish a known negative from a failed
/// or unauthorised observation. Only `supported` and `unsupported` are
/// evidence-bearing; `inconclusive` must remain fail-closed.
public enum AIProviderCapabilityProbeOutcome: String, Codable, CaseIterable, Hashable, Sendable {
  case supported
  case unsupported
  case inconclusive

  public var displayName: String {
    switch self {
    case .supported:
      return CoreL10n.text("支持")
    case .unsupported:
      return CoreL10n.text("不支持")
    case .inconclusive:
      return CoreL10n.text("未知（结果不确定）")
    }
  }

  public var support: AIProviderCapabilitySupport {
    switch self {
    case .supported:
      return .supported
    case .unsupported:
      return .unsupported
    case .inconclusive:
      return .unknown
    }
  }
}

/// Presentation provenance for a capability. This is intentionally separate
/// from the support value so an expired negative/positive observation cannot be
/// mistaken for a current provider fact.
public enum AIProviderCapabilityEvidenceState: String, Codable, CaseIterable, Hashable, Sendable {
  case staticInference = "static_inference"
  case probed
  case unknown
  case expired

  public var displayName: String {
    switch self {
    case .staticInference:
      return CoreL10n.text("静态推断")
    case .probed:
      return CoreL10n.text("已探测")
    case .unknown:
      return CoreL10n.text("未知")
    case .expired:
      return CoreL10n.text("已过期")
    }
  }
}
