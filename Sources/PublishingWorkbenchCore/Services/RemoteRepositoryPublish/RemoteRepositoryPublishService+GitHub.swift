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
    try await githubFileState(
      repository: repository,
      path: path,
      ref: branch,
      token: token
    ).sha
  }

  func githubFileState(
    repository: RemoteRepository,
    path: String,
    ref: String,
    token: String
  ) async throws -> GitHubFileRemoteState {
    let request = githubRequest(
      repository: repository,
      method: "GET",
      path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/contents/\(encodedRepositoryPath(path))",
      token: token,
      queryItems: [URLQueryItem(name: "ref", value: ref)]
    )
    let response = try await data(for: request)
    if response.statusCode == 404 {
      return GitHubFileRemoteState(exists: false, sha: nil, content: nil)
    }
    try validate(response)
    let file = try decoder.decode(GitHubContentResponse.self, from: response.data)
    return GitHubFileRemoteState(
      exists: true,
      sha: file.sha,
      content: file.decodedContent
    )
  }

  func githubBlobContent(
    repository: RemoteRepository,
    sha: String,
    token: String
  ) async throws -> Data? {
    let owner = encodedPathComponent(repository.owner)
    let name = encodedPathComponent(repository.name)
    let blobSHA = encodedPathComponent(sha)
    let request = githubRequest(
      repository: repository,
      method: "GET",
      path: "/repos/\(owner)/\(name)/git/blobs/\(blobSHA)",
      token: token
    )
    let response = try await data(for: request)
    if response.statusCode == 404 {
      return nil
    }
    try validate(response)
    let blob = try decoder.decode(GitHubBlobContentResponse.self, from: response.data)
    guard blob.sha?.trimmedForPublishing.nilIfEmpty == sha.trimmedForPublishing.nilIfEmpty else {
      throw RemoteRepositoryPublishError.remoteVersionConflict(
        path: "git/blobs/\(sha)",
        expectedSHA: sha,
        actualSHA: blob.sha
      )
    }
    return blob.decodedContent
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
