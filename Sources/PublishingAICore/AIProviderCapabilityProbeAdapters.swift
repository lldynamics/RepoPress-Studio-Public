import Foundation

extension AIProviderCapabilityCacheKey {
  public init(config: AIProviderConfig, probeSchemaVersion: Int = Self.currentProbeSchemaVersion) {
    self.init(
      preset: config.preset,
      endpointIdentity: config.capabilityEndpointIdentity,
      model: config.normalizedModel,
      probeSchemaVersion: probeSchemaVersion
    )
  }
}

extension AIProviderCapabilityProbeReport {
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
