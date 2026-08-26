import Foundation

/// Provider-specific thinking switch carried by the shared AI request contract.
public struct AIProviderThinkingOption: Codable, Hashable, Sendable {
  public var type: String

  public init(type: String) {
    self.type = type
  }
}
