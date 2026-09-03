import Foundation

public protocol RemoteRepositoryHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// A call-scoped transport decorator. Publishing constructs this only for the
/// operation that supplied a mutation guard, so concurrent service calls keep
/// their own transport and cannot inherit another operation's authorization.
struct MutationGuardedRemoteRepositoryHTTPTransport: RemoteRepositoryHTTPTransport {
  let underlying: RemoteRepositoryHTTPTransport
  let beforeMutation: @Sendable () async throws -> Void

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let method = request.httpMethod?.uppercased() ?? "GET"
    if method != "GET" && method != "HEAD" {
      try Task.checkCancellation()
      try await beforeMutation()
      try Task.checkCancellation()
    }
    return try await underlying.data(for: request)
  }
}

public struct URLSessionRemoteRepositoryHTTPTransport: RemoteRepositoryHTTPTransport {
  static let maximumResponseByteCount = 8 * 1_024 * 1_024

  private let session: URLSession

  public init(session: URLSession? = nil) {
    self.session = session ?? CredentialSafeURLSession.make()
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await BoundedHTTPResponseLoader.data(
      for: request,
      using: session,
      maximumByteCount: Self.maximumResponseByteCount
    )
  }
}
