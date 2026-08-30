import Foundation

extension RemoteRepositoryPublishService {
  public func reviewStatus(
    for record: ReleaseRecord,
    profile: SiteProfile,
    token: String?,
    checkedAt: Date = Date()
  ) async throws -> RemoteRepositoryReviewStatusSnapshot {
    try Task.checkCancellation()
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    let reviewNumber = try validatedReviewNumber(
      for: record,
      profile: profile,
      repository: repository
    )

    let snapshot: RemoteRepositoryReviewStatusSnapshot
    switch profile.repositoryProvider {
    case .github:
      snapshot = try await githubReviewStatus(
        record: record,
        repository: repository,
        reviewNumber: reviewNumber,
        token: token,
        checkedAt: checkedAt
      )
    case .gitlab:
      snapshot = try await gitLabReviewStatus(
        record: record,
        repository: repository,
        reviewNumber: reviewNumber,
        token: token,
        checkedAt: checkedAt
      )
    }
    try Task.checkCancellation()
    return snapshot
  }

  private func githubReviewStatus(
    record: ReleaseRecord,
    repository: RemoteRepository,
    reviewNumber: Int,
    token: String,
    checkedAt: Date
  ) async throws -> RemoteRepositoryReviewStatusSnapshot {
    let request = githubRequest(
      repository: repository,
      method: "GET",
      path:
        "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls/\(reviewNumber)",
      token: token
    )
    let response = try await data(for: request)
    try validate(response)
    let pull = try decoder.decode(GitHubPullRequestStatusResponse.self, from: response.data)

    guard pull.number == reviewNumber,
      validatedReviewNumber(
        from: pull.htmlURL,
        provider: .github,
        repository: repository
      ) == reviewNumber,
      pull.head.ref == record.branchName?.trimmedForPublishing.nilIfEmpty,
      pull.base.ref == record.targetBranch?.trimmedForPublishing.nilIfEmpty,
      pull.head.repo?.fullName.caseInsensitiveCompare(repository.displayName) == .orderedSame,
      pull.base.repo?.fullName.caseInsensitiveCompare(repository.displayName) == .orderedSame
    else {
      throw RemoteRepositoryPublishError.invalidResponse
    }

    let state: RemoteRepositoryReviewLifecycleState
    let mergeCommitSHA: String?
    switch (pull.merged, pull.state.lowercased()) {
    case (true, "closed"):
      guard let commit = pull.mergeCommitSHA?.trimmedForPublishing.nilIfEmpty else {
        throw RemoteRepositoryPublishError.invalidResponse
      }
      state = .merged
      mergeCommitSHA = commit
    case (false, "open"):
      state = .open
      mergeCommitSHA = nil
    case (false, "closed"):
      state = .closedWithoutMerge
      mergeCommitSHA = nil
    default:
      throw RemoteRepositoryPublishError.invalidResponse
    }

    return RemoteRepositoryReviewStatusSnapshot(
      provider: .github,
      reviewNumber: reviewNumber,
      reviewURL: pull.htmlURL,
      state: state,
      sourceBranch: pull.head.ref,
      targetBranch: pull.base.ref,
      headCommitSHA: pull.head.sha,
      mergeCommitSHA: mergeCommitSHA,
      checkedAt: checkedAt
    )
  }

  private func gitLabReviewStatus(
    record: ReleaseRecord,
    repository: RemoteRepository,
    reviewNumber: Int,
    token: String,
    checkedAt: Date
  ) async throws -> RemoteRepositoryReviewStatusSnapshot {
    let request = gitLabRequest(
      repository: repository,
      method: "GET",
      path:
        "/projects/\(encodedPathComponent(repository.projectPath))/merge_requests/\(reviewNumber)",
      token: token
    )
    let response = try await data(for: request)
    try validate(response)
    let mergeRequest = try decoder.decode(
      GitLabMergeRequestStatusResponse.self,
      from: response.data
    )

    guard mergeRequest.iid == reviewNumber,
      validatedReviewNumber(
        from: mergeRequest.webURL,
        provider: .gitlab,
        repository: repository
      ) == reviewNumber,
      mergeRequest.sourceBranch == record.branchName?.trimmedForPublishing.nilIfEmpty,
      mergeRequest.targetBranch == record.targetBranch?.trimmedForPublishing.nilIfEmpty
    else {
      throw RemoteRepositoryPublishError.invalidResponse
    }

    let state: RemoteRepositoryReviewLifecycleState
    let mergeCommitSHA: String?
    switch mergeRequest.state.lowercased() {
    case "opened":
      state = .open
      mergeCommitSHA = nil
    case "locked":
      state = .locked
      mergeCommitSHA = nil
    case "closed":
      state = .closedWithoutMerge
      mergeCommitSHA = nil
    case "merged":
      guard
        let commit = mergeRequest.mergeCommitSHA?.trimmedForPublishing.nilIfEmpty
          ?? mergeRequest.squashCommitSHA?.trimmedForPublishing.nilIfEmpty
      else {
        throw RemoteRepositoryPublishError.invalidResponse
      }
      state = .merged
      mergeCommitSHA = commit
    default:
      throw RemoteRepositoryPublishError.invalidResponse
    }

    return RemoteRepositoryReviewStatusSnapshot(
      provider: .gitlab,
      reviewNumber: reviewNumber,
      reviewURL: mergeRequest.webURL,
      state: state,
      sourceBranch: mergeRequest.sourceBranch,
      targetBranch: mergeRequest.targetBranch,
      headCommitSHA: mergeRequest.headCommitSHA.trimmedForPublishing.nilIfEmpty,
      mergeCommitSHA: mergeCommitSHA,
      checkedAt: checkedAt
    )
  }

