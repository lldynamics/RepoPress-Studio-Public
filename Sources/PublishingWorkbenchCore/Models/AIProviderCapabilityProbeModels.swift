import Foundation

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

/// Shared, conservative classification for provider errors. A status code by
/// itself is never enough to claim that a capability is unsupported: the
/// bounded error text must name the relevant protocol field/feature and an
/// explicit rejection.
enum AIProviderCapabilityRejectionClassifier {
  static func explicitlyRejects(
    _ errorBody: String,
    capability: AIProviderCapabilityProbeKind
  ) -> Bool {
    let text = errorBody.lowercased()
    guard !text.isEmpty else { return false }

    let capabilityMarkers: [String]
    switch capability {
    case .streamingResponse:
      capabilityMarkers = ["stream", "streaming", "stream_options"]
    case .toolCalling:
      capabilityMarkers = ["tool", "tools", "tool_choice", "function_call", "function calling"]
    case .structuredOutput:
      capabilityMarkers = [
        "response_format",
        "json_schema",
        "structured output",
        "structured_output",
        "json object",
      ]
    case .visionInput:
      capabilityMarkers = [
        "image",
        "image_url",
        "vision",
        "multimodal",
      ]
    case .chat:
      return false
    }

    let rejectionMarkers = [
      "not supported",
      "unsupported",
      "does not support",
      "not implemented",
      "unimplemented",
      "unknown parameter",
      "unknown field",
      "unrecognized parameter",
      "unrecognized field",
      "invalid parameter",
      "invalid field",
      "unsupported parameter",
      "unsupported field",
      "not allowed",
      "not permitted",
      "extra inputs are not permitted",
      "extra_forbidden",
    ]

    return capabilityMarkers.contains(where: text.contains)
      && rejectionMarkers.contains(where: text.contains)
  }

  static func fixedDetail(for capability: AIProviderCapabilityProbeKind) -> String {
    switch capability {
    case .chat:
      return "connection response did not prove chat capability"
    case .streamingResponse:
      return "stream capability was explicitly rejected"
    case .toolCalling:
      return "tool-calling capability was explicitly rejected"
    case .structuredOutput:
      return "structured-output capability was explicitly rejected"
    case .visionInput:
      return "vision capability was explicitly rejected"
    }
  }

  static let inconclusiveDetail = "probe response was inconclusive"
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

/// Cache identity is deliberately free of API keys, query strings and
/// fragments. It binds observations to the exact preset, endpoint identity,
/// selected model and probe schema.
public struct AIProviderCapabilityCacheKey: Codable, Hashable, Sendable {
  public static let currentProbeSchemaVersion = 1

  public let preset: AIProviderPreset
  public let endpointIdentity: String
  public let model: String
  public let probeSchemaVersion: Int

  public init(
    preset: AIProviderPreset,
    endpointIdentity: String,
    model: String,
    probeSchemaVersion: Int = Self.currentProbeSchemaVersion
  ) {
    self.preset = preset
    self.endpointIdentity = endpointIdentity
    self.model = model
    self.probeSchemaVersion = probeSchemaVersion
  }

  public init(config: AIProviderConfig, probeSchemaVersion: Int = Self.currentProbeSchemaVersion) {
    self.init(
      preset: config.preset,
      endpointIdentity: config.capabilityEndpointIdentity,
      model: config.normalizedModel,
      probeSchemaVersion: probeSchemaVersion
    )
  }
}

public struct AIProviderCapabilityProbeEvidence: Codable, Hashable, Sendable {
  public let key: AIProviderCapabilityCacheKey
  public let capability: AIProviderCapabilityProbeKind
  public let outcome: AIProviderCapabilityProbeOutcome
  public let observedAt: Date
  public let expiresAt: Date
  public let statusCode: Int?
  public let detail: String?

  public init(
    key: AIProviderCapabilityCacheKey,
    capability: AIProviderCapabilityProbeKind,
    outcome: AIProviderCapabilityProbeOutcome,
    observedAt: Date,
    expiresAt: Date,
    statusCode: Int? = nil,
    detail: String? = nil
  ) {
    self.key = key
    self.capability = capability
    self.outcome = outcome
    self.observedAt = observedAt
    self.expiresAt = expiresAt
    self.statusCode = statusCode
    self.detail = detail
  }

  public func isCurrent(
    at date: Date,
    schemaVersion: Int = AIProviderCapabilityCacheKey.currentProbeSchemaVersion
  ) -> Bool {
    key.probeSchemaVersion == schemaVersion
      && date >= observedAt
      && date < expiresAt
  }

  public var support: AIProviderCapabilitySupport {
    outcome.support
  }
}

public struct AIProviderCapabilityProbeResult: Codable, Hashable, Sendable {
  public let capability: AIProviderCapabilityProbeKind
  public let outcome: AIProviderCapabilityProbeOutcome
  public let statusCode: Int?
  public let responseModel: String?
  public let responsePreview: String?
  public let evidence: AIProviderCapabilityProbeEvidence
  public let fromCache: Bool

