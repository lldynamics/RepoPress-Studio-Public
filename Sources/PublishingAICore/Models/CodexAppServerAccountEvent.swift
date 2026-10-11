import Foundation

/// Presentation metadata from a running app-server. This never authorizes an AI request.
public struct CodexAppServerAccountEvent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// The server exposes only auth mode and plan here; read the full account again.
    case accountChanged
    case rateLimitsUpdated(CodexAppServerRateLimits)
    case connectionClosed
  }

  public let generation: Int
  public let accountRevision: UInt64
  public let sequence: UInt64
  public let kind: Kind

  public init(generation: Int, accountRevision: UInt64, sequence: UInt64, kind: Kind) {
    self.generation = generation
    self.accountRevision = accountRevision
    self.sequence = sequence
    self.kind = kind
  }
}
