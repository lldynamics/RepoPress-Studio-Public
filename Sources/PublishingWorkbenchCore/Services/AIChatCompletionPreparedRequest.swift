import Foundation

/// The exact transport shape used by a prepared request. Preparation is
/// side-effect free; only the later completePrepared/streamPrepared methods
/// attach Authorization and call a transport.
public enum AIChatTransportMode: String, Codable, Hashable, Sendable {
  case nonStreaming = "non_streaming"
  case streaming

  public var isStreaming: Bool {
    self == .streaming
  }
}

/// Final, reviewable request material shared by privacy preview and the AI
/// transport. `encodedBody` is canonical JSON and never contains an API key.
final class AIPreparedRequestConsumption: @unchecked Sendable {
  private let lock = NSLock()
  private var isConsumed = false

  func consume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isConsumed else { return false }
    isConsumed = true
    return true
  }
}

/// A transient, credential-free request seal. It is intentionally not
/// Codable: a prepared request must never be persisted or replayed from a
/// snapshot, and its one-shot consumption token lives only in memory.
public struct AIPreparedAIChatCompletionRequest: Hashable, Sendable {
  public let normalizedRequest: AIChatCompletionRequest
  public let endpointIdentity: String
  public let endpointURL: URL
  public let encodedBody: Data
  public let mode: AIChatTransportMode
  public let purpose: AIProviderRequestPurpose
  public let capabilitySupportSnapshot: [AIProviderCapabilityProbeKind: AIProviderCapabilitySupport]
  public let capabilityEvidenceSnapshot:
    [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeEvidence]
  /// A SHA-256 fingerprint of the credential-free provider configuration.
  /// It makes an old prepared request unusable after config drift.
  public let configurationFingerprint: String
  /// Optional wall-clock deadline for the automatic authorization that produced
  /// this request. The deadline is deliberately not part of the encoded body
  /// and is checked again at the transport boundary.
  public let authorizationExpiresAt: Date?

  private let consumption: AIPreparedRequestConsumption

  public var canonicalEncodedBody: Data { encodedBody }
  public var isStreaming: Bool { mode.isStreaming }

  init(
    normalizedRequest: AIChatCompletionRequest,
    endpointIdentity: String,
    endpointURL: URL,
    encodedBody: Data,
    mode: AIChatTransportMode,
    purpose: AIProviderRequestPurpose,
    capabilitySupportSnapshot: [AIProviderCapabilityProbeKind: AIProviderCapabilitySupport],
    capabilityEvidenceSnapshot: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeEvidence],
    configurationFingerprint: String,
    authorizationExpiresAt: Date? = nil,
    consumption: AIPreparedRequestConsumption = AIPreparedRequestConsumption()
  ) {
    self.normalizedRequest = normalizedRequest
    self.endpointIdentity = endpointIdentity
    self.endpointURL = endpointURL
    self.encodedBody = encodedBody
    self.mode = mode
    self.purpose = purpose
    self.capabilitySupportSnapshot = capabilitySupportSnapshot
    self.capabilityEvidenceSnapshot = capabilityEvidenceSnapshot
    self.configurationFingerprint = configurationFingerprint
    self.authorizationExpiresAt = authorizationExpiresAt
    self.consumption = consumption
  }

  /// Returns a new, independently consumable prepared request bound to an
  /// optional authorization deadline. An existing tighter deadline can never
  /// be extended by rebinding, so a caller cannot accidentally widen it.
  public func bindingAuthorizationDeadline(
    _ deadline: Date?
  ) -> AIPreparedAIChatCompletionRequest {
    let effectiveDeadline: Date?
    switch (authorizationExpiresAt, deadline) {
    case (let existing?, let requested?):
      effectiveDeadline = min(existing, requested)
    case (let existing?, nil):
      effectiveDeadline = existing
    case (nil, let requested?):
      effectiveDeadline = requested
    case (nil, nil):
      effectiveDeadline = nil
    }
    return AIPreparedAIChatCompletionRequest(
      normalizedRequest: normalizedRequest,
      endpointIdentity: endpointIdentity,
      endpointURL: endpointURL,
      encodedBody: encodedBody,
      mode: mode,
      purpose: purpose,
      capabilitySupportSnapshot: capabilitySupportSnapshot,
      capabilityEvidenceSnapshot: capabilityEvidenceSnapshot,
      configurationFingerprint: configurationFingerprint,
      authorizationExpiresAt: effectiveDeadline
    )
  }

  func consume() throws {
    guard consumption.consume() else {
      throw AIChatCompletionClientError.preparedRequestAlreadyConsumed
    }
  }

  public static func == (
    lhs: AIPreparedAIChatCompletionRequest,
    rhs: AIPreparedAIChatCompletionRequest
  ) -> Bool {
    lhs.normalizedRequest == rhs.normalizedRequest
      && lhs.endpointIdentity == rhs.endpointIdentity
      && lhs.endpointURL == rhs.endpointURL
      && lhs.encodedBody == rhs.encodedBody
      && lhs.mode == rhs.mode
      && lhs.purpose == rhs.purpose
      && lhs.capabilitySupportSnapshot == rhs.capabilitySupportSnapshot
      && lhs.capabilityEvidenceSnapshot == rhs.capabilityEvidenceSnapshot
      && lhs.configurationFingerprint == rhs.configurationFingerprint
      && lhs.authorizationExpiresAt == rhs.authorizationExpiresAt
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(normalizedRequest)
    hasher.combine(endpointIdentity)
    hasher.combine(endpointURL)
    hasher.combine(encodedBody)
    hasher.combine(mode)
    hasher.combine(purpose)
    hasher.combine(capabilitySupportSnapshot)
    hasher.combine(capabilityEvidenceSnapshot)
    hasher.combine(configurationFingerprint)
    hasher.combine(authorizationExpiresAt)
  }
}
