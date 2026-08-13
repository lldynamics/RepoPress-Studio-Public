import Foundation

public struct AIChatCompletionClient: Sendable {
  static let maximumSSEEventByteCount = 2 * 1_024 * 1_024

  let transport: AIChatTransport
  let encoder: SerializedJSONEncoder
  let decoder: SerializedJSONDecoder
  let networkRecoveryPolicy: AIChatNetworkRecoveryPolicy

  public init(
    transport: AIChatTransport? = nil,
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder(),
    networkRecoveryPolicy: AIChatNetworkRecoveryPolicy = .default
  ) {
    self.transport =
      transport
      ?? URLSessionAIChatTransport(
        firstByteTimeout: networkRecoveryPolicy.firstByteTimeout,
        resourceTimeout: networkRecoveryPolicy.resourceTimeout
      )
    encoder.outputFormatting.insert(.sortedKeys)
    self.encoder = SerializedJSONEncoder(encoder)
    self.decoder = SerializedJSONDecoder(decoder)
    self.networkRecoveryPolicy = networkRecoveryPolicy
  }
}
