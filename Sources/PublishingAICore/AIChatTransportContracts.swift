import Foundation

public protocol AIChatTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public protocol AIChatStreamingTransport: AIChatTransport {
  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  )
}

package enum AIChatTransportLimits {
  package static let maximumResponseByteCount = 16 * 1_024 * 1_024
  package static let maximumStreamingResponseByteCount = 32 * 1_024 * 1_024
  package static let maximumStreamingLineByteCount = 1 * 1_024 * 1_024
}
