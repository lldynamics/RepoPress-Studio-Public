import Foundation
import PublishingCoreSupport

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
}
