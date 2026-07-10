import Foundation

extension DeploymentStatusService {

  func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let (data, response) = try await transport.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw DeploymentStatusError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw DeploymentStatusError.httpStatus(httpResponse.statusCode)
    }
    return try decoder.decode(Response.self, from: data)
  }

  func githubRequest(
    profile: SiteProfile,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) throws -> URLRequest {
    var request = try apiRequest(baseURL: githubAPIBaseURL(profile), path: path, queryItems: queryItems)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return request
  }

  func gitLabRequest(
    profile: SiteProfile,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) throws -> URLRequest {
    var request = try apiRequest(baseURL: gitLabAPIBaseURL(profile), path: path, queryItems: queryItems)
    request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
    return request
  }

  func netlifyRequest(
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) throws -> URLRequest {
    var request = try apiRequest(
      baseURL: URL(string: "https://api.netlify.com")!,
      path: path,
      queryItems: queryItems
    )
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  func vercelRequest(
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) throws -> URLRequest {
    var request = try apiRequest(
      baseURL: URL(string: "https://api.vercel.com")!,
      path: path,
      queryItems: queryItems
    )
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  func cloudflareRequest(
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) throws -> URLRequest {
    var request = try apiRequest(
      baseURL: URL(string: "https://api.cloudflare.com")!,
      path: path,
      queryItems: queryItems
    )
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  func apiRequest(baseURL: URL, path: String, queryItems: [URLQueryItem]?) throws -> URLRequest {
    let normalizedBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: normalizedBase + path) else {
      throw DeploymentStatusError.invalidURL(normalizedBase + path)
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw DeploymentStatusError.invalidURL(normalizedBase + path)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  func githubAPIBaseURL(_ profile: SiteProfile) throws -> URL {
    let baseURLText = profile.repositoryBaseURL.nilIfEmpty ?? RepositoryProvider.github.defaultBaseURL
    guard let url = URL(string: baseURLText), url.scheme != nil, url.host != nil else {
      throw DeploymentStatusError.invalidURL(baseURLText)
    }
    return url
  }

  func gitLabAPIBaseURL(_ profile: SiteProfile) throws -> URL {
    let baseURLText = profile.repositoryBaseURL.nilIfEmpty ?? RepositoryProvider.gitlab.defaultBaseURL
    guard let url = URL(string: baseURLText), url.scheme != nil, url.host != nil else {
      throw DeploymentStatusError.invalidURL(baseURLText)
    }
    if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("api/v4") {
      return url
    }
    return url.appendingPathComponent("api/v4")
  }
  func encodedPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

}
