import Foundation

extension RemoteRepositoryPublishService {
  public func checkAccess(
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryAccessCheck {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)

    var check: RemoteRepositoryAccessCheck
    switch profile.repositoryProvider {
    case .github:
      check = try await checkGitHubAccess(repository: repository, token: token)
    case .gitlab:
      check = try await checkGitLabAccess(repository: repository, token: token)
    }
    check.targetBranch = repository.branch
    check.publishStrategy = profile.repositoryPublishStrategy
    return check
  }

  public func createRepository(
    profile: SiteProfile,
    token: String?,
    privateRepository: Bool = true
  ) async throws -> RemoteRepositoryCreationResult {
    let token = try requiredToken(token)
    let name = profile.repoName.trimmedForPublishing
    guard !name.isEmpty else {
      throw RemoteRepositoryPublishError.missingRepositoryName
    }

    switch profile.repositoryProvider {
    case .github:
      return try await createGitHubRepository(
        profile: profile,
        name: name,
        token: token,
        privateRepository: privateRepository
      )
    case .gitlab:
      return try await createGitLabProject(
        profile: profile,
        name: name,
        token: token,
        privateRepository: privateRepository
      )
    }
  }

  public func publish(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    token: String?,
    onProgress: (@Sendable (RemoteRepositoryPublishProgress) -> Void)? = nil,
    expectedContentSHA256: [String: String]? = nil,
    beforeMutation: (@Sendable () async throws -> Void)? = nil
  ) async throws -> RemoteRepositoryPublishResult {
    try StructuralArticlePathPolicy.validate(package: package, profile: profile)
    let package = try normalizedPublishPackage(package)
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    if let expectedContentSHA256 {
      guard
        Set(expectedContentSHA256.keys)
          == Set(package.files.filter { $0.operation == .upsert }.map(\.repositoryPath))
      else {
        throw RemoteArticlePublicationReviewError.confirmationExpired
      }
    }

    onProgress?(
      .init(
        stage: .preparing,
        progress: 0.05,
        message: CoreL10n.text("开始发布"),
        detail: CoreL10n.text("已解析发布参数")
      )
    )

    let publishingService: RemoteRepositoryPublishService
    if beforeMutation != nil || expectedContentSHA256 != nil {
      publishingService = withPublicationGuards(
        beforeMutation: beforeMutation, expectedContentSHA256: expectedContentSHA256)
    } else {
      publishingService = self
    }

    let result: RemoteRepositoryPublishResult
    switch profile.repositoryProvider {
    case .github:
      result = try await publishingService.publishToGitHub(
        package: package,
        repository: repository,
        mode: mode,
        token: token,
        onProgress: onProgress
      )
    case .gitlab:
      result = try await publishingService.publishToGitLab(
        package: package,
        repository: repository,
        mode: mode,
        token: token,
        onProgress: onProgress
      )
    }
    return try result.validatedForSuccess()
  }

  public func rollback(
    draft: RemoteRepositoryRollbackDraft,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryRollbackResult {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)

    switch profile.repositoryProvider {
    case .github:
      return try await rollbackGitHub(draft: draft, repository: repository, token: token)
    case .gitlab:
      return try await rollbackGitLab(draft: draft, repository: repository, token: token)
    }
  }

  public func withdrawReview(
    draft: RemoteRepositoryReviewWithdrawalDraft,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryReviewWithdrawalResult {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    guard
      validatedReviewNumber(
        from: draft.reviewURL,
        provider: profile.repositoryProvider,
        repository: repository
      ) == draft.reviewNumber
    else {
      throw RemoteRepositoryPublishError.invalidReviewURL(draft.reviewURL)
    }

    switch profile.repositoryProvider {
    case .github:
      return try await withdrawGitHubReview(draft: draft, repository: repository, token: token)
    case .gitlab:
      return try await withdrawGitLabReview(draft: draft, repository: repository, token: token)
    }
  }
}