  public init(
    capability: AIProviderCapabilityProbeKind,
    outcome: AIProviderCapabilityProbeOutcome,
    statusCode: Int? = nil,
    responseModel: String? = nil,
    responsePreview: String? = nil,
    evidence: AIProviderCapabilityProbeEvidence,
    fromCache: Bool = false
  ) {
    self.capability = capability
    self.outcome = outcome
    self.statusCode = statusCode
    self.responseModel = responseModel
    self.responsePreview = responsePreview
    self.evidence = evidence
    self.fromCache = fromCache
  }
}

public enum AIProviderCapabilityProbeCacheState: String, Codable, CaseIterable, Hashable, Sendable {
  case hit
  case partialHit = "partial_hit"
  case miss
  case expired
  case forcedRefresh = "forced_refresh"

  public var displayName: String {
    switch self {
    case .hit:
      return CoreL10n.text("缓存命中")
    case .partialHit:
      return CoreL10n.text("部分缓存命中")
    case .miss:
      return CoreL10n.text("首次探测")
    case .expired:
      return CoreL10n.text("已过期，重新探测")
    case .forcedRefresh:
      return CoreL10n.text("强制刷新")
    }
  }
}

public struct AIProviderCapabilityProbeCacheEntry: Codable, Hashable, Sendable {
  public let key: AIProviderCapabilityCacheKey
  public let results: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeResult]
  public let storedAt: Date
  public let expiresAt: Date

  public init(
    key: AIProviderCapabilityCacheKey,
    results: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeResult],
    storedAt: Date,
    expiresAt: Date
  ) {
    self.key = key
    self.results = results
    self.storedAt = storedAt
    self.expiresAt = expiresAt
  }

  public func isCurrent(
    at date: Date,
    schemaVersion: Int = AIProviderCapabilityCacheKey.currentProbeSchemaVersion
  ) -> Bool {
    date < expiresAt
      && key.probeSchemaVersion == schemaVersion
      && results.values.allSatisfy { $0.evidence.isCurrent(at: date, schemaVersion: schemaVersion) }
  }
}

/// The cache is in-memory by default. Persistence, when desired by a caller,
/// can use the Codable entry without ever storing credentials.
public actor AIProviderCapabilityProbeCache {
  private var entries: [AIProviderCapabilityCacheKey: AIProviderCapabilityProbeCacheEntry] = [:]

  public init() {}

  public func entry(
    for key: AIProviderCapabilityCacheKey
  ) -> AIProviderCapabilityProbeCacheEntry? {
    entries[key]
  }

  public func currentEntry(
    for key: AIProviderCapabilityCacheKey,
    at date: Date
  ) -> AIProviderCapabilityProbeCacheEntry? {
    guard let entry = entries[key], entry.isCurrent(at: date) else {
      return nil
    }
    return entry
  }

  public func store(_ entry: AIProviderCapabilityProbeCacheEntry) {
    entries[entry.key] = entry
  }

  /// The final cancellation check lives in the cache actor as well as in the
  /// probe task, so a cancelled probe cannot leave a newly observed entry
  /// behind during the actor hop.
  public func storeUnlessCancelled(
    _ entry: AIProviderCapabilityProbeCacheEntry
  ) -> Bool {
    guard !Task.isCancelled else { return false }
    entries[entry.key] = entry
    return true
  }

  public func remove(for key: AIProviderCapabilityCacheKey) {
    entries.removeValue(forKey: key)
  }

  public func removeAll() {
    entries.removeAll()
  }
}

public struct AIProviderCapabilityProbeReport: Codable, Hashable, Sendable {
  public let key: AIProviderCapabilityCacheKey
  public let results: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeResult]
  public let cacheState: AIProviderCapabilityProbeCacheState
  public let generatedAt: Date

  public init(
    key: AIProviderCapabilityCacheKey,
    results: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeResult],
    cacheState: AIProviderCapabilityProbeCacheState,
    generatedAt: Date
  ) {
    self.key = key
    self.results = results
    self.cacheState = cacheState
    self.generatedAt = generatedAt
  }

  public var evidenceByCapability:
    [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeEvidence]
  {
    results.mapValues(\.evidence)
  }

  public func applying(
    to config: AIProviderConfig,
    at date: Date = Date()
  ) -> AIProviderConfig {
    guard AIProviderCapabilityCacheKey(config: config) == key else {
      return config
    }
    var updated = config
    var evidence = updated.capabilityProbeEvidence ?? [:]
    for result in results.values
    where result.evidence.isCurrent(
      at: date,
      schemaVersion: key.probeSchemaVersion
    ) {
      evidence[result.capability] = result.evidence
    }
    updated.capabilityProbeEvidence = evidence
    return updated
  }
}
