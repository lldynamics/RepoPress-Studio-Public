import Foundation

public enum AIProviderRequestPurpose: String, Codable, Equatable, Hashable, Sendable {
  case interactiveChat = "interactive_chat"
  case utilityTask = "utility_task"
  case connectionTest = "connection_test"
  /// Used only by the capability probe service to intentionally test optional
  /// protocol fields before normal runtime requests are allowed to use them.
  case capabilityProbe = "capability_probe"
}
