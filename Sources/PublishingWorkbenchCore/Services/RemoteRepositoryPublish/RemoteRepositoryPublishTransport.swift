import Foundation

public protocol RemoteRepositoryHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
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
