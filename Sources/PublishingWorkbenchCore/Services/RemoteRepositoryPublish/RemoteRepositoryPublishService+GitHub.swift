import Foundation

// MARK: - GitHub remote repository helpers
extension RemoteRepositoryPublishService {
  func githubBranchSHA(
    repository: RemoteRepository,
    branch: String,
    token: String
  ) async throws -> String {
    let ref: GitHubReferenceResponse = try await send(
      githubRequest(
        repository: repository,
        method: "GET",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/ref/heads/\(encodedRepositoryPath(branch))",
        token: token
      )
    )
    return ref.object.sha
  }

  func githubCommit(
    repository: RemoteRepository,
    sha: String,
    token: String
  ) async throws -> GitHubCommitResponse {
    try await send(
      githubRequest(
        repository: repository,
        method: "GET",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/commits/\(encodedPathComponent(sha))",
        token: token
      )
    )
  }

  func githubCreateBranch(
    repository: RemoteRepository,
    branch: String,
    sha: String,
    token: String
  ) async throws {
    let _: GitHubReferenceResponse = try await send(
      githubRequest(
        repository: repository,
        method: "POST",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/refs",
        token: token,
        body: GitHubCreateReferenceBody(ref: "refs/heads/\(branch)", sha: sha)
      )
    )
  }

  func githubCreateBranchIfNeeded(
    repository: RemoteRepository,
    branch: String,
    sha: String,
    token: String
  ) async throws -> Bool {
    do {
      try await githubCreateBranch(repository: repository, branch: branch, sha: sha, token: token)
      return true
    } catch RemoteRepositoryPublishError.httpStatus(422, let body)
      where isGitHubReferenceAlreadyExists(body) {
      return false
    }
  }

  func githubDeleteBranch(
    repository: RemoteRepository,
    branch: String,
    token: String
  ) async throws {
    let response = try await data(
      for: githubRequest(
        repository: repository,
        method: "DELETE",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/refs/heads/\(encodedRepositoryPath(branch))",
        token: token
      )
    )
    try validate(response)
  }

  func isGitHubReferenceAlreadyExists(_ body: String) -> Bool {
    let normalized = body.lowercased()
    return normalized.contains("reference already exists")
      || normalized.contains("reference already exist")
      || normalized.contains("already exists")
  }

  func githubContentSHA(
    repository: RemoteRepository,
    path: String,
    branch: String,
    token: String
  ) async throws -> String? {
    let request = githubRequest(
      repository: repository,
      method: "GET",
      path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/contents/\(encodedRepositoryPath(path))",
      token: token,
      queryItems: [URLQueryItem(name: "ref", value: branch)]
    )
    let response = try await data(for: request)
    if response.statusCode == 404 {
      return nil
    }
    try validate(response)
    return try decoder.decode(GitHubContentResponse.self, from: response.data).sha
  }

  func githubExistingPullRequestURL(
    repository: RemoteRepository,
    sourceBranch: String,
    targetBranch: String,
    token: String
  ) async throws -> String? {
    let request = githubRequest(
      repository: repository,
      method: "GET",
      path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls",
      token: token,
      queryItems: [
        URLQueryItem(name: "state", value: "open"),
        URLQueryItem(name: "head", value: "\(repository.owner):\(sourceBranch)"),
        URLQueryItem(name: "base", value: targetBranch),
      ]
    )
    let response = try await data(for: request)
    try validate(response)
    return try decoder.decode([GitHubPullRequestResponse].self, from: response.data).first?.htmlURL
  }
}
