import Foundation

// MARK: - Provider rollback and review withdrawal
extension RemoteRepositoryPublishService {
  func rollbackGitHub(
    draft: RemoteRepositoryRollbackDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryRollbackResult {
    let commit = try await githubCommit(repository: repository, sha: draft.commitSHA, token: token)
    guard let parent = commit.parents.first?.sha.nilIfEmpty else {
      throw RemoteRepositoryPublishError.rollbackCommitHasNoParent(draft.commitSHA)
    }
    let parentCommit = try await githubCommit(repository: repository, sha: parent, token: token)

    let currentTargetSHA = try await githubBranchSHA(
      repository: repository,
      branch: draft.targetBranch,
      token: token
    )
    guard currentTargetSHA == draft.commitSHA else {
      throw RemoteRepositoryPublishError.remoteVersionConflict(
        path: "refs/heads/\(draft.targetBranch)",
        expectedSHA: draft.commitSHA,
        actualSHA: currentTargetSHA
      )
    }

    let rollbackCommit: GitHubCommitResponse = try await send(
      githubRequest(
        repository: repository,
        method: "POST",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/commits",
        token: token,
        body: GitHubCreateCommitBody(
          message: draft.commitMessage,
          tree: parentCommit.tree.sha,
          parents: [draft.commitSHA]
        )
      )
    )
    let _: GitHubReferenceResponse = try await send(
      githubRequest(
        repository: repository,
        method: "PATCH",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/refs/heads/\(encodedRepositoryPath(draft.targetBranch))",
        token: token,
        body: GitHubUpdateReferenceBody(sha: rollbackCommit.sha, force: false)
      )
    )

    return RemoteRepositoryRollbackResult(
      provider: .github,
      recordID: draft.recordID,
      targetBranch: draft.targetBranch,
      rolledBackCommitSHA: draft.commitSHA,
      rollbackCommitSHA: rollbackCommit.sha,
      changedPaths: draft.changedPaths,
      remoteURL: "https://github.com/\(repository.owner)/\(repository.name)/commit/\(rollbackCommit.sha)"
    )
  }

  func rollbackGitLab(
    draft: RemoteRepositoryRollbackDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryRollbackResult {
    let reverted: GitLabCommitResponse = try await send(
      gitLabRequest(
        repository: repository,
        method: "POST",
        path: "/projects/\(encodedPathComponent(repository.projectPath))/repository/commits/\(encodedPathComponent(draft.commitSHA))/revert",
        token: token,
        body: GitLabRevertCommitBody(branch: draft.targetBranch)
      )
    )

    return RemoteRepositoryRollbackResult(
      provider: .gitlab,
      recordID: draft.recordID,
      targetBranch: draft.targetBranch,
      rolledBackCommitSHA: draft.commitSHA,
      rollbackCommitSHA: reverted.id,
      changedPaths: draft.changedPaths,
      remoteURL: "https://gitlab.com/\(repository.projectPath)/-/commit/\(reverted.id)"
    )
  }

  func withdrawGitHubReview(
    draft: RemoteRepositoryReviewWithdrawalDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryReviewWithdrawalResult {
    let response: GitHubPullRequestStateResponse = try await send(
      githubRequest(
        repository: repository,
        method: "PATCH",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls/\(draft.reviewNumber)",
        token: token,
        body: GitHubClosePullRequestBody(state: "closed")
      )
    )
    return RemoteRepositoryReviewWithdrawalResult(
      provider: .github,
      recordID: draft.recordID,
      reviewURL: response.htmlURL ?? draft.reviewURL,
      reviewNumber: draft.reviewNumber,
      state: response.state ?? "closed",
      branchName: draft.branchName,
      targetBranch: draft.targetBranch
    )
  }

  func withdrawGitLabReview(
    draft: RemoteRepositoryReviewWithdrawalDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryReviewWithdrawalResult {
    let response: GitLabMergeRequestStateResponse = try await send(
      gitLabRequest(
        repository: repository,
        method: "PUT",
        path: "/projects/\(encodedPathComponent(repository.projectPath))/merge_requests/\(draft.reviewNumber)",
        token: token,
        body: GitLabCloseMergeRequestBody(stateEvent: "close")
      )
    )
    return RemoteRepositoryReviewWithdrawalResult(
      provider: .gitlab,
      recordID: draft.recordID,
      reviewURL: response.webURL ?? draft.reviewURL,
      reviewNumber: draft.reviewNumber,
      state: response.state ?? "closed",
      branchName: draft.branchName,
      targetBranch: draft.targetBranch
    )
  }
}
