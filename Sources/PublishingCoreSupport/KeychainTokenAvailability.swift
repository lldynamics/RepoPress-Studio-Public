import Foundation

public enum KeychainTokenAccessState: String, Codable, Hashable, Sendable {
  case available
  case missing
  case accessFailed
}

public struct KeychainTokenAvailability: Codable, Hashable, Sendable {
  public var hasToken: Bool
  public var updatedAt: Date?
  public var accessFailureMessage: String?

  private enum CodingKeys: String, CodingKey {
    case hasToken
    case updatedAt
    case accessFailureMessage
  }

  public init(
    hasToken: Bool,
    updatedAt: Date? = nil,
    accessFailureMessage: String? = nil
  ) {
    let normalizedAccessFailure = accessFailureMessage?
      .trimmedForPublishing
      .nilIfEmpty
    self.hasToken = normalizedAccessFailure == nil && hasToken
    self.updatedAt = updatedAt
    self.accessFailureMessage = normalizedAccessFailure
  }

  public init(accessFailure error: Error) {
    self.init(
      hasToken: false,
      accessFailureMessage: error.localizedDescription
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      hasToken: try container.decodeIfPresent(Bool.self, forKey: .hasToken) ?? false,
      updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt),
      accessFailureMessage: try container.decodeIfPresent(
        String.self,
        forKey: .accessFailureMessage
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hasToken, forKey: .hasToken)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try container.encodeIfPresent(
      accessFailureMessage,
      forKey: .accessFailureMessage
    )
  }

  public var accessState: KeychainTokenAccessState {
    if accessFailureMessage != nil {
      return .accessFailed
    }
    return hasToken ? .available : .missing
  }
}
