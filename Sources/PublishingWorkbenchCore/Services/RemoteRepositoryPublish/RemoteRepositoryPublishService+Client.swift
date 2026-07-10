import Foundation

extension RemoteRepositoryPublishService {
  func githubRequest<Body: Encodable>(
    repository: RemoteRepository,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil,
    body: Body
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: repository.apiBaseURL,
      method: method,
      path: path,
      queryItems: queryItems,
      body: body
    )
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return request
  }

  func githubRequest<Body: Encodable>(
    baseURL: URL,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil,
    body: Body
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: baseURL,
      method: method,
      path: path,
      queryItems: queryItems,
      body: body
    )
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return request
  }

  func githubRequest(
    repository: RemoteRepository,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: repository.apiBaseURL,
      method: method,
      path: path,
      queryItems: queryItems
    )
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return request
  }

  func githubRequest(
    baseURL: URL,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: baseURL,
      method: method,
      path: path,
      queryItems: queryItems
    )
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return request
  }

  func gitLabRequest<Body: Encodable>(
    repository: RemoteRepository,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil,
    body: Body
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: repository.apiBaseURL,
      method: method,
      path: path,
      queryItems: queryItems,
      body: body
    )
    request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  func gitLabRequest<Body: Encodable>(
    baseURL: URL,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil,
    body: Body
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: baseURL,
      method: method,
      path: path,
      queryItems: queryItems,
      body: body
    )
    request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  func gitLabRequest(
    repository: RemoteRepository,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: repository.apiBaseURL,
      method: method,
      path: path,
      queryItems: queryItems
    )
    request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  func gitLabRequest(
    baseURL: URL,
    method: String,
    path: String,
    token: String,
    queryItems: [URLQueryItem]? = nil
  ) -> URLRequest {
    var request = jsonRequest(
      baseURL: baseURL,
      method: method,
      path: path,
      queryItems: queryItems
    )
    request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  func jsonRequest<Body: Encodable>(
    baseURL: URL,
    method: String,
    path: String,
    queryItems: [URLQueryItem]?,
    body: Body
  ) -> URLRequest {
    var request = URLRequest(url: requestURL(baseURL: baseURL, path: path, queryItems: queryItems))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? encoder.encode(body)
    return request
  }

  func jsonRequest(
    baseURL: URL,
    method: String,
    path: String,
    queryItems: [URLQueryItem]?
  ) -> URLRequest {
    var request = URLRequest(url: requestURL(baseURL: baseURL, path: path, queryItems: queryItems))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func requestURL(
    baseURL: URL,
    path: String,
    queryItems: [URLQueryItem]?
  ) -> URL {
    let normalizedBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: normalizedBase + path) else {
      return baseURL
    }
    components.queryItems = queryItems
    return components.url ?? baseURL
  }

  func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let response = try await data(for: request)
    try validate(response)
    return try decoder.decode(Response.self, from: response.data)
  }

  func data(for request: URLRequest) async throws -> HTTPDataResponse {
    let (data, response) = try await transport.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw RemoteRepositoryPublishError.invalidResponse
    }
    let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, item in
      guard let key = item.key as? String else { return }
      result[key] = String(describing: item.value)
    }
    return HTTPDataResponse(data: data, statusCode: httpResponse.statusCode, headers: headers)
  }

  func validate(_ response: HTTPDataResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      let body = String(data: response.data, encoding: .utf8) ?? ""
      throw RemoteRepositoryPublishError.httpStatus(response.statusCode, body)
    }
  }

  func remoteRepository(from profile: SiteProfile) throws -> RemoteRepository {
    let owner = profile.repoOwner.trimmedForPublishing
    let name = profile.repoName.trimmedForPublishing
    guard !owner.isEmpty, !name.isEmpty else {
      throw RemoteRepositoryPublishError.missingRepositoryConfiguration
    }

    let baseURL = try apiBaseURL(for: profile)
    return RemoteRepository(
      profile: profile,
      owner: owner,
      name: name,
      branch: profile.branch.nilIfEmpty ?? "main",
      apiBaseURL: baseURL
    )
  }

  func apiBaseURL(for profile: SiteProfile) throws -> URL {
    let baseURLText = profile.repositoryBaseURL.nilIfEmpty ?? profile.repositoryProvider.defaultBaseURL
    guard let baseURL = URL(string: baseURLText), baseURL.scheme != nil, baseURL.host != nil else {
      throw RemoteRepositoryPublishError.invalidBaseURL(baseURLText)
    }

    switch profile.repositoryProvider {
    case .github:
      return baseURL
    case .gitlab:
      let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if path.hasSuffix("api/v4") {
        return baseURL
      }
      return baseURL.appendingPathComponent("api/v4")
    }
  }

  func normalizedAPIBaseURLString(_ url: URL) -> String {
    url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  func githubPermissionSummary(_ permissions: GitHubRepositoryMetadata.Permissions?) -> String {
    guard let permissions else {
      return "GitHub 未返回 repository permissions；无法确认 push/maintain/admin。"
    }
    let active = [
      permissions.push == true ? "push" : nil,
      permissions.maintain == true ? "maintain" : nil,
      permissions.admin == true ? "admin" : nil,
    ].compactMap(\.self)
    let activeText = active.isEmpty ? "none" : active.joined(separator: ", ")
    return "GitHub repository permissions: push=\(permissions.push == true), maintain=\(permissions.maintain == true), admin=\(permissions.admin == true); active=\(activeText)."
  }

  func gitLabPermissionSummary(_ permissions: GitLabProjectMetadata.Permissions?) -> String {
    let projectAccess = permissions?.projectAccess?.accessLevel ?? 0
    let groupAccess = permissions?.groupAccess?.accessLevel ?? 0
    let effectiveAccess = max(projectAccess, groupAccess)
    return "GitLab access level: project=\(projectAccess) (\(gitLabAccessLevelName(projectAccess))), group=\(groupAccess) (\(gitLabAccessLevelName(groupAccess))), effective=\(effectiveAccess) (\(gitLabAccessLevelName(effectiveAccess)))."
  }

  func gitLabAccessLevelName(_ level: Int) -> String {
    switch level {
    case 50...:
      return "Owner"
    case 40..<50:
      return "Maintainer"
    case 30..<40:
      return "Developer"
    case 20..<30:
      return "Reporter"
    case 10..<20:
      return "Guest"
    default:
      return "No access"
    }
  }

  func githubScopeSummary(from response: HTTPDataResponse) -> String? {
    let scopes = response.headerValue("X-OAuth-Scopes")?.trimmedForPublishing.nilIfEmpty
    let accepted = response.headerValue("X-Accepted-OAuth-Scopes")?.trimmedForPublishing.nilIfEmpty
    switch (scopes, accepted) {
    case (.some(let scopes), .some(let accepted)):
      return "GitHub OAuth scopes: \(scopes); accepted: \(accepted)."
    case (.some(let scopes), .none):
      return "GitHub OAuth scopes: \(scopes)."
    case (.none, .some(let accepted)):
      return "GitHub accepted OAuth scopes: \(accepted)."
    case (.none, .none):
      return nil
    }
  }

  func requiredToken(_ token: String?) throws -> String {
    guard let token = token?.trimmedForPublishing, !token.isEmpty else {
      throw RemoteRepositoryPublishError.missingToken
    }
    return token
  }

  func contentData(for file: PublishPackageFile) throws -> Data {
    switch file.kind {
    case .markdown:
      return Data((file.content ?? "").utf8)
    case .image:
      guard let sourceFilePath = file.sourceFilePath, fileManager.fileExists(atPath: sourceFilePath) else {
        throw RemoteRepositoryPublishError.missingSourceFile(file.repositoryPath)
      }
      return try Data(contentsOf: URL(fileURLWithPath: sourceFilePath))
    }
  }

  func validateExpectedRemoteVersion(
    path: String,
    expected: String?,
    actual: String?
  ) throws {
    guard let expected = expected?.trimmedForPublishing.nilIfEmpty else {
      if let actual = actual?.trimmedForPublishing.nilIfEmpty {
        throw RemoteRepositoryPublishError.untrackedRemoteFile(path: path, actualSHA: actual)
      }
      return
    }
    guard expected == actual?.trimmedForPublishing.nilIfEmpty else {
      throw RemoteRepositoryPublishError.remoteVersionConflict(
        path: path,
        expectedSHA: expected,
        actualSHA: actual
      )
    }
  }

  func encodedRepositoryPath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
      .map { encodedPathComponent(String($0)) }
      .joined(separator: "/")
  }

  func encodedPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}
