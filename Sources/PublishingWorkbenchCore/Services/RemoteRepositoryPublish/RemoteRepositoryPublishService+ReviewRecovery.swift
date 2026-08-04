import Foundation

extension RemoteRepositoryPublishService {
  public func resumeReview(
    draft: RemoteRepositoryReviewRecoveryDraft,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryPublishResult {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)

    do {
      switch profile.repositoryProvider {
      case .github:
        return try await resumeGitHubReview(
          draft: draft,
          repository: repository,
          token: token
        )
      case .gitlab:
        return try await resumeGitLabReview(
          draft: draft,
          repository: repository,
          token: token
        )
      }
    } catch {
      throw normalizedReviewCreationError(error, provider: profile.repositoryProvider)
    }
  }

  func reviewCreationFailureDescription(
    _ error: Error,
    provider: RepositoryProvider
  ) -> String {
    normalizedReviewCreationError(error, provider: provider).localizedDescription
  }

  private func normalizedReviewCreationError(
    _ error: Error,
    provider: RepositoryProvider
  ) -> Error {
    guard case let RemoteRepositoryPublishError.httpStatus(403, body) = error else {
      return error
    }
    return RemoteRepositoryPublishError.reviewCreationPermissionDenied(
      provider: provider,
      body: body
    )
  }

  private func resumeGitHubReview(
    draft: RemoteRepositoryReviewRecoveryDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryPublishResult {
    let branchSHA = try await githubBranchSHA(
      repository: repository,
      branch: draft.branchName,
      token: token
    )
    let reviewURL: String?
    if let existing = try await githubExistingPullRequestURL(
      repository: repository,
      sourceBranch: draft.branchName,
      targetBranch: draft.targetBranch,
      token: token
    ) {
      reviewURL = existing
    } else {
      let pull: GitHubPullRequestResponse = try await send(
        githubRequest(
          repository: repository,
          method: "POST",
          path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls",
          token: token,
          body: GitHubCreatePullRequestBody(
            title: draft.title,
            body: draft.body,
            head: draft.branchName,
            base: draft.targetBranch
          )
        )
      )
      reviewURL = pull.htmlURL
    }
    guard reviewURL?.trimmedForPublishing.nilIfEmpty != nil else {
      throw RemoteRepositoryPublishError.invalidResponse
    }
    return RemoteRepositoryPublishResult(
      provider: .github,
      repositoryName: repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      mode: .reviewRequest,
      branchName: draft.branchName,
      targetBranch: draft.targetBranch,
      changedPaths: draft.changedPaths,
      commitSHA: branchSHA,
      reviewURL: reviewURL,
      reviewTitle: draft.title
    )
  }

  private func resumeGitLabReview(
    draft: RemoteRepositoryReviewRecoveryDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryPublishResult {
    guard try await gitLabBranchExists(
      repository: repository,
      branch: draft.branchName,
      token: token
    ) else {
      throw RemoteRepositoryPublishError.reviewRecoveryUnavailable(
        CoreL10n.format("远端分支 %@ 不存在。", draft.branchName)
      )
    }
    let reviewURL: String?
    if let existing = try await gitLabExistingMergeRequestURL(
      repository: repository,
      sourceBranch: draft.branchName,
      targetBranch: draft.targetBranch,
      token: token
    ) {
      reviewURL = existing
    } else {
      let mergeRequest: GitLabMergeRequestResponse = try await send(
        gitLabRequest(
          repository: repository,
          method: "POST",
          path: "/projects/\(encodedPathComponent(repository.projectPath))/merge_requests",
          token: token,
          body: GitLabCreateMergeRequestBody(
            sourceBranch: draft.branchName,
            targetBranch: draft.targetBranch,
            title: draft.title,
            description: draft.body,
            removeSourceBranch: false
          )
        )
      )
      reviewURL = mergeRequest.webURL
    }
    guard reviewURL?.trimmedForPublishing.nilIfEmpty != nil else {
      throw RemoteRepositoryPublishError.invalidResponse
    }
    return RemoteRepositoryPublishResult(
      provider: .gitlab,
      repositoryName: repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      mode: .reviewRequest,
      branchName: draft.branchName,
      targetBranch: draft.targetBranch,
      changedPaths: draft.changedPaths,
      commitSHA: draft.recordedCommitSHA,
      reviewURL: reviewURL,
      reviewTitle: draft.title
    )
  }
}
