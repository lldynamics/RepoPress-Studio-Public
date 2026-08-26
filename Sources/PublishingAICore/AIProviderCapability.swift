import Foundation

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
