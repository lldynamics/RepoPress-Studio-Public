import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RepositoryEndpointError: String, Error, Equatable, Sendable {
  case invalidURL = "repository_endpoint.invalid_url"
}

/// Provider-neutral repository API endpoint that preserves self-hosted base
/// paths such as `/api/v3` instead of silently falling back to a public host.
public struct RepositoryEndpoint: Hashable, Sendable {
  public let baseURL: URL

  public static let github = RepositoryEndpoint(
    baseURL: URL(string: "https://api.github.com")!
  )

  public init(baseURL: URL) {
    self.baseURL = baseURL
  }

  public static func validated(baseURL: String) throws -> RepositoryEndpoint {
    guard
      let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme?.lowercased() == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil,
      url.query == nil,
      url.fragment == nil
    else {
      throw RepositoryEndpointError.invalidURL
    }
    return RepositoryEndpoint(baseURL: url)
  }

  public func url(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw RepositoryEndpointError.invalidURL
    }
    let slashSet = CharacterSet(charactersIn: "/")
    let basePath = components.percentEncodedPath.trimmingCharacters(in: slashSet)
    let requestPath = path.trimmingCharacters(in: slashSet)
    components.percentEncodedPath = "/" + [basePath, requestPath]
      .filter { !$0.isEmpty }
      .joined(separator: "/")
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else {
      throw RepositoryEndpointError.invalidURL
    }
    return url
  }
}

public enum RepositoryAuthentication: Sendable {
  case githubBearer(String)
  case gitLabPrivateToken(String)

  public func apply(to request: inout URLRequest) {
    switch self {
    case .githubBearer(let token):
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    case .gitLabPrivateToken(let token):
      request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
    }
    request.setValue("RepoPress", forHTTPHeaderField: "User-Agent")
  }
}
