import Foundation

public protocol RemoteRepositoryHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionRemoteRepositoryHTTPTransport: RemoteRepositoryHTTPTransport {
  static let maximumResponseByteCount = 8 * 1_024 * 1_024

  private let sessionOwner: ManagedURLSession

  var hasCreatedSession: Bool { sessionOwner.hasCreatedSession }

  public init(session: URLSession? = nil) {
    sessionOwner = session.map { ManagedURLSession(session: $0) }
      ?? ManagedURLSession { CredentialSafeURLSession.make() }
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    defer { withExtendedLifetime(sessionOwner) {} }
    return try await BoundedHTTPResponseLoader.data(
      for: request,
      using: sessionOwner.session,
      maximumByteCount: Self.maximumResponseByteCount
    )
  }
}
