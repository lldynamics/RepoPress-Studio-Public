import Foundation
import PublishingAICore

public struct URLSessionAIChatTransport: AIChatTransport, AIChatStreamingTransport {
  static let maximumResponseByteCount = AIChatTransportLimits.maximumResponseByteCount
  static let maximumStreamingResponseByteCount =
    AIChatTransportLimits.maximumStreamingResponseByteCount
  static let maximumStreamingLineByteCount = AIChatTransportLimits.maximumStreamingLineByteCount

  private let sessionOwner: ManagedURLSession

  private var session: URLSession { sessionOwner.session }

  var sessionConfiguration: URLSessionConfiguration {
    session.configuration
  }

  var sessionIdentity: ObjectIdentifier {
    ObjectIdentifier(session)
  }

  public init(
    session: URLSession? = nil,
    firstByteTimeout: TimeInterval = AIChatNetworkRecoveryPolicy.default.firstByteTimeout,
    resourceTimeout: TimeInterval = AIChatNetworkRecoveryPolicy.default.resourceTimeout
  ) {
    sessionOwner = session.map { ManagedURLSession(session: $0) }
      ?? ManagedURLSession {
        CredentialSafeURLSession.make(
          timeoutIntervalForRequest: firstByteTimeout,
          timeoutIntervalForResource: resourceTimeout
        )
      }
  }

  private init(ownedSession: URLSession) {
    sessionOwner = ManagedURLSession(session: ownedSession, ownsSession: true)
  }

  static func makeValidated(
    firstByteTimeout: TimeInterval,
    resourceTimeout: TimeInterval,
    proxyURL: String?
  ) throws -> URLSessionAIChatTransport {
    let session = try CredentialSafeURLSession.makeValidated(
      timeoutIntervalForRequest: firstByteTimeout,
      timeoutIntervalForResource: resourceTimeout,
      proxyURL: proxyURL
    )
    return URLSessionAIChatTransport(ownedSession: session)
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    defer { withExtendedLifetime(sessionOwner) {} }
    return try await BoundedHTTPResponseLoader.data(
      for: request,
      using: session,
      maximumByteCount: Self.maximumResponseByteCount
    )
  }

  public func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    defer { withExtendedLifetime(sessionOwner) {} }
    let (bytes, response) = try await session.bytes(for: request)
    try BoundedHTTPResponseLoader.validateExpectedLength(
      response,
      maximumByteCount: Self.maximumStreamingResponseByteCount
    )
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task { [sessionOwner] in
        defer { withExtendedLifetime(sessionOwner) {} }
        do {
          var lineBytes: [UInt8] = []
          lineBytes.reserveCapacity(4 * 1_024)
          var totalByteCount = 0
          for try await byte in bytes {
            try Task.checkCancellation()
            totalByteCount += 1
            guard totalByteCount <= Self.maximumStreamingResponseByteCount else {
              throw AIChatCompletionClientError.responseTooLarge(
                maximumBytes: Self.maximumStreamingResponseByteCount
              )
            }
            if byte == 0x0A {
              if lineBytes.last == 0x0D {
                lineBytes.removeLast()
              }
              continuation.yield(String(decoding: lineBytes, as: UTF8.self))
              lineBytes.removeAll(keepingCapacity: true)
              continue
            }
            guard lineBytes.count < Self.maximumStreamingLineByteCount else {
              throw AIChatCompletionClientError.responseTooLarge(
                maximumBytes: Self.maximumStreamingLineByteCount
              )
            }
            lineBytes.append(byte)
          }
          if !lineBytes.isEmpty {
            continuation.yield(String(decoding: lineBytes, as: UTF8.self))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    return (stream, response)
  }
}