  private func validatedReviewNumber(
    for record: ReleaseRecord,
    profile: SiteProfile,
    repository: RemoteRepository
  ) throws -> Int {
    guard record.kind == .remoteReviewRequest,
      record.repositoryProvider == profile.repositoryProvider,
      repositoryIdentity(
        record.repoOwner, matches: repository.owner, provider: repository.profile.repositoryProvider
      ),
      repositoryIdentity(
        record.repoName, matches: repository.name, provider: repository.profile.repositoryProvider),
      try recordedAPIBaseURL(record: record, profile: profile) == repository.apiBaseURL,
      record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil,
      let reviewURL = record.reviewURL?.trimmedForPublishing.nilIfEmpty
    else {
      throw RemoteRepositoryPublishError.invalidResponse
    }

    let urlNumber = validatedReviewNumber(
      from: reviewURL,
      provider: profile.repositoryProvider,
      repository: repository
    )
    let storedNumber = record.reviewNumber.flatMap { $0 > 0 ? $0 : nil }
    guard let reviewNumber = storedNumber ?? urlNumber,
      urlNumber == reviewNumber
    else {
      throw RemoteRepositoryPublishError.invalidReviewURL(reviewURL)
    }
    return reviewNumber
  }

  private func recordedAPIBaseURL(record: ReleaseRecord, profile: SiteProfile) throws -> URL {
    guard let repositoryBaseURL = record.repositoryBaseURL?.trimmedForPublishing.nilIfEmpty else {
      throw RemoteRepositoryPublishError.invalidResponse
    }
    var recordedProfile = profile
    recordedProfile.repositoryProvider = record.repositoryProvider ?? profile.repositoryProvider
    recordedProfile.repositoryBaseURL = repositoryBaseURL
    recordedProfile.repoOwner = record.repoOwner ?? ""
    recordedProfile.repoName = record.repoName ?? ""
    return try apiBaseURL(for: recordedProfile)
  }

  private func repositoryIdentity(
    _ recorded: String?,
    matches current: String,
    provider: RepositoryProvider
  ) -> Bool {
    guard let recorded = recorded?.trimmedForPublishing.nilIfEmpty else { return false }
    switch provider {
    case .github:
      return recorded.caseInsensitiveCompare(current) == .orderedSame
    case .gitlab:
      return recorded == current
    }
  }

  func reviewNumber(from reviewURL: String, provider: RepositoryProvider) -> Int? {
    guard let url = URL(string: reviewURL),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil
    else {
      return nil
    }
    let parts = url.pathComponents.filter { $0 != "/" }
    switch provider {
    case .github:
      guard parts.count == 4,
        parts[2] == "pull",
        let number = Int(parts[3]),
        number > 0
      else {
        return nil
      }
      return number
    case .gitlab:
      guard parts.count >= 5,
        parts[parts.count - 3] == "-",
        parts[parts.count - 2] == "merge_requests",
        let number = Int(parts[parts.count - 1]),
        number > 0
      else {
        return nil
      }
      return number
    }
  }

  func validatedReviewNumber(
    from reviewURL: String,
    provider: RepositoryProvider,
    repository: RemoteRepository
  ) -> Int? {
    guard let url = URL(string: reviewURL),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      let host = url.host?.lowercased(),
      url.user == nil,
      url.password == nil,
      let number = reviewNumber(from: reviewURL, provider: provider)
    else {
      return nil
    }

    let expectedHost: String
    switch provider {
    case .github:
      expectedHost =
        repository.apiBaseURL.host?.lowercased() == "api.github.com"
        ? "github.com"
        : repository.apiBaseURL.host?.lowercased() ?? ""
    case .gitlab:
      expectedHost = repository.apiBaseURL.host?.lowercased() ?? ""
    }
    guard host == expectedHost, url.port == repository.apiBaseURL.port else { return nil }

    let parts = url.pathComponents.filter { $0 != "/" }
    switch provider {
    case .github:
      guard parts.count == 4,
        parts[0].caseInsensitiveCompare(repository.owner) == .orderedSame,
        parts[1].caseInsensitiveCompare(repository.name) == .orderedSame,
        parts[2] == "pull",
        Int(parts[3]) == number
      else {
        return nil
      }
    case .gitlab:
      let expectedPrefix =
        repository.owner.split(separator: "/").map(String.init)
        + [repository.name]
      guard parts.count == expectedPrefix.count + 3,
        Array(parts.prefix(expectedPrefix.count)) == expectedPrefix,
        parts[expectedPrefix.count] == "-",
        parts[expectedPrefix.count + 1] == "merge_requests",
        Int(parts[expectedPrefix.count + 2]) == number
      else {
        return nil
      }
    }
    return number
  }
}
