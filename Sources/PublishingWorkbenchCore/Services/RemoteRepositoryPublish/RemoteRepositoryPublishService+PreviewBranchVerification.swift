import Foundation

extension RemoteRepositoryPublishService {
  /// A no-op preview still needs a branch that can actually be checked out.
  /// Resolve its head rather than treating matching files as branch proof.
  func verifiedPreviewBranchHead(
    result: RemoteRepositoryPublishResult,
    repository: RemoteRepository,
    token: String
  ) async throws -> String {
    guard result.branchName.trimmedForPublishing.nilIfEmpty != nil,
      result.branchName != result.targetBranch
    else { throw RemoteRepositoryPublishError.invalidResponse }
    switch result.provider {
    case .github:
      return try await githubBranchSHA(
        repository: repository, branch: result.branchName, token: token)
    case .gitlab:
      return try await gitLabBranchSHA(
        repository: repository, branch: result.branchName, token: token)
    }
  }

  func confirmGitLabNoOpPreviewBranch(
    repository: RemoteRepository,
    branch: String,
    baseCommitSHA: String,
    alreadyExists: Bool,
    token: String
  ) async throws -> String {
    guard baseCommitSHA.trimmedForPublishing.nilIfEmpty != nil else {
      throw RemoteRepositoryPublishError.invalidResponse
    }
    if !alreadyExists {
      let created: GitLabCreatedPreviewBranch = try await send(
        gitLabRequest(
          repository: repository,
          method: "POST",
          path: "/projects/\(encodedPathComponent(repository.projectPath))/repository/branches",
          token: token,
          body: GitLabCreatePreviewBranchBody(branch: branch, ref: baseCommitSHA)
        )
      )
      guard created.name == branch, created.commit.id == baseCommitSHA else {
        throw RemoteRepositoryPublishError.invalidResponse
      }
    }
    let head = try await gitLabBranchSHA(repository: repository, branch: branch, token: token)
    guard head == baseCommitSHA else {
      throw RemoteRepositoryPublishError.remoteVersionConflict(
        path: "refs/heads/\(branch)", expectedSHA: baseCommitSHA, actualSHA: head)
    }
    return head
  }
}

private struct GitLabCreatePreviewBranchBody: Encodable {
  var branch: String
  var ref: String
}

private struct GitLabCreatedPreviewBranch: Decodable {
  var name: String
  var commit: GitLabBranchResponse.Commit
}
