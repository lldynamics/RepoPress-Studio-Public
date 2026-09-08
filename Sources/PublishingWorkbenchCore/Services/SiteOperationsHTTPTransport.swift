import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared transport for credentialed site-operation APIs.
///
/// The default session refuses credential-bearing cross-origin redirects and
/// every caller must provide a response-size ceiling.
public protocol SiteOperationsHTTPTransport: Sendable {
  func data(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse)
}

public struct URLSessionSiteOperationsHTTPTransport: SiteOperationsHTTPTransport {
  private let sessionOwner: ManagedURLSession

  public init(session: URLSession? = nil) {
    sessionOwner = session.map { ManagedURLSession(session: $0) }
      ?? ManagedURLSession {
        CredentialSafeURLSession.make(
          timeoutIntervalForRequest: 30, timeoutIntervalForResource: 60
        )
      }
  }

  public func data(
    for request: URLRequest,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse) {
    defer { withExtendedLifetime(sessionOwner) {} }
    return try await BoundedHTTPResponseLoader.data(
      for: request,
      using: sessionOwner.session,
      maximumByteCount: maximumByteCount
    )
  }
}
