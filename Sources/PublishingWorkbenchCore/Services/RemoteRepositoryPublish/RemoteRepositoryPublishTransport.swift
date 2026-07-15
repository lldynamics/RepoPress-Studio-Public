import Foundation

public protocol RemoteRepositoryHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionRemoteRepositoryHTTPTransport: RemoteRepositoryHTTPTransport {
  private let session: URLSession

  public init(session: URLSession? = nil) {
    self.session = session ?? CredentialSafeURLSession.make()
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}
