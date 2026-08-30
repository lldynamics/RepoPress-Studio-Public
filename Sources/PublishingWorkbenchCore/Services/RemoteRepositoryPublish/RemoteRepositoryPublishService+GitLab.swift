import Foundation

extension RemoteRepositoryPublishService {
  func gitLabFileState(
    repository: RemoteRepository,
    path: String,
    ref: String,
    token: String
  ) async throws -> GitLabFileRemoteState {
    let request = gitLabRequest(
      repository: repository,
      method: "GET",
      path: "/projects/\(encodedPathComponent(repository.projectPath))/repository/files/\(encodedPathComponent(path))",
      token: token,
      queryItems: [URLQueryItem(name: "ref", value: ref)]
    )
    let response = try await data(for: request)
    if response.statusCode == 404 {
      return GitLabFileRemoteState(exists: false, lastCommitID: nil, content: nil)
    }
    try validate(response)
    let file = try decoder.decode(GitLabFileResponse.self, from: response.data)
    return GitLabFileRemoteState(
      exists: true,
      lastCommitID: file.lastCommitID,
      content: file.decodedContent
    )
  }

  func gitLabBranchExists(
    repository: RemoteRepository,
    branch: String,
    token: String
  ) async throws -> Bool {
    let request = gitLabRequest(
      repository: repository,
      method: "GET",
      path: "/projects/\(encodedPathComponent(repository.projectPath))/repository/branches/\(encodedPathComponent(branch))",
      token: token
    )
    let response = try await data(for: request)
    if response.statusCode == 404 {
      return false
    }
    try validate(response)
    return true
  }

  func gitLabBranchSHA(
    repository: RemoteRepository,
    branch: String,
    token: String
  ) async throws -> String {
    let request = gitLabRequest(
      repository: repository,
      method: "GET",
      path:
        "/projects/\(encodedPathComponent(repository.projectPath))/repository/branches/\(encodedPathComponent(branch))",
      token: token
    )
    let response = try await data(for: request)
    try validate(response)
    return try decoder.decode(GitLabBranchResponse.self, from: response.data).commit.id
  }

  func gitLabExistingMergeRequestURL(
    repository: RemoteRepository,
    sourceBranch: String,
    targetBranch: String,
    token: String
  ) async throws -> String? {
    let request = gitLabRequest(
      repository: repository,
      method: "GET",
      path: "/projects/\(encodedPathComponent(repository.projectPath))/merge_requests",
      token: token,
      queryItems: [
        URLQueryItem(name: "state", value: "opened"),
        URLQueryItem(name: "source_branch", value: sourceBranch),
        URLQueryItem(name: "target_branch", value: targetBranch),
      ]
    )
    let response = try await data(for: request)
    try validate(response)
    return try decoder.decode([GitLabMergeRequestResponse].self, from: response.data).first?.webURL
  }

}
