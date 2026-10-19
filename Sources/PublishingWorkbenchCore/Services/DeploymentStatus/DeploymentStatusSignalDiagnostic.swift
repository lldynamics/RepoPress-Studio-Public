import Foundation

/// Machine-readable diagnostics for status signals that require human action.
/// Keep this optional and additive: older persisted snapshots omit it.
public enum DeploymentStatusSignalDiagnostic: String, Codable, Hashable, Sendable {
  case missingExpectedDigest
  case missingMarker
  case invalidMarker
  case digestMismatch
}

public struct DeploymentProviderIntegrationDepth: Codable, Hashable, Sendable {
  public var title: String
  public var detail: String

  public init(title: String, detail: String) {
    self.title = title
    self.detail = detail
  }
}
